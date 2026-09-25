import SwiftUI
import WebKit

/// 经过特化配置的高性能游戏 WebKit 容器（全面集成 OGG 软解内核、WebAudio 激活层与 原生磁盘存档桥接）
struct GameWebView: UIViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        
        // Runtime and save snapshot are installed together before navigation below.
        // MARK: - 注入 1：在 DOM 加载最早阶段注入 stbvorbis 软解内核
        let vorbisScript = WKUserScript(source: EmuScriptAssets.stbvorbisScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(vorbisScript)
        
        // MARK: - 注入 2：AudioContext 解码补丁与 canPlayType 声明
        let audioCompatSource = """
        (function() {
            // 1. Hook HTML5 Audio canPlayType 声明支持 OGG Vorbis
            if (window.HTMLAudioElement && window.HTMLAudioElement.prototype) {
                const origCanPlay = window.HTMLAudioElement.prototype.canPlayType;
                window.HTMLAudioElement.prototype.canPlayType = function(type) {
                    if (type && (type.includes('audio/ogg') || type.includes('vorbis'))) {
                        return 'probably';
                    }
                    return origCanPlay.call(this, type);
                };
            }
            
            // 2. 检测 ArrayBuffer 是否为 OGG 容器 (前 4 字节为 "OggS")
            function isOggBuffer(buf) {
                if (!buf || buf.byteLength < 4) return false;
                try {
                    const v = new Uint8Array(buf, 0, 4);
                    return v[0] === 0x4F && v[1] === 0x67 && v[2] === 0x67 && v[3] === 0x53;
                } catch(e) {
                    return false;
                }
            }
            
            // 3. AudioContext decodeAudioData 智能分流解码：
            // 对于 OGG 文件直接使用 stbvorbis 软解（避免 iOS 原生 decode 导致 buffer 剥离损坏或静音报红崩溃）
            const AudioCtx = window.AudioContext || window.webkitAudioContext;
            if (AudioCtx && AudioCtx.prototype) {
                const origDecode = AudioCtx.prototype.decodeAudioData;
                AudioCtx.prototype.decodeAudioData = function(buffer, success, error) {
                    const self = this;
                    return new Promise((resolve, reject) => {
                        let settled = false;
                        const timer = setTimeout(() => fallbackSilent(new Error('音频解码超时')), 15000);
                        const complete = (decoded) => {
                            if (settled) return;
                            settled = true;
                            clearTimeout(timer);
                            resolve(decoded);
                            if (success) success(decoded);
                        };
                        const fallbackSilent = (err) => {
                            if (settled) return;
                            console.warn('[Emu Audio] 音频解码失败，使用静音:', err);
                            try {
                                const rate = self.sampleRate || 44100;
                                complete(self.createBuffer(2, Math.max(1, Math.floor(rate * 0.1)), rate));
                            } catch (failure) {
                                settled = true;
                                clearTimeout(timer);
                                reject(failure);
                                if (error) error(failure);
                            }
                        };
                        if (isOggBuffer(buffer) && window.stbvorbis && window.stbvorbis.decode) {
                            try {
                                const copy = buffer.slice(0);
                                Promise.resolve(window.stbvorbis.decode(copy)).then(result => {
                                    if (settled) return;
                                    const audioBuf = self.createBuffer(result.data.length, result.data[0].length, result.sampleRate);
                                    for (let i = 0; i < result.data.length; i++) {
                                        if (audioBuf.copyToChannel) audioBuf.copyToChannel(result.data[i], i);
                                        else audioBuf.getChannelData(i).set(result.data[i]);
                                    }
                                    complete(audioBuf);
                                }).catch(fallbackSilent);
                            } catch (err) { fallbackSilent(err); }
                            return;
                        }
                        try {
                            const decoding = origDecode.call(self, buffer, complete, fallbackSilent);
                            // WebKit may return a Promise in addition to invoking callbacks.
                            if (decoding && decoding.catch) decoding.catch(fallbackSilent);
                        } catch (err) { fallbackSilent(err); }
                    });
                };
            }
        })();
        """
        let audioScript = WKUserScript(source: audioCompatSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(audioScript)
        
        // MARK: - 注入 3：全局手势监听自动解锁 WebAudio
        let unlockScriptSource = """
        (function() {
            const unlockAudio = () => {
                const ctx = (window.WebAudio && window.WebAudio._context) ||
                            (window.AudioManager && window.AudioManager._context) ||
                            (window.SoundManager && window.SoundManager._context);
                if (ctx && ctx.state === 'suspended') {
                    ctx.resume();
                }
            };
            ['touchstart', 'touchend', 'click', 'pointerdown'].forEach(evt => {
                window.addEventListener(evt, unlockAudio, { passive: true });
                document.addEventListener(evt, unlockAudio, { passive: true });
            });
        })();
        """
        let unlockScript = WKUserScript(source: unlockScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(unlockScript)
        
        configuration.userContentController.add(context.coordinator, name: "emuLog")
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        
        DispatchQueue.main.async {
            self.webView = webView
        }
        
        context.coordinator.baseScripts = configuration.userContentController.userScripts
        do {
            guard let runtimeURL = Bundle.main.url(forResource: "GameRuntime", withExtension: "js") else {
                throw CocoaError(.fileNoSuchFile)
            }
            context.coordinator.runtime = try String(contentsOf: runtimeURL, encoding: .utf8)
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        } catch {
            GameLogManager.shared.log("启动脚本读取失败: \(error.localizedDescription)", level: .error)
        }

        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.hideWorkItem?.cancel()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "emuLog")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GameWebView
        var isActive = true
        var hideWorkItem: DispatchWorkItem?
        var baseScripts: [WKUserScript] = []
        var runtime = ""
        private var navigationGeneration = 0
        
        init(_ parent: GameWebView) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isActive else { return }
            if message.name == "emuLog", let dict = message.body as? [String: Any] {
                let levelStr = dict["level"] as? String ?? "info"
                let msg = dict["message"] as? String ?? ""
                
                if levelStr == "ready" || levelStr == "pageReady" {
                    GameLogManager.shared.isGameReady = true
                    GameLogManager.shared.preserveStartupLogs()
                    GameLogManager.shared.log("🎮 \(msg)", level: .success)
                    hideWorkItem?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard self?.isActive == true, GameLogManager.shared.errorCount == 0, !GameLogManager.shared.manuallyOpened else { return }
                        withAnimation(.easeOut(duration: 0.6)) {
                            GameLogManager.shared.isVisible = false
                        }
                    }
                    hideWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                } else {
                    let level: GameLogManager.LogItem.Level
                    switch levelStr {
                    case "error": level = .error
                    case "warning": level = .warning
                    case "success": level = .success
                    case "server": level = .server
                    default: level = .info
                    }
                    if level == .error {
                        hideWorkItem?.cancel()
                        GameLogManager.shared.isVisible = true
                    }
                    GameLogManager.shared.log(msg, level: level)
                }
            }
        }
        
        // Refresh on reload as well: reusing the original snapshot would resurrect
        // old saves after successful writes have already cleared the local journal.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard isActive else { decisionHandler(.cancel); return }
            guard navigationAction.targetFrame?.isMainFrame != false else {
                decisionHandler(.allow)
                return
            }
            guard let target = navigationAction.request.url,
                  target.scheme == parent.url.scheme, target.host == parent.url.host,
                  target.port == parent.url.port else {
                GameLogManager.shared.log("已阻止游戏页面跳转到外部地址", level: .warning)
                decisionHandler(.cancel)
                return
            }
            navigationGeneration += 1
            let generation = navigationGeneration
            hideWorkItem?.cancel()
            GameLogManager.shared.isGameReady = false
            GameLogManager.shared.isVisible = true
            let prepareSnapshot = { [weak self, weak webView] in
                guard let self = self, let webView = webView, self.isActive,
                      self.navigationGeneration == generation else {
                    decisionHandler(.cancel)
                    return
                }
                LocalGameServer.shared.loadBootstrap { [weak self, weak webView] result in
                    guard let self = self, let webView = webView, self.isActive,
                          self.navigationGeneration == generation else {
                        decisionHandler(.cancel)
                        return
                    }
                    do {
                        let data = try result.get()
                        let bootstrap = "window.__emuBootstrap = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(data.base64EncodedString())'), c => c.charCodeAt(0))));\n"
                        let controller = webView.configuration.userContentController
                        controller.removeAllUserScripts()
                        // Logging/runtime first, so failures in later compatibility scripts are captured.
                        controller.addUserScript(WKUserScript(source: bootstrap + self.runtime,
                            injectionTime: .atDocumentStart, forMainFrameOnly: true))
                        self.baseScripts.forEach { controller.addUserScript($0) }
                        decisionHandler(.allow)
                    } catch {
                        GameLogManager.shared.log("存档初始化失败，已停止启动: \(error.localizedDescription)", level: .error)
                        decisionHandler(.cancel)
                    }
                }
            }
            // There is no JavaScript document to flush on first navigation.
            if let current = webView.url, current.scheme == parent.url.scheme,
               current.host == parent.url.host {
                webView.callAsyncJavaScript("if (window.__emuFlushSaves) { await window.__emuFlushSaves(); } return true;",
                                            arguments: [:], in: nil, in: .page) { _ in prepareSnapshot() }
            } else {
                prepareSnapshot()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            GameLogManager.shared.log("正在请求 index.html 网页入口...", level: .server)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            GameLogManager.shared.log("网页加载完成，等待游戏场景就绪...", level: .success)
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            hideWorkItem?.cancel()
            GameLogManager.shared.isVisible = true
            GameLogManager.shared.isGameReady = false
            GameLogManager.shared.log("WebKit 游戏进程已终止，请重新打开游戏", level: .error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            GameLogManager.shared.log("网页渲染中断: \(error.localizedDescription)", level: .error)
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            GameLogManager.shared.log("无法连接本地服务: \(error.localizedDescription)", level: .error)
        }
    }
}

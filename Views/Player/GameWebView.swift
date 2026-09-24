import SwiftUI
import WebKit

/// 经过特化配置的高性能游戏 WebKit 容器（全面集成 OGG 兼容补丁与 WebAudio 保护层）
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
        
        // MARK: - 注入 1：在 DOM 加载最早阶段注入 OGG 格式伪装与 AudioContext 崩溃防护
        let oggAudioCompatSource = """
        (function() {
            // 1. Hook HTML5 Audio canPlayType，强制声明支持 OGG Vorbis
            if (window.HTMLAudioElement && window.HTMLAudioElement.prototype) {
                const origCanPlay = window.HTMLAudioElement.prototype.canPlayType;
                window.HTMLAudioElement.prototype.canPlayType = function(type) {
                    if (type && (type.includes('audio/ogg') || type.includes('vorbis'))) {
                        return 'probably';
                    }
                    return origCanPlay.call(this, type);
                };
            }
            
            // 2. AudioContext decodeAudioData 崩溃保护与静音兜底
            // 避免极端 OGG 采样率在 iOS 解码失败导致游戏引擎全屏报红崩溃
            const AudioCtx = window.AudioContext || window.webkitAudioContext;
            if (AudioCtx && AudioCtx.prototype) {
                const origDecode = AudioCtx.prototype.decodeAudioData;
                AudioCtx.prototype.decodeAudioData = function(buffer, success, error) {
                    return new Promise((resolve, reject) => {
                        origDecode.call(this, buffer, (decoded) => {
                            if (success) success(decoded);
                            resolve(decoded);
                        }, (err) => {
                            console.warn('[Emu Audio] OGG decode failed, applying silent fallback buffer:', err);
                            // 构造 0.1 秒静音 AudioBuffer 防止 RPG Maker 游戏直接崩溃中断
                            try {
                                const fallbackBuf = this.createBuffer(2, this.sampleRate * 0.1, this.sampleRate);
                                if (success) success(fallbackBuf);
                                resolve(fallbackBuf);
                            } catch(e) {
                                if (error) error(err);
                                reject(err);
                            }
                        });
                    });
                };
            }
        })();
        """
        let oggScript = WKUserScript(source: oggAudioCompatSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(oggScript)
        
        // MARK: - 注入 2：页面加载完成后注入 RPG Maker MV/MZ 引擎级 Ogg 开启 Hook
        let engineCompatSource = """
        (function() {
            const meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            document.getElementsByTagName('head')[0]?.appendChild(meta);
            
            // 强制 Hook RPG Maker MV/MZ 引擎中的 canPlayOgg 检测
            const patchEngineOgg = () => {
                if (window.WebAudio) {
                    window.WebAudio.canPlayOgg = function() { return true; };
                }
                if (window.AudioManager) {
                    window.AudioManager._canPlayOgg = true;
                }
            };
            patchEngineOgg();
            window.addEventListener('load', patchEngineOgg);
            
            // 自动激活 WebAudio (绕过 iOS 首触静音保护)
            const unlockAudio = () => {
                if (window.WebAudio && window.WebAudio._context && window.WebAudio._context.state === 'suspended') {
                    window.WebAudio._context.resume();
                }
                window.removeEventListener('touchstart', unlockAudio);
            };
            window.addEventListener('touchstart', unlockAudio, { passive: true });
            
            // 消除网页原生外边距与滚动条
            const style = document.createElement('style');
            style.innerHTML = 'body, html { overflow: hidden !important; margin: 0 !important; background: black !important; }';
            document.head?.appendChild(style);
        })();
        """
        let engineScript = WKUserScript(source: engineCompatSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(engineScript)
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        
        DispatchQueue.main.async {
            self.webView = webView
        }
        
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        webView.load(request)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

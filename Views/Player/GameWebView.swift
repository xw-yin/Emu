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
            
            // 2. AudioContext decodeAudioData 拦截：iOS 原生失败时无缝启用 stbvorbis 软解生成真实 PCM AudioBuffer
            const AudioCtx = window.AudioContext || window.webkitAudioContext;
            if (AudioCtx && AudioCtx.prototype) {
                const origDecode = AudioCtx.prototype.decodeAudioData;
                AudioCtx.prototype.decodeAudioData = function(buffer, success, error) {
                    return new Promise((resolve, reject) => {
                        origDecode.call(this, buffer, (decoded) => {
                            if (success) success(decoded);
                            resolve(decoded);
                        }, (err) => {
                            // 原生解码失败（iOS 无法硬解 OGG Vorbis），调度 stbvorbis WebAssembly 软解引擎
                            if (window.stbvorbis && window.stbvorbis.decode) {
                                window.stbvorbis.decode(buffer).then((result) => {
                                    const channels = result.data.length;
                                    const length = result.data[0].length;
                                    const sampleRate = result.sampleRate;
                                    const audioBuf = this.createBuffer(channels, length, sampleRate);
                                    for (let i = 0; i < channels; i++) {
                                        if (audioBuf.copyToChannel) {
                                            audioBuf.copyToChannel(result.data[i], i);
                                        } else {
                                            audioBuf.getChannelData(i).set(result.data[i]);
                                        }
                                    }
                                    if (success) success(audioBuf);
                                    resolve(audioBuf);
                                }).catch((stbErr) => {
                                    console.error('[Emu Audio] stbvorbis 软解失败:', stbErr);
                                    if (error) error(stbErr);
                                    reject(stbErr);
                                });
                            } else {
                                if (error) error(err);
                                reject(err);
                            }
                        });
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
        
        // MARK: - 注入 4：RPG Maker 引擎级音频嗅探修复与原生磁盘存档双向桥接
        let engineAndStorageCompatSource = """
        (function() {
            // 视口与黑边修饰
            const meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            document.getElementsByTagName('head')[0]?.appendChild(meta);
            
            const style = document.createElement('style');
            style.innerHTML = 'body, html { overflow: hidden !important; margin: 0 !important; background: black !important; }';
            document.head?.appendChild(style);
            
            // 同步 HTTP 请求辅助工具 (专为 MV 同步存档读写定制)
            function httpSync(method, url, data) {
                try {
                    const xhr = new XMLHttpRequest();
                    xhr.open(method, url, false);
                    if (data) {
                        xhr.setRequestHeader('Content-Type', 'text/plain; charset=utf-8');
                    }
                    xhr.send(data || null);
                    return { status: xhr.status, text: xhr.responseText };
                } catch(e) {
                    return { status: 0, text: '' };
                }
            }
            
            const applyEnginePatches = () => {
                // 1. 音频引擎扩展名修补：移动端强制选用 .ogg，并启用 OGG 标志
                if (window.WebAudio) {
                    window.WebAudio.canPlayOgg = function() { return true; };
                }
                if (window.AudioManager) {
                    window.AudioManager._canPlayOgg = true;
                    window.AudioManager.audioFileExt = function() { return '.ogg'; };
                }
                
                // 2. 存档引擎 StorageManager 磁盘化改造 (MV & MZ 统一适配)
                if (window.StorageManager) {
                    window.StorageManager.isLocalMode = function() { return true; };
                    
                    // --- MV 模式 Hook ---
                    if (window.StorageManager.localFilePath) {
                        window.StorageManager.localFileDirectoryPath = function() {
                            return 'save/';
                        };
                        
                        window.StorageManager.localFilePath = function(savefileId) {
                            let name;
                            if (savefileId < 0) {
                                name = 'config.rpgsave';
                            } else if (savefileId === 0) {
                                name = 'global.rpgsave';
                            } else {
                                name = 'file' + savefileId + '.rpgsave';
                            }
                            return this.localFileDirectoryPath() + name;
                        };
                        
                        window.StorageManager.localFileExists = function(savefileId) {
                            const path = this.localFilePath(savefileId);
                            const res = httpSync('HEAD', '/' + path);
                            if (res.status >= 200 && res.status < 300) return true;
                            return this.webStorageExists(savefileId);
                        };
                        
                        window.StorageManager.loadFromLocalFile = function(savefileId) {
                            const path = this.localFilePath(savefileId);
                            const res = httpSync('GET', '/' + path);
                            if (res.status >= 200 && res.status < 300 && res.text) {
                                try {
                                    if (window.LZString) {
                                        const decomp = window.LZString.decompressFromBase64(res.text);
                                        if (decomp) return decomp;
                                    }
                                    return res.text;
                                } catch(e) {
                                    return res.text;
                                }
                            }
                            return this.loadFromWebStorage(savefileId);
                        };
                        
                        window.StorageManager.saveToLocalFile = function(savefileId, json) {
                            const path = this.localFilePath(savefileId);
                            let data = json;
                            if (window.LZString) {
                                data = window.LZString.compressToBase64(json);
                            }
                            httpSync('PUT', '/' + path, data);
                            try {
                                this.saveToWebStorage(savefileId, json);
                            } catch(e) {}
                        };
                        
                        window.StorageManager.removeLocalFile = function(savefileId) {
                            const path = this.localFilePath(savefileId);
                            httpSync('DELETE', '/' + path);
                            try {
                                this.removeWebStorage(savefileId);
                            } catch(e) {}
                        };
                    }
                    
                    // --- MZ 模式 Hook ---
                    if (window.StorageManager.filePath) {
                        window.StorageManager.fileDirectoryPath = function() {
                            return 'save/';
                        };
                        
                        window.StorageManager.filePath = function(saveName) {
                            return this.fileDirectoryPath() + saveName + '.rmmzsave';
                        };
                        
                        window.StorageManager.localFileExists = function(saveName) {
                            const path = '/' + this.filePath(saveName);
                            return fetch(path, { method: 'HEAD' })
                                .then(res => res.ok ? true : this.forageExists(saveName))
                                .catch(() => this.forageExists(saveName));
                        };
                        
                        window.StorageManager.loadFromLocalFile = function(saveName) {
                            const path = '/' + this.filePath(saveName);
                            return fetch(path)
                                .then(res => {
                                    if (!res.ok) throw new Error('File not found');
                                    return res.text();
                                })
                                .catch(() => this.loadFromForage(saveName));
                        };
                        
                        window.StorageManager.saveToLocalFile = function(saveName, zip) {
                            const path = '/' + this.filePath(saveName);
                            fetch(path, { method: 'PUT', body: zip }).catch(() => {});
                            return this.saveToForage(saveName, zip);
                        };
                        
                        window.StorageManager.removeLocalFile = function(saveName) {
                            const path = '/' + this.filePath(saveName);
                            fetch(path, { method: 'DELETE' }).catch(() => {});
                            return this.removeForage(saveName);
                        };
                    }
                }
                
                // 3. 修复 DataManager 存档所有权校验，确保已有磁盘存档能无障碍显示和继续游戏
                if (window.DataManager) {
                    window.DataManager.isThisGameFile = function(savefileId) {
                        const globalInfo = this.loadGlobalInfo();
                        if (globalInfo && globalInfo[savefileId]) {
                            return true;
                        }
                        return false;
                    };
                }
            };
            
            applyEnginePatches();
            window.addEventListener('load', applyEnginePatches);
            // 多次延迟重试确保覆盖第三方插件或晚加载的脚本
            setTimeout(applyEnginePatches, 100);
            setTimeout(applyEnginePatches, 500);
            setTimeout(applyEnginePatches, 1500);
        })();
        """
        let engineScript = WKUserScript(source: engineAndStorageCompatSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
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

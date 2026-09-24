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
        
        // MARK: - 注入 0：Node.js 环境安全沙盒垫片 (防止第三方 PC 插件调用 require/fs 触发崩溃)
        let nodeShimSource = """
        (function() {
            if (typeof window.require === 'undefined') {
                window.require = function(mod) {
                    if (mod === 'fs') {
                        return {
                            existsSync: function() { return false; },
                            readFileSync: function() { return null; },
                            writeFileSync: function() {},
                            mkdirSync: function() {},
                            unlinkSync: function() {},
                            readdirSync: function() { return []; },
                            statSync: function() { return { isDirectory: function() { return false; } }; }
                        };
                    }
                    if (mod === 'path') {
                        return {
                            join: function() { return Array.from(arguments).join('/'); },
                            dirname: function(p) { return p ? p.substring(0, p.lastIndexOf('/')) : ''; },
                            basename: function(p) { return p ? p.substring(p.lastIndexOf('/') + 1) : ''; },
                            extname: function(p) { return p ? p.substring(p.lastIndexOf('.')) : ''; }
                        };
                    }
                    return {};
                };
            }
            if (typeof window.process === 'undefined') {
                window.process = {
                    platform: 'darwin',
                    mainModule: { filename: 'index.html' }
                };
            }
        })();
        """
        let nodeShimScript = WKUserScript(source: nodeShimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(nodeShimScript)
        
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
                        const fallbackSilent = (err) => {
                            try {
                                const fallbackBuf = self.createBuffer(2, Math.max(1, self.sampleRate * 0.1), self.sampleRate || 44100);
                                if (success) success(fallbackBuf);
                                resolve(fallbackBuf);
                            } catch(e) {
                                if (error) error(err);
                                reject(err);
                            }
                        };
                        
                        // 若是 OGG 格式，直接交由 stbvorbis 解码，保护 ArrayBuffer 完整性
                        if (isOggBuffer(buffer)) {
                            if (window.stbvorbis && window.stbvorbis.decode) {
                                try {
                                    const copy = buffer.slice ? buffer.slice(0) : buffer;
                                    window.stbvorbis.decode(copy).then((result) => {
                                        const channels = result.data.length;
                                        const length = result.data[0].length;
                                        const sampleRate = result.sampleRate;
                                        const audioBuf = self.createBuffer(channels, length, sampleRate);
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
                                        console.warn('[Emu Audio] stbvorbis 软解失败，启用静音兜底保护:', stbErr);
                                        fallbackSilent(stbErr);
                                    });
                                    return;
                                } catch(e) {
                                    fallbackSilent(e);
                                    return;
                                }
                            }
                        }
                        
                        // 非 OGG 格式（如 MP3、M4A、WAV），走 iOS 原生硬解
                        try {
                            origDecode.call(self, buffer, (decoded) => {
                                if (success) success(decoded);
                                resolve(decoded);
                            }, (err) => {
                                fallbackSilent(err);
                            });
                        } catch(callErr) {
                            fallbackSilent(callErr);
                        }
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
        
        // MARK: - 注入 4：RPG Maker 引擎级补丁 (防崩溃 + 磁盘存档无缝挂载)
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
                // 1. 音频引擎安全加固：阻断 YEP_X_CoreUpdatesOpt 等插件因单个音频缺失引发的 checkErrors 全屏红字崩溃
                if (window.WebAudio) {
                    window.WebAudio.canPlayOgg = function() { return true; };
                }
                if (window.AudioManager) {
                    window.AudioManager._canPlayOgg = true;
                    window.AudioManager.audioFileExt = function() { return '.ogg'; };
                    // 覆写 checkErrors 与 checkWebAudioError，防止无害的音频告警中断整局游戏循环
                    window.AudioManager.checkErrors = function() {};
                    window.AudioManager.checkWebAudioError = function() {};
                }
                
                // 2. 存档引擎 StorageManager 磁盘挂载（注意：绝不强改 isLocalMode，避免引发第三方插件如 DrillUp 误判）
                if (window.StorageManager) {
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
                            return this.webStorageExists ? this.webStorageExists(savefileId) : false;
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
                            return this.loadFromWebStorage ? this.loadFromWebStorage(savefileId) : null;
                        };
                        
                        window.StorageManager.saveToLocalFile = function(savefileId, json) {
                            const path = this.localFilePath(savefileId);
                            let data = json;
                            if (window.LZString) {
                                data = window.LZString.compressToBase64(json);
                            }
                            httpSync('PUT', '/' + path, data);
                            try {
                                if (this.saveToWebStorage) this.saveToWebStorage(savefileId, json);
                            } catch(e) {}
                        };
                        
                        window.StorageManager.removeLocalFile = function(savefileId) {
                            const path = this.localFilePath(savefileId);
                            httpSync('DELETE', '/' + path);
                            try {
                                if (this.removeWebStorage) this.removeWebStorage(savefileId);
                            } catch(e) {}
                        };
                        
                        // 拦截总入口 load / save / exists，无缝透传到磁盘
                        const origMvLoad = window.StorageManager.load;
                        window.StorageManager.load = function(savefileId) {
                            if (this.localFileExists(savefileId)) {
                                const localData = this.loadFromLocalFile(savefileId);
                                if (localData) return localData;
                            }
                            return origMvLoad ? origMvLoad.call(this, savefileId) : (this.loadFromWebStorage ? this.loadFromWebStorage(savefileId) : null);
                        };
                        
                        const origMvSave = window.StorageManager.save;
                        window.StorageManager.save = function(savefileId, json) {
                            try { this.saveToLocalFile(savefileId, json); } catch(e) {}
                            if (origMvSave) {
                                try { origMvSave.call(this, savefileId, json); } catch(e) {}
                            }
                        };
                        
                        const origMvExists = window.StorageManager.exists;
                        window.StorageManager.exists = function(savefileId) {
                            if (this.localFileExists(savefileId)) return true;
                            return origMvExists ? origMvExists.call(this, savefileId) : (this.webStorageExists ? this.webStorageExists(savefileId) : false);
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
                                .then(res => res.ok ? true : (this.forageExists ? this.forageExists(saveName) : false))
                                .catch(() => this.forageExists ? this.forageExists(saveName) : false);
                        };
                        
                        window.StorageManager.loadFromLocalFile = function(saveName) {
                            const path = '/' + this.filePath(saveName);
                            return fetch(path)
                                .then(res => {
                                    if (!res.ok) throw new Error('File not found');
                                    return res.text();
                                })
                                .catch(() => this.loadFromForage ? this.loadFromForage(saveName) : null);
                        };
                        
                        window.StorageManager.saveToLocalFile = function(saveName, zip) {
                            const path = '/' + this.filePath(saveName);
                            fetch(path, { method: 'PUT', body: zip }).catch(() => {});
                            return this.saveToForage ? this.saveToForage(saveName, zip) : Promise.resolve();
                        };
                        
                        window.StorageManager.removeLocalFile = function(saveName) {
                            const path = '/' + this.filePath(saveName);
                            fetch(path, { method: 'DELETE' }).catch(() => {});
                            return this.removeForage ? this.removeForage(saveName) : Promise.resolve();
                        };
                        
                        const origMzLoadObject = window.StorageManager.loadObject;
                        window.StorageManager.loadObject = function(saveName) {
                            const self = this;
                            return this.localFileExists(saveName).then(exists => {
                                if (exists) {
                                    return self.loadFromLocalFile(saveName)
                                        .then(zip => self.zipToJson(zip))
                                        .then(json => self.jsonToObject(json));
                                } else {
                                    return origMzLoadObject ? origMzLoadObject.call(self, saveName) : Promise.reject();
                                }
                            });
                        };
                        
                        const origMzSaveObject = window.StorageManager.saveObject;
                        window.StorageManager.saveObject = function(saveName, object) {
                            const self = this;
                            return this.objectToJson(object)
                                .then(json => self.jsonToZip(json))
                                .then(zip => self.saveToLocalFile(saveName, zip));
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

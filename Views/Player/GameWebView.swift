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
        
        // MARK: - 注入 0：RPG Maker 核心引擎预拦截与环境安全加固 (atDocumentStart)
        let earlyCompatSource = """
        (function() {
            // 0. 日志与调试捕获通道：将 JS 控制台日志、错误与场景状态实时投递至原生控制台
            function postNativeLog(level, message) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.emuLog) {
                        window.webkit.messageHandlers.emuLog.postMessage({ level: level, message: String(message) });
                    }
                } catch(e) {}
            }
            window._emuPostLog = postNativeLog;
            
            window.onerror = function(msg, url, line, col, error) {
                const file = url ? url.split('/').pop() : 'inline';
                postNativeLog('error', 'JS 错误: ' + msg + ' (' + file + ':' + line + ')');
            };
            
            const origConsoleError = console.error;
            console.error = function() {
                try {
                    const args = Array.from(arguments).map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
                    postNativeLog('error', args);
                } catch(e) {}
                origConsoleError.apply(console, arguments);
            };
            
            const origConsoleWarn = console.warn;
            console.warn = function() {
                try {
                    const args = Array.from(arguments).map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
                    if (args.includes('[Emu') || args.includes('Error') || args.includes('fail') || args.includes('warn')) {
                        postNativeLog('warning', args);
                    }
                } catch(e) {}
                origConsoleWarn.apply(console, arguments);
            };
            
            const origConsoleLog = console.log;
            console.log = function() {
                try {
                    const args = Array.from(arguments).map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
                    if (args.includes('[Emu') || args.includes('RPG') || args.includes('Manager') || args.includes('Scene') || args.includes('load') || args.includes('start') || args.includes('init') || args.includes('Plugin') || args.includes('Data')) {
                        postNativeLog('info', args);
                    }
                } catch(e) {}
                origConsoleLog.apply(console, arguments);
            };
            
            // 监听场景生命周期，感知标题画面或主地图真正就绪
            function monitorSceneLifecycle(sceneClass, sceneName) {
                if (!sceneClass || !sceneClass.prototype) return;
                const origStart = sceneClass.prototype.start;
                if (!origStart || origStart._emuLogged) return;
                const wrapped = function() {
                    postNativeLog('ready', sceneName);
                    return origStart.apply(this, arguments);
                };
                wrapped._emuLogged = true;
                sceneClass.prototype.start = wrapped;
            }
            
            const sceneMonitorInterval = setInterval(function() {
                if (window.Scene_Title) monitorSceneLifecycle(window.Scene_Title, '标题画面 (Scene_Title)');
                if (window.Scene_Map) monitorSceneLifecycle(window.Scene_Map, '游戏地图 (Scene_Map)');
                if (window.Scene_Boot) monitorSceneLifecycle(window.Scene_Boot, '启动引擎 (Scene_Boot)');
                if (window.Scene_Title && window.Scene_Map) clearInterval(sceneMonitorInterval);
            }, 50);
            
            // 1. Utils 兼容打桩
            function patchUtils(u) {
                if (!u || u._emuPatched) return;
                try {
                    u.canReadGameFiles = function() { return true; };
                    u.isNwjs = function() { return false; };
                    u._emuPatched = true;
                    postNativeLog('info', '已注入 Utils 引擎兼容层');
                } catch(e) {}
            }
            
            // 2. SceneManager 启动自检加固（彻底免疫 WebGL 检测报错与空抛异常）
            function patchSceneManager(sm) {
                if (!sm || sm._emuPatched) return;
                try {
                    sm.checkFileAccess = function() {};
                    sm.checkPluginErrors = function() {};
                    sm.checkWebGL = function() {};
                    sm._emuPatched = true;
                    postNativeLog('info', '已注入 SceneManager 自检保护层');
                } catch(e) {}
            }
            
            // 3. PluginManager 异常熔断
            function patchPluginManager(pm) {
                if (!pm || pm._emuPatched) return;
                try {
                    pm._errorUrls = [];
                    pm.checkErrors = function() { this._errorUrls = []; };
                    pm.onError = function(e) {
                        console.warn('[Emu] 忽略插件加载失败:', e?.target?.src || e);
                    };
                    pm._emuPatched = true;
                    postNativeLog('info', '已注入 PluginManager 容错层');
                } catch(e) {}
            }
            
            // 4. AudioManager 音频支持声明
            function patchAudioManager(am) {
                if (!am || am._emuPatched) return;
                try {
                    am._canPlayOgg = true;
                    am.checkErrors = function() {};
                    am.checkWebAudioError = function() {};
                    am._emuPatched = true;
                    postNativeLog('info', '已注入 AudioManager 音频支持');
                } catch(e) {}
            }
            
            // 5. DataManager 监控数据库载入进度
            function patchDataManager(dm) {
                if (!dm || dm._emuPatched) return;
                try {
                    const origOnLoad = dm.onLoad;
                    if (origOnLoad && !origOnLoad._emuWrapped) {
                        dm.onLoad = function(object) {
                            try {
                                const name = object ? (object.constructor ? object.constructor.name : '数据') : '数据';
                                postNativeLog('info', '数据载入就绪: ' + name);
                            } catch(e) {}
                            return origOnLoad.apply(this, arguments);
                        };
                        dm.onLoad._emuWrapped = true;
                    }
                    dm._emuPatched = true;
                } catch(e) {}
            }
            
            // 6. Game_Map 核心保护
            function patchGameMap(gm) {
                if (!gm || !gm.prototype || gm._emuPatched) return;
                try {
                    gm.prototype.width = function() {
                        return (window.$dataMap && window.$dataMap.width) ? window.$dataMap.width : 20;
                    };
                    gm.prototype.height = function() {
                        return (window.$dataMap && window.$dataMap.height) ? window.$dataMap.height : 15;
                    };
                    gm.prototype.data = function() {
                        return (window.$dataMap && window.$dataMap.data) ? window.$dataMap.data : [];
                    };
                    gm.prototype.isLoopHorizontal = function() {
                        return (window.$dataMap && window.$dataMap.scrollType) ? (window.$dataMap.scrollType === 2 || window.$dataMap.scrollType === 3) : false;
                    };
                    gm.prototype.isLoopVertical = function() {
                        return (window.$dataMap && window.$dataMap.scrollType) ? (window.$dataMap.scrollType === 1 || window.$dataMap.scrollType === 3) : false;
                    };
                    gm.prototype.adjustX = function(x) {
                        const w = (window.$dataMap && window.$dataMap.width) ? window.$dataMap.width : 20;
                        if (this.isLoopHorizontal && this.isLoopHorizontal() && x < this._displayX - (this.width() - this.screenTileX()) / 2) {
                            return x - this._displayX + w;
                        } else {
                            return x - this._displayX;
                        }
                    };
                    gm.prototype.adjustY = function(y) {
                        const h = (window.$dataMap && window.$dataMap.height) ? window.$dataMap.height : 15;
                        if (this.isLoopVertical && this.isLoopVertical() && y < this._displayY - (this.height() - this.screenTileY()) / 2) {
                            return y - this._displayY + h;
                        } else {
                            return y - this._displayY;
                        }
                    };
                    gm.prototype.events = function() {
                        return (this._events && Array.isArray(this._events)) ? this._events.filter(function(event) {
                            return !!event;
                        }) : [];
                    };
                    gm.prototype.event = function(eventId) {
                        return (this._events && this._events[eventId]) ? this._events[eventId] : null;
                    };
                    gm._emuPatched = true;
                } catch(e) {}
            }
            
            // 7. Game_System 存档校验加固
            function patchGameSystem(gs) {
                if (!gs || !gs.prototype || gs._emuPatched) return;
                try {
                    for (const key of Object.getOwnPropertyNames(gs.prototype)) {
                        if (key.includes('checkSysData') && typeof gs.prototype[key] === 'function' && !gs.prototype[key]._emuWrapped) {
                            const orig = gs.prototype[key];
                            const wrapped = function() {
                                try {
                                    return orig.apply(this, arguments);
                                } catch(err) {
                                    console.warn('[Emu] 拦截并跳过插件存档校验异常 (' + key + '):', err);
                                }
                            };
                            wrapped._emuWrapped = true;
                            gs.prototype[key] = wrapped;
                        }
                    }
                    gs._emuPatched = true;
                } catch(e) {}
            }
            
            // 8. Scene_Map 进图淡入保护
            function patchSceneMap(sm) {
                if (!sm || !sm.prototype || sm._emuPatched) return;
                try {
                    const origStart = sm.prototype.start;
                    if (origStart && !origStart._emuWrapped) {
                        const wrappedStart = function() {
                            try {
                                origStart.apply(this, arguments);
                            } catch(err) {
                                console.warn('[Emu] Scene_Map.start 异常:', err);
                            }
                            if (this._fadeSprite && this._fadeSprite.opacity > 0) {
                                this.startFadeIn(this.fadeSpeed ? this.fadeSpeed() : 24, false);
                            }
                        };
                        wrappedStart._emuWrapped = true;
                        sm.prototype.start = wrappedStart;
                    }
                    sm._emuPatched = true;
                } catch(e) {}
            }
            
            // 9. ImageManager 容错
            function patchImageManager(im) {
                if (!im || im._emuPatched) return;
                try {
                    im.throwLoadError = function(bitmap) {
                        console.warn('[Emu] 忽略缺失图片加载失败:', bitmap ? (bitmap._url || bitmap.url) : 'unknown');
                        if (bitmap) {
                            bitmap._hasError = false;
                            bitmap._isLoading = false;
                        }
                    };
                    im._emuPatched = true;
                } catch(e) {}
            }
            
            window._emuPatchGameMap = patchGameMap;
            window._emuPatchGameSystem = patchGameSystem;
            window._emuPatchSceneMap = patchSceneMap;
            window._emuPatchImageManager = patchImageManager;
            
            // 10. 定时巡检保护（在脚本加载前期持续挂载补丁，绝不影响 JS 引擎原型声明）
            const checkTimer = setInterval(function() {
                if (window.Utils) patchUtils(window.Utils);
                if (window.SceneManager) patchSceneManager(window.SceneManager);
                if (window.PluginManager) patchPluginManager(window.PluginManager);
                if (window.AudioManager) patchAudioManager(window.AudioManager);
                if (window.DataManager) patchDataManager(window.DataManager);
                if (window.ImageManager) patchImageManager(window.ImageManager);
                if (window.Game_Map) patchGameMap(window.Game_Map);
                if (window.Game_System) patchGameSystem(window.Game_System);
                if (window.Scene_Map) patchSceneMap(window.Scene_Map);
            }, 20);
            setTimeout(function() { clearInterval(checkTimer); }, 15000);
        })();
        """
        let earlyCompatScript = WKUserScript(source: earlyCompatSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(earlyCompatScript)
        
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
            
            // 全局内存存档秒开预热缓存 (彻底避免读取存档时因网络阻塞死锁)
            window._emuSaveCache = window._emuSaveCache || {};
            try {
                fetch('/_emu/saves')
                    .then(r => r.json())
                    .then(saves => {
                        for (const k in saves) {
                            window._emuSaveCache[k] = saves[k];
                        }
                        console.log('[Emu Save] 成功预热内存存档缓存，加载存档数量:', Object.keys(window._emuSaveCache).length);
                    })
                    .catch(() => {});
            } catch(e) {}
            
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
                // 1. 核心运行环境安全加固：彻底禁用 local file 校验、插件缺失中断与纠正 NW.js 环境假阳性
                if (window.Utils) {
                    window.Utils.canReadGameFiles = function() { return true; };
                    window.Utils.isNwjs = function() { return false; };
                }
                if (window.PluginManager) {
                    window.PluginManager._errorUrls = [];
                    window.PluginManager.checkErrors = function() { this._errorUrls = []; };
                }
                if (window.SceneManager) {
                    window.SceneManager.checkFileAccess = function() {};
                    window.SceneManager.checkPluginErrors = function() {};
                    window.SceneManager.checkWebGL = function() {};
                }
                
                // 2. 音频引擎安全加固：阻断 YEP_X_CoreUpdatesOpt 等插件因单个音频缺失引发的 checkErrors 全屏红字崩溃
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
                            const fileName = path.split('/').pop();
                            if (window._emuSaveCache && (window._emuSaveCache[fileName] || window._emuSaveCache[path])) {
                                return true;
                            }
                            const res = httpSync('HEAD', '/' + path);
                            if (res.status >= 200 && res.status < 300) return true;
                            return this.webStorageExists ? this.webStorageExists(savefileId) : false;
                        };
                        
                        window.StorageManager.loadFromLocalFile = function(savefileId) {
                            const path = this.localFilePath(savefileId);
                            const fileName = path.split('/').pop();
                            
                            // 1. 优先命中内存高速缓存 (0 毫秒秒出，彻底消除主线程挂死)
                            let content = (window._emuSaveCache && (window._emuSaveCache[fileName] || window._emuSaveCache[path])) || null;
                            
                            // 2. 缓存未命中时走同步请求兜底
                            if (!content) {
                                const res = httpSync('GET', '/' + path);
                                if (res.status >= 200 && res.status < 300 && res.text) {
                                    content = res.text;
                                    window._emuSaveCache[fileName] = content;
                                }
                            }
                            
                            if (content) {
                                const text = content.trim();
                                if (text.startsWith('{') || text.startsWith('[')) {
                                    return text;
                                }
                                try {
                                    if (window.LZString) {
                                        const decomp = window.LZString.decompressFromBase64(text);
                                        if (decomp) return decomp;
                                    }
                                    return text;
                                } catch(e) {
                                    return text;
                                }
                            }
                            return this.loadFromWebStorage ? this.loadFromWebStorage(savefileId) : null;
                        };
                        
                        window.StorageManager.saveToLocalFile = function(savefileId, json) {
                            const path = this.localFilePath(savefileId);
                            const fileName = path.split('/').pop();
                            let data = json;
                            if (window.LZString) {
                                data = window.LZString.compressToBase64(json);
                            }
                            // 内存秒存
                            window._emuSaveCache[fileName] = data;
                            // 异步刷入磁盘
                            try {
                                fetch('/' + path, { method: 'PUT', body: data }).catch(() => {});
                            } catch(e) {}
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
                
                // 3. 修复 DataManager 存档所有权校验与解包容错，确保已有磁盘存档能无障碍读取与恢复
                if (window.DataManager) {
                    window.DataManager.isThisGameFile = function(savefileId) {
                        const globalInfo = this.loadGlobalInfo();
                        if (globalInfo && globalInfo[savefileId]) {
                            return true;
                        }
                        if (window.StorageManager && window.StorageManager.localFileExists) {
                            return window.StorageManager.localFileExists(savefileId);
                        }
                        return false;
                    };
                    
                    if (!window.DataManager._emuExtractHooked) {
                        const origExtract = window.DataManager.extractSaveContents;
                        window.DataManager.extractSaveContents = function(contents) {
                            if (!contents) return;
                            
                            // 确保核心全局对象在执行插件钩子链前安全还原
                            if (contents.system) window.$gameSystem = contents.system;
                            if (contents.screen) window.$gameScreen = contents.screen;
                            if (contents.timer) window.$gameTimer = contents.timer;
                            if (contents.switches) window.$gameSwitches = contents.switches;
                            if (contents.variables) window.$gameVariables = contents.variables;
                            if (contents.selfSwitches) window.$gameSelfSwitches = contents.selfSwitches;
                            if (contents.actors) window.$gameActors = contents.actors;
                            if (contents.party) window.$gameParty = contents.party;
                            if (contents.map) window.$gameMap = contents.map;
                            if (contents.player) window.$gamePlayer = contents.player;
                            
                            if (window._emuPatchGameMap && window.Game_Map) window._emuPatchGameMap(window.Game_Map);
                            if (window._emuPatchGameSystem && window.Game_System) window._emuPatchGameSystem(window.Game_System);
                            if (window._emuPatchSceneMap && window.Scene_Map) window._emuPatchSceneMap(window.Scene_Map);
                            if (window._emuPatchImageManager && window.ImageManager) window._emuPatchImageManager(window.ImageManager);
                            
                            // 虚拟提供基础 $dataMap，防止第三方插件在读档检查时访问 $dataMap 属性抛错中断
                            const hadDataMap = !!window.$dataMap;
                            if (!hadDataMap) {
                                window.$dataMap = {
                                    width: (window.$gameMap && typeof window.$gameMap.width === 'function' ? window.$gameMap.width() : 20) || 20,
                                    height: (window.$gameMap && typeof window.$gameMap.height === 'function' ? window.$gameMap.height() : 15) || 15,
                                    data: [],
                                    events: [null],
                                    scrollType: 0,
                                    tilesetId: 1
                                };
                            }
                            
                            try {
                                if (origExtract) origExtract.call(this, contents);
                            } catch(err) {
                                console.warn('[Emu] 捕获 extractSaveContents 异常并安全恢复:', err);
                            } finally {
                                if (!hadDataMap) {
                                    window.$dataMap = null;
                                }
                            }
                        };
                        window.DataManager._emuExtractHooked = true;
                    }
                }
                
                // 4. 主动应用补丁
                if (window._emuPatchGameMap && window.Game_Map) window._emuPatchGameMap(window.Game_Map);
                if (window._emuPatchGameSystem && window.Game_System) window._emuPatchGameSystem(window.Game_System);
                if (window._emuPatchSceneMap && window.Scene_Map) window._emuPatchSceneMap(window.Scene_Map);
                if (window._emuPatchImageManager && window.ImageManager) window._emuPatchImageManager(window.ImageManager);
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
        
        // 清理 WebKit 本地磁盘与内存缓存，确保不会命中此前因 500 异常残留的错误脚本缓存
        WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date(timeIntervalSince1970: 0)) {}
        
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        webView.load(request)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GameWebView
        
        init(_ parent: GameWebView) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "emuLog", let dict = message.body as? [String: Any] {
                let levelStr = dict["level"] as? String ?? "info"
                let msg = dict["message"] as? String ?? ""
                
                if levelStr == "ready" {
                    GameLogManager.shared.isGameReady = true
                    GameLogManager.shared.log("🎮 \(msg) 启动成功，进入世界！", level: .success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.easeOut(duration: 0.6)) {
                            GameLogManager.shared.isVisible = false
                        }
                    }
                } else {
                    let level: GameLogManager.LogItem.Level
                    switch levelStr {
                    case "error": level = .error
                    case "warning": level = .warning
                    case "success": level = .success
                    case "server": level = .server
                    default: level = .info
                    }
                    GameLogManager.shared.log(msg, level: level)
                }
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            GameLogManager.shared.log("正在请求 index.html 网页入口...", level: .server)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            GameLogManager.shared.log("index.html 解析完毕，开始执行游戏脚本链...", level: .success)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            GameLogManager.shared.log("网页渲染中断: \(error.localizedDescription)", level: .error)
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            GameLogManager.shared.log("无法连接本地服务: \(error.localizedDescription)", level: .error)
        }
    }
}

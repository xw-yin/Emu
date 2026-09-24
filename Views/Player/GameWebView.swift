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
            // 1. 确保 window.Utils 无论何时被定义或重写，canReadGameFiles 恒为 true，isNwjs 恒为 false
            function patchUtils(u) {
                if (!u) return;
                try {
                    Object.defineProperty(u, 'canReadGameFiles', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() { return true; }; },
                        set: function() {}
                    });
                    Object.defineProperty(u, 'isNwjs', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() { return false; }; },
                        set: function() {}
                    });
                } catch(e) {}
            }
            
            let _Utils = window.Utils;
            patchUtils(_Utils);
            try {
                Object.defineProperty(window, 'Utils', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _Utils; },
                    set: function(val) {
                        _Utils = val;
                        patchUtils(_Utils);
                    }
                });
            } catch(e) {}
            
            // 2. 确保 window.SceneManager 无论何时被定义，checkFileAccess、checkPluginErrors、checkWebGL 恒为空函数（彻底免疫启动自检崩溃）
            function patchSceneManager(sm) {
                if (!sm) return;
                try {
                    Object.defineProperty(sm, 'checkFileAccess', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() {}; },
                        set: function() {}
                    });
                    Object.defineProperty(sm, 'checkPluginErrors', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() {}; },
                        set: function() {}
                    });
                    Object.defineProperty(sm, 'checkWebGL', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() {}; },
                        set: function() {}
                    });
                } catch(e) {}
            }
            
            let _SceneManager = window.SceneManager;
            patchSceneManager(_SceneManager);
            try {
                Object.defineProperty(window, 'SceneManager', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _SceneManager; },
                    set: function(val) {
                        _SceneManager = val;
                        patchSceneManager(_SceneManager);
                    }
                });
            } catch(e) {}

            // 3. 确保 window.PluginManager 无论何时被定义，checkErrors 恒为空函数，消除单个插件缺失阻断启动
            function patchPluginManager(pm) {
                if (!pm) return;
                try {
                    pm._errorUrls = [];
                    Object.defineProperty(pm, 'checkErrors', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() { this._errorUrls = []; }; },
                        set: function() {}
                    });
                    pm.onError = function(e) {
                        console.warn('[Emu] 忽略插件加载失败:', e?.target?.src || e);
                    };
                } catch(e) {}
            }
            
            let _PluginManager = window.PluginManager;
            patchPluginManager(_PluginManager);
            try {
                Object.defineProperty(window, 'PluginManager', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _PluginManager; },
                    set: function(val) {
                        _PluginManager = val;
                        patchPluginManager(_PluginManager);
                    }
                });
            } catch(e) {}
            
            // 4. 确保 window.AudioManager 提前拦截 checkErrors 与 checkWebAudioError
            function patchAudioManager(am) {
                if (!am) return;
                try {
                    am._canPlayOgg = true;
                    Object.defineProperty(am, 'checkErrors', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() {}; },
                        set: function() {}
                    });
                    Object.defineProperty(am, 'checkWebAudioError', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return function() {}; },
                        set: function() {}
                    });
                } catch(e) {}
            }
            
            let _AudioManager = window.AudioManager;
            patchAudioManager(_AudioManager);
            try {
                Object.defineProperty(window, 'AudioManager', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _AudioManager; },
                    set: function(val) {
                        _AudioManager = val;
                        patchAudioManager(_AudioManager);
                    }
                });
            } catch(e) {}

            // 5. 核心存档安全加固：确保 Game_Map 在 $dataMap 为空时访问 width/height/adjustX/adjustY/events 不崩溃
            function patchGameMap(gm) {
                if (!gm || !gm.prototype) return;
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
                } catch(e) {}
            }
            
            let _Game_Map = window.Game_Map;
            patchGameMap(_Game_Map);
            try {
                Object.defineProperty(window, 'Game_Map', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _Game_Map; },
                    set: function(val) {
                        _Game_Map = val;
                        patchGameMap(_Game_Map);
                    }
                });
            } catch(e) {}

            // 6. 存档数据校验安全加固：保护所有 DrillUp 插件的 checkSysData 不中断读档
            function patchGameSystem(gs) {
                if (!gs || !gs.prototype) return;
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
                } catch(e) {}
            }

            let _Game_System = window.Game_System;
            patchGameSystem(_Game_System);
            try {
                Object.defineProperty(window, 'Game_System', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _Game_System; },
                    set: function(val) {
                        _Game_System = val;
                        patchGameSystem(_Game_System);
                    }
                });
            } catch(e) {}

            // 7. 场景切换安全加固：防止读档进入 Scene_Map 时因黑屏遮罩未清除或资源加载阻断导致画面卡死假象
            function patchSceneMap(sm) {
                if (!sm || !sm.prototype) return;
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
                    
                    let mapReadyWaitCount = 0;
                    const origIsReady = sm.prototype.isReady;
                    if (origIsReady && !origIsReady._emuWrapped) {
                        const wrappedMapIsReady = function() {
                            const ready = origIsReady.call(this);
                            if (ready) {
                                mapReadyWaitCount = 0;
                                return true;
                            }
                            mapReadyWaitCount++;
                            // 若地图等待就绪超过 90 帧 (~1.5 秒)，强制补全空地图并启动，彻底杜绝黑屏死锁
                            if (mapReadyWaitCount > 90) {
                                console.warn('[Emu] Scene_Map 就绪超时，强制启动地图');
                                if (!this._mapLoaded) {
                                    if (!window.$dataMap) {
                                        window.$dataMap = { width: 20, height: 15, data: [], events: [null], scrollType: 0, tilesetId: 1 };
                                    }
                                    try { this.onMapLoaded(); } catch(e) {}
                                    this._mapLoaded = true;
                                }
                                mapReadyWaitCount = 0;
                                return true;
                            }
                            return false;
                        };
                        wrappedMapIsReady._emuWrapped = true;
                        sm.prototype.isReady = wrappedMapIsReady;
                    }
                } catch(e) {}
            }
            
            let _Scene_Map = window.Scene_Map;
            patchSceneMap(_Scene_Map);
            try {
                Object.defineProperty(window, 'Scene_Map', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _Scene_Map; },
                    set: function(val) {
                        _Scene_Map = val;
                        patchSceneMap(_Scene_Map);
                    }
                });
            } catch(e) {}

            // 8. 资源加载保护：杜绝单张缺失图片引发 ImageManager 崩溃或阻断 isReady
            function patchImageManager(im) {
                if (!im) return;
                try {
                    im.throwLoadError = function(bitmap) {
                        console.warn('[Emu] 忽略缺失图片加载失败:', bitmap ? (bitmap._url || bitmap.url) : 'unknown');
                        if (bitmap) {
                            bitmap._hasError = false;
                            bitmap._isLoading = false;
                            bitmap._loadingState = 'loaded';
                        }
                    };
                    
                    let isReadyWaitCount = 0;
                    const origIsReady = im.isReady;
                    if (origIsReady && !origIsReady._emuWrapped) {
                        const wrappedIsReady = function() {
                            const ready = origIsReady.call(this);
                            if (ready) {
                                isReadyWaitCount = 0;
                                return true;
                            }
                            isReadyWaitCount++;
                            // 保护：等待图片资源就绪若超过 90 帧 (~1.5 秒)，强制放行进图
                            if (isReadyWaitCount > 90) {
                                console.warn('[Emu] 图片加载等待超时，强制放行启动');
                                isReadyWaitCount = 0;
                                return true;
                            }
                            return false;
                        };
                        wrappedIsReady._emuWrapped = true;
                        im.isReady = wrappedIsReady;
                    }
                } catch(e) {}
            }
            let _ImageManager = window.ImageManager;
            patchImageManager(_ImageManager);
            try {
                Object.defineProperty(window, 'ImageManager', {
                    configurable: true,
                    enumerable: true,
                    get: function() { return _ImageManager; },
                    set: function(val) {
                        _ImageManager = val;
                        patchImageManager(_ImageManager);
                    }
                });
            } catch(e) {}

            window._emuPatchGameMap = patchGameMap;
            window._emuPatchGameSystem = patchGameSystem;
            window._emuPatchSceneMap = patchSceneMap;
            window._emuPatchImageManager = patchImageManager;
            
            // 9. 全局异常可视化浮动条（在真机无控制台环境下直观定位脚本错误，杜绝静默卡死）
            function showErrorBanner(msg) {
                try {
                    let el = document.getElementById('_emu_err_banner');
                    if (!el) {
                        el = document.createElement('div');
                        el.id = '_emu_err_banner';
                        el.style.cssText = 'position:fixed;top:6px;left:8px;right:8px;background:rgba(220,20,60,0.9);color:#fff;font-size:11px;line-height:1.4;padding:6px 10px;border-radius:6px;z-index:999999;word-break:break-all;pointer-events:none;font-family:sans-serif;box-shadow:0 2px 8px rgba(0,0,0,0.5);';
                        (document.body || document.documentElement).appendChild(el);
                    }
                    el.textContent = '[Emu 调试] ' + msg;
                    setTimeout(() => { if (el && el.parentNode) el.remove(); }, 8000);
                } catch(e) {}
            }
            window.addEventListener('error', function(e) {
                if (e && e.message) showErrorBanner(e.message);
            });
            window.addEventListener('unhandledrejection', function(e) {
                if (e && e.reason) showErrorBanner(e.reason.message || String(e.reason));
            });

            // 10. 定时巡检保护（在脚本加载前期持续监控补丁状态）
            const checkTimer = setInterval(function() {
                if (window.Utils) patchUtils(window.Utils);
                if (window.SceneManager) patchSceneManager(window.SceneManager);
                if (window.PluginManager) patchPluginManager(window.PluginManager);
                if (window.AudioManager) patchAudioManager(window.AudioManager);
                if (window.ImageManager) patchImageManager(window.ImageManager);
                if (window.Game_Map) patchGameMap(window.Game_Map);
                if (window.Game_System) patchGameSystem(window.Game_System);
                if (window.Scene_Map) patchSceneMap(window.Scene_Map);
            }, 25);
            setTimeout(function() { clearInterval(checkTimer); }, 10000);
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
            
            // 同步 HTTP 请求辅助工具 (专为 MV 同步存档读写定制，附带 1.5 秒硬超时防御)
            function httpSync(method, url, data) {
                try {
                    const xhr = new XMLHttpRequest();
                    xhr.open(method, url, false);
                    xhr.timeout = 1500;
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

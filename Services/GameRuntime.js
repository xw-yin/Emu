/* Injected at document start, after the native save snapshot. No engine globals
 * are declared/replaced before the game's own scripts have defined them. */
(function () {
    'use strict';
    const bootstrap = window.__emuBootstrap;
    if (!bootstrap) throw new Error('Emu save snapshot is missing');
    const cache = Object.assign(Object.create(null), bootstrap.saves);
    const prefix = 'emu.pending.' + bootstrap.namespace + '.';
    const pending = Object.create(null);
    const queues = new Map();
    let ready = false;
    let failed = false;

    function describe(value) {
        if (value && value.stack) return String(value.stack);
        if (value && value.message) return String(value.message);
        if (typeof value === 'string') return value;
        try { return JSON.stringify(value); } catch (_) { return String(value); }
    }
    function log(level, message) {
        if (level === 'error') failed = true;
        try { window.webkit?.messageHandlers?.emuLog?.postMessage({level, message: String(message)}); }
        catch (_) { /* The native handler can disappear during navigation teardown. */ }
    }
    for (const level of ['log', 'warn', 'error']) {
        const original = console[level];
        console[level] = function (...args) {
            log(level === 'warn' ? 'warning' : level === 'error' ? 'error' : 'info', args.map(describe).join(' '));
            original.apply(console, args);
        };
    }
    window.addEventListener('error', event => {
        const target = event.target;
        log('error', event.message ? describe(event.error || event.message) :
            '资源加载失败: ' + (target?.src || target?.href || 'unknown'));
    }, true);
    window.addEventListener('unhandledrejection', event => log('error', '异步错误: ' + describe(event.reason)));

    function validName(name) {
        if (typeof name !== 'string' || !/^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/.test(name)) {
            throw new Error('Invalid save name: ' + name);
        }
        return name;
    }
    const has = name => Object.prototype.hasOwnProperty.call(cache, name);
    function update(name, value) {
        if (value === null) delete cache[name];
        else cache[name] = value;
    }
    async function request(name, value) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10000);
        try {
            const response = await fetch('/save/' + encodeURIComponent(name), {
                method: value === null ? 'DELETE' : 'PUT',
                headers: {'Content-Type': 'text/plain; charset=utf-8', 'X-Emu-Session': bootstrap.session},
                body: value === null ? undefined : value,
                signal: controller.signal
            });
            if (!response.ok) throw new Error('HTTP ' + response.status);
        } finally { clearTimeout(timeout); }
    }
    function enqueue(name, operation) {
        const previous = queues.get(name) || Promise.resolve();
        const next = previous.catch(() => {}).then(operation);
        queues.set(name, next);
        const cleanup = () => { if (queues.get(name) === next) queues.delete(name); };
        next.then(cleanup, cleanup);
        return next;
    }
    window.__emuFlushSaves = () => Promise.allSettled([...queues.values()]);
    function flush(name, value) {
        return enqueue(name, async () => {
            await request(name, value);
            // An older completed write must not remove a newer pending write.
            if (pending[name] === value) {
                localStorage.removeItem(prefix + name);
                delete pending[name];
            }
        }).catch(error => {
            log('error', '存档未写回磁盘（已保留本地副本）: ' + name + ': ' + describe(error));
        });
    }
    function writeMV(name, value) {
        // MV's API is synchronous. Journal first, then acknowledge to the engine.
        // Quota/security errors propagate instead of falsely reporting success.
        localStorage.setItem(prefix + name, JSON.stringify(value));
        pending[name] = value;
        update(name, value);
        flush(name, value);
    }
    try {
        for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            if (!key.startsWith(prefix)) continue;
            try {
                const name = validName(key.slice(prefix.length));
                const value = JSON.parse(localStorage.getItem(key));
                if (value !== null && typeof value !== 'string') throw new Error('Invalid pending save: ' + name);
                pending[name] = value;
                update(name, value);
            } catch (error) { log('error', '待写回记录损坏: ' + key + ': ' + describe(error)); }
        }
        for (const name of Object.keys(pending)) flush(name, pending[name]);
    } catch (error) { log('error', '无法恢复待写回存档: ' + describe(error)); }
    log('info', '存档快照已就绪（游戏脚本执行前），文件数: ' + Object.keys(cache).length);

    function mvName(id) {
        if (!Number.isInteger(id)) throw new Error('Invalid save ID: ' + id);
        return id < 0 ? 'config.rpgsave' : id === 0 ? 'global.rpgsave' : 'file' + id + '.rpgsave';
    }
    function readMV(id) {
        const name = mvName(id);
        if (!has(name)) return null;
        const raw = cache[name];
        const trimmed = raw.trim();
        const json = /^[\[{]/.test(trimmed) ? trimmed : window.LZString.decompressFromBase64(raw);
        if (!json) throw new Error('存档解压失败: ' + name);
        // Validate here so corrupt config/global data gets a filename in the log.
        try { JSON.parse(json); } catch (_) { throw new Error('存档 JSON 无效: ' + name); }
        return json;
    }
    function migrateMV(sm) {
        // Old versions also saved to shared browser keys. Only import entries
        // whose title/globalId match this game, and never overwrite disk saves.
        const marker = 'emu.migrated.' + bootstrap.namespace;
        if (!bootstrap.gameTitle || !sm.webStorageKey || !window.DataManager) return;
        try {
            if (localStorage.getItem(marker)) return;
            const raw = localStorage.getItem(sm.webStorageKey(0));
            if (!raw) return;
            const legacy = JSON.parse(window.LZString.decompressFromBase64(raw));
            if (!Array.isArray(legacy)) return;
            const info = has('global.rpgsave') ? JSON.parse(readMV(0)) : [];
            if (!Array.isArray(info)) throw new Error('global.rpgsave 必须是存档索引数组');
            let imported = false;
            for (let id = 1; id < legacy.length; id++) {
                if (legacy[id]?.title !== bootstrap.gameTitle || legacy[id]?.globalId !== window.DataManager._globalId) continue;
                const name = mvName(id);
                if (!has(name)) {
                    const content = localStorage.getItem(sm.webStorageKey(id));
                    if (!content) continue;
                    JSON.parse(window.LZString.decompressFromBase64(content));
                    writeMV(name, content);
                    imported = true;
                }
                if (!info[id]) {
                    info[id] = legacy[id];
                    imported = true;
                }
            }
            if (imported) {
                writeMV('global.rpgsave', window.LZString.compressToBase64(JSON.stringify(info)));
                // The per-game journal is already durable, even if disk flush fails.
                localStorage.setItem(marker, '1');
                log('info', '已恢复属于本游戏的旧浏览器存档');
            }
        } catch (error) { log('error', '旧浏览器存档恢复失败: ' + describe(error)); }
    }
    function installStorage() {
        const sm = window.StorageManager;
        if (!sm || sm.__emuStorage) return;
        const mv = window.Utils?.RPGMAKER_NAME !== 'MZ' && typeof sm.load === 'function' && typeof sm.save === 'function' && typeof sm.localFilePath === 'function';
        const mz = typeof sm.loadZip === 'function' && typeof sm.saveZip === 'function';
        if (!mv && !mz) return; // Wait until the managers script has finished.
        if (mv) {
            migrateMV(sm);
            sm.load = sm.loadFromLocalFile = readMV;
            sm.save = sm.saveToLocalFile = function (id, json) {
                JSON.parse(json);
                writeMV(mvName(id), window.LZString.compressToBase64(json));
            };
            sm.exists = sm.localFileExists = id => has(mvName(id));
            sm.remove = sm.removeLocalFile = id => writeMV(mvName(id), null);
            sm.backup = id => {
                const name = mvName(id);
                if (has(name)) writeMV(name + '.bak', cache[name]);
            };
            sm.backupExists = id => has(mvName(id) + '.bak');
            sm.cleanBackup = id => writeMV(mvName(id) + '.bak', null);
            sm.restoreBackup = id => {
                const name = mvName(id);
                if (has(name + '.bak')) {
                    writeMV(name, cache[name + '.bak']);
                    writeMV(name + '.bak', null);
                }
            };
        } else {
            const nameFor = name => validName(name).toLowerCase() + '.rmmzsave';
            // Keep the engine's IndexedDB key initialization and codecs intact.
            // Its forage keys include the game's ID, unlike MV's legacy keys.
            sm.loadZip = sm.loadFromLocalFile = async name => {
                const file = nameFor(name);
                if (queues.has(file)) await queues.get(file);
                if (!has(file)) {
                    if (sm.loadFromForage) return sm.loadFromForage(name);
                    throw new Error('存档不存在: ' + file);
                }
                return cache[file];
            };
            sm.saveZip = sm.saveToLocalFile = (name, zip) => {
                const file = nameFor(name);
                return enqueue(file, async () => {
                    await request(file, zip);
                    update(file, zip);
                }).catch(error => {
                    log('error', '保存失败: ' + file + ': ' + describe(error));
                    throw error;
                });
            };
            // MZ exists/localFileExists are synchronous booleans, not Promises.
            sm.exists = sm.localFileExists = name => has(nameFor(name)) || !!sm.forageExists?.(name);
            sm.remove = sm.removeLocalFile = name => {
                const file = nameFor(name);
                return enqueue(file, async () => {
                    await request(file, null);
                    if (sm.removeForage) await sm.removeForage(name);
                    update(file, null);
                });
            };
        }
        sm.__emuStorage = mv ? 'MV' : 'MZ';
        log('info', sm.__emuStorage + ' 磁盘存档接口已安装');
    }

    function wrap(object, name, make) {
        const original = object?.[name];
        if (typeof original !== 'function' || original.__emuObserved) return;
        const wrapped = make(original);
        wrapped.__emuObserved = true;
        object[name] = wrapped;
    }
    function install() {
        installStorage();
        // Observe the engine; preserve plugin implementations and readiness checks.
        wrap(window.SceneManager, 'run', original => function (...args) {
            installStorage();
            log('info', '引擎开始启动: ' + (args[0]?.name || 'unknown'));
            return original.apply(this, args);
        });
        wrap(window.SceneManager, 'catchException', original => function (error) {
            log('error', '引擎停止: ' + describe(error));
            return original.call(this, error);
        });
        wrap(window.DataManager, 'loadDatabase', original => function (...args) {
            log('info', '开始加载数据库');
            return original.apply(this, args);
        });
        wrap(window.DataManager, 'loadMapData', original => function (id) {
            log('info', '开始加载地图: ' + id);
            return original.call(this, id);
        });
    }
    // The server calls this immediately after the core managers script executes,
    // before plugins/main.js can perform their first configuration/save read.
    window.__emuInstallRuntime = install;
    document.addEventListener('DOMContentLoaded', install);
    window.addEventListener('load', install, true);
    install();
    const monitor = setInterval(() => {
        install();
        const manager = window.SceneManager;
        const scene = manager?._scene;
        const started = manager && (manager._sceneStarted === true ||
            (typeof scene?.isStarted === 'function' && scene.isStarted() === true));
        const name = scene?.constructor?.name;
        if (!ready && started && name && name !== 'Scene_Boot' && name !== 'Scene_Splash' && !manager._stopped) {
            ready = true;
            log('ready', name);
        }
    }, 100);
    // A diagnostic timeout reports state; it never forces an unready scene ahead.
    const watchdog = setTimeout(() => {
        if (ready) return;
        const dm = window.DataManager;
        const missing = (dm?._databaseFiles || []).filter(file => !window[file.name]).map(file => file.src);
        const imageCache = window.ImageManager?._imageCache?._items || window.ImageManager?._cache || {};
        const images = Object.keys(imageCache).filter(key => {
            const bitmap = imageCache[key]?.bitmap || imageCache[key];
            return bitmap?._loadingState && bitmap._loadingState !== 'loaded' && bitmap._loadingState !== 'none';
        }).slice(0, 12);
        log('warning', '启动尚未完成: ' + JSON.stringify({
            document: document.readyState,
            engine: window.Utils?.RPGMAKER_NAME || 'HTML5/unknown',
            scene: window.SceneManager?._scene?.constructor?.name || '未创建',
            stopped: window.SceneManager?._stopped,
            storage: window.StorageManager?.__emuStorage || '未安装',
            missingDatabase: missing,
            mapLoaded: !!window.$dataMap,
            pendingImages: images,
            fonts: window.FontManager?._states || null,
            errorUrl: dm?._errorUrl || null
        }));
    }, 15000);
    window.addEventListener('pagehide', () => { clearInterval(monitor); clearTimeout(watchdog); });
    // For non-RPG HTML5 pages, report page readiness without claiming engine readiness.
    window.addEventListener('load', () => setTimeout(() => {
        if (!window.SceneManager && !window.Utils?.RPGMAKER_NAME && !failed) {
            ready = true;
            try {
                const scripts = Array.from(document.scripts || []).map(s =>
                    s.src ? s.src.split('/').slice(-2).join('/') : '(inline)');
                log('warning', '页面诊断: ' + JSON.stringify({
                    scripts: scripts.slice(0, 20),
                    scriptCount: scripts.length,
                    sceneManager: !!window.SceneManager,
                    rpgMaker: window.Utils?.RPGMAKER_NAME || null,
                    dataSystem: !!window.$dataSystem,
                    canvasCount: document.querySelectorAll('canvas').length,
                    page: location.pathname.split('/').pop()
                }));
            } catch (_) { /* diagnostic only, never block pageReady */ }
            log('pageReady', 'HTML5 页面已加载');
        }
    }, 1000));
})();

/* Injected at document start, after the native save snapshot. No engine globals
 * are declared/replaced before the game's own scripts have defined them. */
(function () {
    'use strict';
    const bootstrap = window.__emuBootstrap;
    if (!bootstrap) throw new Error('Emu save snapshot is missing');
    // Native startup cache is bounded; larger MV files stay on demand, MZ uses fetch.
    const meta = bootstrap.savesMeta || Object.create(null);
    const cache = Object.create(null);
    const cacheOrder = new Map();
    const revisions = new Map();
    const cacheLimit = 8 * 1024 * 1024; // Conservative UTF-16 string byte estimate.
    let cacheBytes = 0;
    const prefix = 'emu.pending.' + bootstrap.namespace + '.';
    const pending = Object.create(null);
    const queues = new Map();
    const journalAliases = new Map();
    let ready = false;
    let failed = false;

    function describe(value) {
        if (value && value.stack) {
            const summary = [value.name, value.message].filter(Boolean).join(': ');
            const stack = String(value.stack);
            return summary && !stack.includes(summary) ? summary + '\n' + stack : stack;
        }
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
    const asyncSources = new WeakMap();
    window.addEventListener('unhandledrejection', event => log('error', '异步错误: ' + describe(event.reason) +
        '\n来源: ' + (asyncSources.get(event.promise) || '未知') +
        '，场景: ' + (window.SceneManager?._scene?.constructor?.name || '未创建') +
        '，页面: ' + (document.visibilityState || 'unknown')));

    function validName(name) {
        if (typeof name !== 'string' || !/^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/.test(name)) {
            throw new Error('Invalid save name: ' + name);
        }
        return name;
    }
    const has = name => Object.prototype.hasOwnProperty.call(cache, name);
    const hasFile = name => Object.prototype.hasOwnProperty.call(meta, name);
    function forget(name) {
        if (has(name)) cacheBytes -= cache[name].length * 2;
        delete cache[name];
        cacheOrder.delete(name);
    }
    function trimCache() {
        for (const name of cacheOrder.keys()) {
            if (cacheBytes <= cacheLimit) break;
            if (!Object.prototype.hasOwnProperty.call(pending, name)) forget(name);
        }
    }
    function remember(name, text) {
        forget(name);
        cache[name] = text;
        cacheOrder.set(name, true);
        cacheBytes += text.length * 2;
        trimCache();
    }
    function cached(name) {
        cacheOrder.delete(name);
        cacheOrder.set(name, true);
        return cache[name];
    }
    function update(name, value) {
        revisions.set(name, (revisions.get(name) || 0) + 1);
        if (value === null) { forget(name); delete meta[name]; }
        else { meta[name] = {size: String(value).length}; remember(name, value); }
    }
    for (const [name, text] of Object.entries(bootstrap.startupSaves || {})) {
        if (hasFile(name) && typeof text === 'string') remember(name, text);
    }
    delete bootstrap.startupSaves;

    function readFileSync(name) {
        if (has(name)) return cached(name);
        if (!hasFile(name)) return null;
        // MV and its plugins require a synchronous return value. The loopback
        // server runs on a native background queue, independent of this JS thread.
        const xhr = new XMLHttpRequest();
        xhr.open('GET', '/save/' + encodeURIComponent(name), false);
        try { xhr.send(null); }
        catch (error) {
            throw new Error('同步存档读取失败: ' + name + ': ' + describe(error));
        }
        if (xhr.status !== 200) throw new Error('存档读取失败 HTTP ' + xhr.status + ': ' + name);
        const text = xhr.responseText;
        remember(name, text);
        return text;
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
        } catch (error) {
            if (controller.signal.aborted) throw new Error('存档写回超时（10秒）: ' + name);
            throw error;
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
    async function prefetchOne(name) {
        const file = validName(name).toLowerCase();
        if (has(file)) return cached(file);
        if (!hasFile(file)) throw new Error('存档不存在: ' + file);
        const revision = revisions.get(file) || 0;
        const resp = await fetch('/save/' + encodeURIComponent(file));
        if (!resp.ok) throw new Error('存档读取失败 HTTP ' + resp.status + ': ' + file);
        const text = await resp.text();
        if ((revisions.get(file) || 0) !== revision) {
            if (!hasFile(file)) throw new Error('存档不存在: ' + file);
            return prefetchOne(file);
        }
        remember(file, text);
        return text;
    }
    window.__emuSaveCacheStats = () => ({bytes: cacheBytes, limit: cacheLimit, files: cacheOrder.size});
    window.__emuFlushSaves = () => Promise.allSettled([...queues.values()]);
    function flush(name, value) {
        return enqueue(name, async () => {
            await request(name, value);
            // An older completed write must not remove a newer pending write.
            if (pending[name] === value) {
                localStorage.removeItem(prefix + name);
                for (const key of journalAliases.get(name) || []) localStorage.removeItem(key);
                journalAliases.delete(name);
                delete pending[name];
                trimCache();
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
                const name = validName(key.slice(prefix.length)).toLowerCase();
                if (key !== prefix + name) {
                    if (!journalAliases.has(name)) journalAliases.set(name, new Set());
                    journalAliases.get(name).add(key);
                }
                const value = JSON.parse(localStorage.getItem(key));
                if (value !== null && typeof value !== 'string') throw new Error('Invalid pending save: ' + name);
                pending[name] = value;
                update(name, value);
            } catch (error) { log('error', '待写回记录损坏: ' + key + ': ' + describe(error)); }
        }
        for (const name of Object.keys(pending)) flush(name, pending[name]);
    } catch (error) { log('error', '无法恢复待写回存档: ' + describe(error)); }
    log('info', '存档元信息已就绪（游戏脚本执行前），文件数: ' + Object.keys(meta).length + '，正文按需加载');

    function mvName(id) {
        // 原版 MV 从不校验存档 id（'file%1.rpgsave'.format(id) 直接拼字符串），
        // 插件（如 XdRs_GlobalData）会用字符串 key 调 StorageManager.load/save。
        // 这里永不抛错：整数走原版命名，非常规 key 清洗成稳定的文件名。
        const n = typeof id === 'number' ? id : Number(id);
        if (Number.isInteger(n)) {
            return n < 0 ? 'config.rpgsave' : n === 0 ? 'global.rpgsave' : 'file' + n + '.rpgsave';
        }
        const key = String(id).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 64) || 'custom';
        return ('plugin_' + key + '.rpgsave').toLowerCase();
    }
    function readRaw(name) {
        const raw = readFileSync(name);
        const trimmed = String(raw).trim();
        const json = /^[\[{]/.test(trimmed) ? trimmed : window.LZString.decompressFromBase64(raw);
        if (!json) throw new Error('存档解压失败: ' + name);
        // Validate here so corrupt config/global data gets a filename in the log.
        try { JSON.parse(json); } catch (_) { throw new Error('存档 JSON 无效: ' + name); }
        return json;
    }
    function readMV(id) {
        const name = mvName(id);
        if (!hasFile(name)) return null;
        return readRaw(name);
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
            const info = hasFile('global.rpgsave') ? JSON.parse(readMV(0)) : [];
            if (!Array.isArray(info)) throw new Error('global.rpgsave 必须是存档索引数组');
            let imported = false;
            for (let id = 1; id < legacy.length; id++) {
                if (legacy[id]?.title !== bootstrap.gameTitle || legacy[id]?.globalId !== window.DataManager._globalId) continue;
                const name = mvName(id);
                if (!hasFile(name) && pending[name] !== null) {
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
            sm.exists = sm.localFileExists = id => hasFile(mvName(id));
            sm.remove = sm.removeLocalFile = id => writeMV(mvName(id), null);
            sm.backup = id => {
                const name = mvName(id);
                if (hasFile(name)) writeMV(name + '.bak', readFileSync(name));
            };
            sm.backupExists = id => hasFile(mvName(id) + '.bak');
            sm.cleanBackup = id => writeMV(mvName(id) + '.bak', null);
            sm.restoreBackup = id => {
                const name = mvName(id);
                if (hasFile(name + '.bak')) {
                    writeMV(name, readFileSync(name + '.bak'));
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
                if (hasFile(file)) return prefetchOne(file);
                if (sm.loadFromForage) return sm.loadFromForage(name);
                throw new Error('存档不存在: ' + file);
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
            sm.exists = sm.localFileExists = name => hasFile(nameFor(name)) || !!sm.forageExists?.(name);
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

    // 读档诊断：只读、不写盘、不泄露存档正文。标题画面就绪后自动跑一次，
    // 用户也可在控制台手动调用 window.__emuSaveDiag()。
    function saveDiag() {
        const report = {engine: window.Utils?.RPGMAKER_NAME || null, files: [], game: null, slots: []};
        try {
            for (const name of Object.keys(meta).sort()) {
                const entry = {name, size: (meta[name] && meta[name].size) ?? 0, stage: has(name) ? 'ok' : 'not-loaded'};
                try {
                    if (!has(name)) { report.files.push(entry); continue; }
                    const data = JSON.parse(readRaw(name));
                    if (name === 'global.rpgsave') {
                        entry.kind = 'global-index';
                        entry.isArray = Array.isArray(data);
                        if (Array.isArray(data)) {
                            entry.slots = data.map((s, i) => s ? {
                                id: i, title: s.title ?? null, globalId: s.globalId ?? null,
                                hasChars: Array.isArray(s.characters), playtime: s.playtime ?? null
                            } : null).filter(Boolean);
                        }
                    } else if (/^file\d+\.rpgsave$/.test(name)) {
                        entry.kind = 'savefile';
                        entry.topKeys = data && typeof data === 'object' ? Object.keys(data).slice(0, 12) : null;
                    } else {
                        entry.kind = 'other';
                    }
                } catch (error) { entry.stage = 'error'; entry.error = describe(error).slice(0, 200); }
                report.files.push(entry);
            }
            const dm = window.DataManager, sm = window.StorageManager;
            const existsConsistent = !!sm && [0, 1, 5].every(id => {
                try { return !!sm.exists?.(id) === hasFile(mvName(id)); } catch (_) { return false; }
            });
            report.game = {
                title: window.$dataSystem?.gameTitle ?? null,
                globalId: dm?._globalId ?? null,
                storage: sm?.__emuStorage || null,
                // 插件可能在我们之后又替换掉 StorageManager 接口（如走 localStorage 的云存档插件）
                loadFn: !sm ? null : (sm.load === readMV ? 'emu' : String(sm.load?.name || typeof sm.load)),
                existsConsistent,
                saveFn: !sm ? null : String(sm.save?.name || typeof sm.save)
            };
            try {
                const webKeys = [];
                for (const k of ['RPG Global', 'RPG Config', 'RPG File1', 'RPG File2', 'RPG File3', 'RPG File4', 'RPG File5']) {
                    if (localStorage.getItem(k) !== null) webKeys.push(k);
                }
                report.webStorageKeys = webKeys;
            } catch (_) { report.webStorageKeys = 'unreadable'; }
            const max = typeof dm?.maxSavefiles === 'function' ? dm.maxSavefiles() : 20;
            for (let id = 1; id <= max; id++) {
                const slot = {id};
                try { slot.exists = !!sm?.exists?.(id); }
                catch (error) { slot.exists = 'error: ' + describe(error).slice(0, 120); }
                try {
                    const info = dm?.loadSavefileInfo?.(id);
                    slot.info = info ? {title: info.title ?? null, globalId: info.globalId ?? null} : null;
                } catch (error) { slot.info = 'error: ' + describe(error).slice(0, 120); }
                try { slot.thisGame = !!dm?.isThisGameFile?.(id); }
                catch (error) { slot.thisGame = 'error: ' + describe(error).slice(0, 120); }
                report.slots.push(slot);
            }
        } catch (error) { report.fatal = describe(error).slice(0, 200); }
        return report;
    }
    let diagDone = false;
    window.__emuSaveDiag = () => {
        const report = saveDiag();
        log('warning', '存档诊断: ' + JSON.stringify(report));
        return report;
    };

    function wrap(object, name, make) {
        const original = object?.[name];
        if (typeof original !== 'function' || original.__emuObserved) return;
        const wrapped = make(original);
        wrapped.__emuObserved = true;
        object[name] = wrapped;
    }
    let viewportInstalled = false;
    let resizeTimer;
    let viewportSize = '';
    window.__emuRefreshViewport = () => {
        if (hostPaused || document.hidden) return;
        const graphics = window.Graphics;
        if (!graphics || !graphics._canvas || !window.innerWidth || !window.innerHeight) return;
        const size = window.innerWidth + 'x' + window.innerHeight;
        if (size === viewportSize) return;
        // Keep engine resolution and plugin resize hooks; only refresh its display
        // fit after WebKit has the final viewport dimensions.
        if (typeof graphics._onWindowResize === 'function') graphics._onWindowResize();
        viewportSize = size;
    };
    function scheduleViewportRefresh() {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(window.__emuRefreshViewport, 250);
    }
    function installViewport() {
        if (viewportInstalled || !window.Graphics || !document.head || !window.Utils?.RPGMAKER_NAME) return;
        let meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
            meta = document.createElement('meta');
            meta.name = 'viewport';
            document.head.appendChild(meta);
        }
        // A fixed-width layout viewport plus WebKit page zoom competes with the
        // RPG engine's own canvas scaling when the device rotates.
        meta.content = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
        viewportInstalled = true;
        window.addEventListener('resize', scheduleViewportRefresh);
        window.addEventListener('orientationchange', scheduleViewportRefresh);
        window.visualViewport?.addEventListener('resize', scheduleViewportRefresh);
        scheduleViewportRefresh();
    }
    const heldKeys = new Map();
    const titleFrames = new WeakMap();
    const actionFrames = new WeakMap();
    let performanceEnabled = false;
    let previousFrameTime = 0;
    let frameIntervals = [];
    window.__emuStopPerformance = () => {
        performanceEnabled = false;
        previousFrameTime = 0;
        frameIntervals = [];
    };
    window.__emuPerformance = () => {
        performanceEnabled = true;
        const samples = frameIntervals;
        frameIntervals = [];
        const mean = samples.length ? samples.reduce((a, b) => a + b, 0) / samples.length : 0;
        const sorted = samples.slice().sort((a, b) => a - b);
        const bitmaps = new Set();
        for (const item of Object.values(window.ImageManager?._imageCache?._items || {})) {
            if (item?.bitmap) bitmaps.add(item.bitmap);
        }
        let titleFrameCount = 0;
        for (const data of window.SceneManager?._scene?._drill_TTG_dataTank || []) {
            for (const bitmap of titleFrames.get(data)?.values() || []) { bitmaps.add(bitmap); titleFrameCount++; }
        }
        let pixels = 0;
        for (const bitmap of bitmaps) pixels += (bitmap.width || 0) * (bitmap.height || 0) * 4;
        return {
            fps: mean ? Math.round(1000 / mean) : 0,
            frameMs: Math.round(mean * 10) / 10,
            p95Ms: Math.round((sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)] || 0) * 10) / 10,
            slowFrames: samples.filter(ms => ms > 50).length,
            scene: window.SceneManager?._scene?.constructor?.name || '未创建',
            renderer: window.Graphics?.isWebGL?.() ? 'WebGL' : 'Canvas/未知',
            imageCount: bitmaps.size, titleFrameCount,
            pixelMiB: Math.round(pixels / 1048576),
            heapMiB: window.performance?.memory ? Math.round(window.performance.memory.usedJSHeapSize / 1048576) : null,
            pendingWrites: queues.size, paused: hostPaused
        };
    };
    function releasePrivateBitmap(bitmap) {
        if (!bitmap?.__emuPrivate) return;
        try { (bitmap.__baseTexture || bitmap._baseTexture)?.dispose?.(); } catch (_) {}
        try {
            if (bitmap._image && bitmap.isReady?.() && typeof bitmap._clearImgInstance === 'function') {
                bitmap._clearImgInstance();
                if (Array.isArray(window.Bitmap?._reuseImages) && window.Bitmap._reuseImages.length > 16) {
                    window.Bitmap._reuseImages.length = 16;
                }
            }
        } catch (_) {}
    }
    window.__emuTitleFrame = (data, index) => {
        let frames = titleFrames.get(data);
        if (!frames) { frames = new Map(); titleFrames.set(data, frames); }
        const count = data.src_img.length;
        if (!count) throw new Error('标题动画未配置图片');
        const wanted = [index, (index + (data.back_run ? count - 1 : 1)) % count];
        for (const id of wanted) {
            if (!frames.has(id)) {
                const bitmap = window.Bitmap.load(data.src_img_file + data.src_img[id] + '.png');
                bitmap.__emuPrivate = true;
                bitmap.smooth = data.smooth;
                if (data.tint) bitmap.addLoadListener(() => bitmap.rotateHue(data.tint));
                frames.set(id, bitmap);
            }
        }
        // Avoid ImageManager's shared cache: the plugin previously pinned every
        // full-resolution bitmap both in Game_Temp and in its title sprite data.
        for (const [id, bitmap] of frames.entries()) {
            if (!wanted.includes(id)) {
                frames.delete(id);
                releasePrivateBitmap(bitmap);
            }
        }
        const current = frames.get(index);
        if (current.isError?.()) throw new Error('标题动画图片读取失败: ' + data.src_img[index]);
        return current;
    };
    window.__emuActionFrame = controller => {
        if (!controller) return null;
        const path = controller._drill_curBitmapPath || '';
        const name = controller._drill_curBitmapName || '';
        const tint = controller._drill_curBitmapTint || 0;
        const smooth = !!controller._drill_curBitmapSmooth;
        if (!name) {
            return window.ImageManager?.loadEmptyBitmap ? window.ImageManager.loadEmptyBitmap() :
                window.ImageManager?.loadBitmap?.(path, '', tint, smooth) || null;
        }
        let frames = actionFrames.get(controller);
        if (!frames) { frames = new Map(); actionFrames.set(controller, frames); }
        const makeKey = (p, n, t, s) => `${p}${n}:${t}:${s ? 1 : 0}`;
        const load = (p, n, t, s) => {
            if (window.Bitmap?.load) {
                const bitmap = window.Bitmap.load(p + encodeURIComponent(n) + '.png');
                bitmap.__emuPrivate = true;
                bitmap.smooth = s;
                if (t && typeof bitmap.addLoadListener === 'function') {
                    bitmap.addLoadListener(() => bitmap.rotateHue?.(t));
                }
                return bitmap;
            }
            return window.ImageManager?.loadBitmap?.(p, n, t, s) || null;
        };
        const currentKey = makeKey(path, name, tint, smooth);
        const wanted = [currentKey];
        const unit = controller.drill_controllerMain_Act_isPlayingAct?.() ?
            controller._drill_act_curController :
            controller.drill_controllerMain_Node_getCurState_Private?.();
        const unitData = unit?.drill_data?.();
        const list = Array.isArray(unitData?.gif_src) ? unitData.gif_src : null;
        if (list && list.length > 1) {
            const curIdx = (typeof unit._drill_curIndex === 'number' && list[unit._drill_curIndex] === name) ?
                unit._drill_curIndex : list.indexOf(name);
            if (curIdx >= 0) {
                const nextIdx = (curIdx + (unitData.gif_back_run ? list.length - 1 : 1)) % list.length;
                const nextName = list[nextIdx];
                if (nextName) {
                    const nextPath = unitData.gif_src_file || path;
                    const nextTint = unitData.tint ?? tint;
                    const nextSmooth = unitData.smooth !== undefined ? !!unitData.smooth : smooth;
                    const nextKey = makeKey(nextPath, nextName, nextTint, nextSmooth);
                    if (nextKey !== currentKey) wanted.push(nextKey);
                    if (!frames.has(nextKey)) frames.set(nextKey, load(nextPath, nextName, nextTint, nextSmooth));
                }
            }
        }
        if (!frames.has(currentKey)) frames.set(currentKey, load(path, name, tint, smooth));
        for (const [key, bitmap] of frames.entries()) {
            if (!wanted.includes(key)) {
                frames.delete(key);
                releasePrivateBitmap(bitmap);
            }
        }
        const current = frames.get(currentKey);
        if (current?.isError?.()) throw new Error('动作序列图片读取失败: ' + name);
        return current;
    };
    function keyNumber(key, code) {
        if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3);
        if (/^Digit[0-9]$/.test(code)) return code.charCodeAt(5);
        if (/^F([1-9]|1[0-2])$/.test(code)) return 111 + Number(code.slice(1));
        const codes = {Enter: 13, Escape: 27, Space: 32, Tab: 9, Backspace: 8,
            ShiftLeft: 16, ShiftRight: 16, ControlLeft: 17, ControlRight: 17,
            AltLeft: 18, AltRight: 18, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39,
            ArrowDown: 40, PageUp: 33, PageDown: 34, Home: 36, End: 35, Delete: 46,
            Quote: 222, Backslash: 220, Semicolon: 186, Comma: 188, Period: 190,
            Slash: 191, Backquote: 192, BracketLeft: 219, BracketRight: 221, Minus: 189, Equal: 187};
        return codes[code] || codes[key] || ({Shift: 16, Control: 17, Alt: 18, ' ': 32})[key] ||
            (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
    }
    function dispatchKey(entry, down) {
        const modifier = prefix => [...heldKeys.keys()].some(code => code.startsWith(prefix));
        const event = new KeyboardEvent(down ? 'keydown' : 'keyup', {
            key: entry.key, code: entry.code, keyCode: entry.number, which: entry.number,
            bubbles: true, cancelable: true, shiftKey: modifier('Shift'),
            ctrlKey: modifier('Control'), altKey: modifier('Alt'), metaKey: modifier('Meta')
        });
        Object.defineProperty(event, 'keyCode', {get: () => entry.number});
        Object.defineProperty(event, 'which', {get: () => entry.number});
        // One bubbling event reaches element, document and window listeners once.
        (document.activeElement || document).dispatchEvent(event);
    }
    window.__emuKeyEvent = (key, code, down) => {
        let entry = heldKeys.get(code);
        if (down) {
            if (entry) { entry.release = false; return; }
            entry = {key, code, number: keyNumber(key, code), sampled: false, release: false};
            heldKeys.set(code, entry);
            for (const context of new Set([window.WebAudio?._context, window.AudioManager?._context])) {
                if (context?.state === 'suspended') context.resume().catch(error => log('warning', describe(error)));
            }
            dispatchKey(entry, true);
        } else if (entry) {
            // MV/MZ sample held state once per frame. A tap ending before that
            // sample otherwise disappears entirely, especially on slow maps.
            if (window.Input?.update && !entry.sampled) entry.release = true;
            else { heldKeys.delete(code); dispatchKey(entry, false); }
        }
    };
    window.__emuReleaseKeys = () => {
        const entries = [...heldKeys.values()];
        heldKeys.clear();
        for (const entry of entries) dispatchKey(entry, false);
    };
    window.addEventListener('blur', window.__emuReleaseKeys);
    window.addEventListener('pagehide', window.__emuReleaseKeys);
    let hostPaused = false;
    let monitor = null;
    let monitorStopped = false;
    let resumeScene = false;
    let pausedAudio = [];
    let pausedMedia = [];
    let pendingSceneFrame = null;
    let resumeStartedAt = null;
    window.__emuSetPaused = paused => {
        if (hostPaused === paused) return;
        hostPaused = paused;
        const manager = window.SceneManager;
        if (paused) {
            clearTimeout(monitor);
            window.__emuReleaseKeys();
            resumeScene = !!manager && !manager._stopped;
            if (resumeScene) manager.stop?.();
            pausedAudio = [...new Set([window.WebAudio?._context, window.AudioManager?._context])]
                .filter(context => context?.state === 'running');
            for (const context of pausedAudio) context.suspend().catch(error => log('warning', describe(error)));
            pausedMedia = [...(document.querySelectorAll?.('audio, video') || [])].filter(media => !media.paused);
            for (const media of pausedMedia) media.pause();
        } else {
            install();
            scheduleMonitor();
            scheduleViewportRefresh();
            if (resumeScene) {
                resumeStartedAt = Date.now();
                manager?.resume?.();
                // Plugins may replace updateMain without updating resume's clock.
                if (typeof manager?._currentTime === 'number') {
                    const clock = manager._getTimeInMs || manager._getTimeInMsWithoutMobileSafari;
                    if (typeof clock === 'function') manager._currentTime = clock.call(manager);
                }
                if (typeof manager?._accumulator === 'number') manager._accumulator = 0;
                previousFrameTime = 0;
            }
            resumeScene = false;
            for (const context of pausedAudio) context.resume().catch(error => log('warning', describe(error)));
            pausedAudio = [];
            for (const media of pausedMedia) media.play()?.catch(error => log('warning', describe(error)));
            pausedMedia = [];
        }
    };
    // MV's browser index assumes shared localStorage. Our files are already
    // isolated by game directory, like desktop MV. Repair only the in-memory
    // index view; never rewrite imported saves merely by opening the title.
    const inspectedSlots = new Map();
    function repairMVIndex(info, dm) {
        if (window.StorageManager?.__emuStorage !== 'MV' || !window.$dataSystem) return info;
        const result = Array.isArray(info) ? info.slice() : [];
        for (let id = 1; id <= dm.maxSavefiles(); id++) {
            const name = mvName(id);
            if (!hasFile(name)) continue;
            const previous = result[id];
            if (previous?.globalId === dm._globalId && previous?.title === window.$dataSystem.gameTitle) continue;
            let inspected = inspectedSlots.get(name);
            const revision = revisions.get(name) || 0;
            if (!inspected || inspected.revision !== revision) {
                inspected = {revision, valid: false};
                try {
                    const data = JSON.parse(readRaw(name));
                    // Do not enable Continue for arbitrary JSON/config/plugin files.
                    inspected.valid = ['system', 'screen', 'timer', 'switches', 'variables',
                        'selfSwitches', 'actors', 'party', 'map', 'player'].every(key =>
                        data?.[key] && typeof data[key] === 'object' && !Array.isArray(data[key]));
                    if (!inspected.valid) throw new Error('缺少 MV 游戏存档必要字段');
                    log('warning', '已恢复存档索引（仅内存）: ' + name +
                        (previous ? '，按当前游戏目录识别旧标题/标识' : '，原索引缺失'));
                } catch (error) { log('error', '无法恢复存档索引: ' + name + ': ' + describe(error)); }
                inspectedSlots.set(name, inspected);
            }
            if (inspected.valid) result[id] = Object.assign({characters: [], faces: [], playtime: '', timestamp: 0}, previous, {
                globalId: dm._globalId, title: window.$dataSystem.gameTitle
            });
        }
        return result;
    }

    // MARK: - 深度显存与内存优化引擎 (iOS WebKit VRAM & Memory Guard)
    let lastPurgeAt = 0;

    window.__emuMemoryDiag = () => {
        const groups = new Map(), seen = new Set(), reservedBitmaps = new Set();
        let count = 0, pending = 0, reserved = 0, pixels = 0;
        const add = (key, bitmap, reservation) => {
            if (bitmap && reservation && !reservedBitmaps.has(bitmap)) {
                reservedBitmaps.add(bitmap);
                reserved++;
            }
            if (!bitmap || seen.has(bitmap)) return;
            seen.add(bitmap);
            count++;
            if (bitmap.isReady && !bitmap.isReady()) pending++;
            const size = (bitmap.width || 0) * (bitmap.height || 0) * 4;
            pixels += size;
            const folder = String(key).split('/').slice(0, -1).join('/') || '(其他)';
            const group = groups.get(folder) || {folder, count: 0, bytes: 0};
            group.count++; group.bytes += size;
            groups.set(folder, group);
        };
        for (const [key, item] of Object.entries(window.ImageManager?._imageCache?._items || {})) {
            add(key, item?.bitmap, item?.reservationId);
        }
        for (const [key, bitmap] of Object.entries(window.ImageManager?._cache || {})) {
            if (typeof bitmap?.isReady === 'function') add(key, bitmap, false);
        }
        return {scene: window.SceneManager?._scene?.constructor?.name || '未知',
            cachedImages: count, pending, reserved, pixelMiB: Math.round(pixels / 1048576),
            scope: '仅图片缓存；不含插件私有引用、GPU副本和音频，不代表进程总内存',
            topFolders: [...groups.values()].sort((a, b) => b.bytes - a.bytes || b.count - a.count)
                .slice(0, 8).map(g => ({folder: g.folder, count: g.count, pixelMiB: Math.round(g.bytes / 1048576)}))};
    };

    // Cache eviction releases only our references; Bitmap internals may be
    // getter-only and textures can still be shared with live sprites.
    function purgeTransientImages(urgent = false) {
        const now = Date.now();
        if (!urgent && now - lastPurgeAt < 500) return;
        lastPurgeAt = now;

        let purgedCount = 0;
        let freedPixelEst = 0;

        // 识别可以安全换出的临时场景素材 (严格保留核心系统 Window/Icon 等 UI)
        const isTransientKey = (key) => {
            if (!key || typeof key !== 'string') return false;
            if (key.includes('/system/') || key.includes('system/')) return false;
            if (urgent) return true;
            return key.includes('/tilesets/') || key.includes('tilesets/') ||
                   key.includes('/parallaxes/') || key.includes('parallaxes/') ||
                   key.includes('/battlebacks1/') || key.includes('battlebacks1/') ||
                   key.includes('/battlebacks2/') || key.includes('battlebacks2/') ||
                   key.includes('/animations/') || key.includes('animations/') ||
                   key.includes('/titles1/') || key.includes('titles1/') ||
                   key.includes('/titles2/') || key.includes('titles2/') ||
                   key.includes('/pictures/') || key.includes('pictures/') ||
                   key.toLowerCase().includes('special__actionseq');
        };

        // 1. MV 缓存: ImageManager._imageCache._items
        const imageCacheItems = window.ImageManager?._imageCache?._items;
        if (imageCacheItems && typeof imageCacheItems === 'object') {
            for (const key of Object.keys(imageCacheItems)) {
                if (isTransientKey(key)) {
                    const item = imageCacheItems[key];
                    const bitmap = item?.bitmap;
                    if (item?.reservationId || (bitmap?.isReady && !bitmap.isReady())) continue;
                    if (bitmap) {
                        freedPixelEst += (bitmap.width || 0) * (bitmap.height || 0);
                        purgedCount++;
                        try { bitmap.__baseTexture?.dispose?.(); } catch (_) {}
                    }
                    delete imageCacheItems[key];
                }
            }
        }

        // 2. MZ / 简易版 MV 缓存: ImageManager._cache
        const directCache = window.ImageManager?._cache;
        if (directCache && typeof directCache === 'object') {
            for (const key of Object.keys(directCache)) {
                if (isTransientKey(key)) {
                    const bitmap = directCache[key];
                    // Older MV uses a CacheMap here, not a Bitmap dictionary.
                    // Do not remove its bookkeeping fields during urgent purge.
                    if (typeof bitmap?.isReady !== 'function' || !bitmap.isReady()) continue;
                    if (bitmap) {
                        freedPixelEst += (bitmap.width || 0) * (bitmap.height || 0);
                        purgedCount++;
                        try { bitmap.__baseTexture?.dispose?.(); } catch (_) {}
                    }
                    delete directCache[key];
                }
            }
        }

        // 3. 触发 PIXI 纹理垃圾收集 (Texture GC)
        const renderer = window.Graphics?._renderer;
        if (renderer?.textureGC && typeof renderer.textureGC.run === 'function') {
            try { renderer.textureGC.run(); } catch (_) {}
        }

        if (purgedCount > 0) {
            const freedMB = Math.round(freedPixelEst * 4 / 1048576);
            log('info', `[显存管理] 已移除 ${purgedCount} 个缓存引用 (像素估算 ~${freedMB}MB；仍被场景引用的资源保留，实际释放由引擎回收)`);
        }
    }

    window.__emuPurgeMemory = (urgent = false) => {
        log('warning', '[内存诊断] 清理前: ' + JSON.stringify(window.__emuMemoryDiag()));
        purgeTransientImages(urgent);
        log('info', '[内存诊断] 清理后: ' + JSON.stringify(window.__emuMemoryDiag()));
    };

    function installMemoryOptimizer() {
        // Engine classes and plugin replacements arrive at different times.
        // Each wrap is idempotent; retry missing hooks instead of marking the
        // whole optimizer complete as soon as SceneManager exists.
        if (!window.SceneManager) return;

        // 1. 场景结束切换边界 (例如从地图切到战斗、或进出菜单)
        wrap(window.SceneManager, 'onSceneTerminate', original => function (...args) {
            const result = original.apply(this, args);
            purgeTransientImages(false);
            return result;
        });

        // 2. 玩家在同一地图场景下传送进入新地图 (地图间转移)
        wrap(window.Game_Player?.prototype, 'performTransfer', original => function (...args) {
            if (this.isTransferring() && this._newMapId !== window.$gameMap?.mapId()) {
                purgeTransientImages(false);
            }
            return original.apply(this, args);
        });

        // Keep the engine's LRU and reservation rules. Never destroy a bitmap
        // merely because its cache entry was evicted: live sprites may own it.
        if (window.ImageCache && typeof window.ImageCache.limit === 'number') {
            window.ImageCache.limit = Math.min(window.ImageCache.limit, 12 * 1000 * 1000);
        }

        // 3b. 收紧 PIXI 纹理回收周期 (默认 3600 帧=60 秒会在 _managedTextures 中强引用已淘汰的 CPU 源图与 GPU 纹理)
        if (window.PIXI?.settings) {
            if (typeof window.PIXI.settings.GC_MAX_IDLE === 'number') {
                window.PIXI.settings.GC_MAX_IDLE = Math.min(window.PIXI.settings.GC_MAX_IDLE, 600);
            }
            if (typeof window.PIXI.settings.GC_MAX_CHECK_COUNT === 'number') {
                window.PIXI.settings.GC_MAX_CHECK_COUNT = Math.min(window.PIXI.settings.GC_MAX_CHECK_COUNT, 180);
            }
        }
        const textureGC = window.Graphics?._renderer?.textureGC;
        if (textureGC) {
            if (typeof textureGC.maxIdle === 'number') textureGC.maxIdle = Math.min(textureGC.maxIdle, 600);
            if (typeof textureGC.checkCountMax === 'number') textureGC.checkCountMax = Math.min(textureGC.checkCountMax, 180);
        }

        // 3c. 消除 Bitmap.blt 引起的 CPU 2D Canvas + GPU BaseTexture 双倍内存膨胀:
        // MV 原版 blt 无条件读取 source._canvas，迫使未修改的只读图片创建整张 2D <canvas> 并复制像素、重建纹理。
        if (window.Bitmap?.prototype) {
            wrap(window.Bitmap.prototype, 'blt', original => function (source, sx, sy, sw, sh, dx, dy, dw, dh) {
                if (source && !source.__canvas && source._image && typeof this.bltImage === 'function') {
                    return this.bltImage(source, sx, sy, sw, sh, dx, dy, dw, dh);
                }
                return original.call(this, source, sx, sy, sw, sh, dx, dy, dw, dh);
            });
            wrap(window.Bitmap.prototype, '_createCanvas', original => function (...args) {
                const prevTexture = this.__baseTexture;
                const result = original.apply(this, args);
                if (prevTexture && this.__baseTexture && prevTexture !== this.__baseTexture) {
                    try { prevTexture.dispose?.(); } catch (_) {}
                }
                return result;
            });
        }

        // 3d. 窗口重绘或菜单背景截图替换旧 Bitmap 时，立即卸载旧 GPU 纹理并移出 _managedTextures
        wrap(window.Window_Base?.prototype, 'createContents', original => function (...args) {
            const prev = this.contents;
            const result = original.apply(this, args);
            if (prev && prev !== this.contents) {
                try { prev.__baseTexture?.dispose?.(); } catch (_) {}
            }
            return result;
        });
        wrap(window.SceneManager, 'snapForBackground', original => function (...args) {
            const prev = this._backgroundBitmap;
            const result = original.apply(this, args);
            if (prev && prev !== this._backgroundBitmap) {
                try { prev.__baseTexture?.dispose?.(); } catch (_) {}
            }
            return result;
        });

        // 4. 修复 Decrypter 解密后的 ObjectURL 泄露
        if (window.Decrypter && typeof window.Decrypter.decryptImg === 'function') {
            wrap(window.Decrypter, 'decryptImg', original => function (url, bitmap) {
                original.call(this, url, bitmap);
                if (bitmap && bitmap._image) {
                    const img = bitmap._image;
                    const cleanupBlob = () => {
                        if (img.src && img.src.startsWith('blob:')) {
                            try { URL.revokeObjectURL(img.src); } catch (_) {}
                        }
                    };
                    img.addEventListener('load', cleanupBlob, { once: true });
                    img.addEventListener('error', cleanupBlob, { once: true });
                }
            });
        }

        // 5. 监听 WebGL 丢失与恢复，防止渲染器崩溃
        const canvas = window.Graphics?._canvas || (typeof document?.querySelector === 'function' ? document.querySelector('canvas') : null);
        if (canvas && typeof canvas.addEventListener === 'function' && !canvas.__emuContextListenerAdded) {
            canvas.__emuContextListenerAdded = true;
            canvas.addEventListener('webglcontextlost', (e) => {
                e.preventDefault();
                log('warning', '[显存管理] WebGL 上下文发生显存降级保护，正在启动恢复...');
                purgeTransientImages(true);
            }, false);
            canvas.addEventListener('webglcontextrestored', () => {
                log('info', '[显存管理] WebGL 上下文已成功恢复');
            }, false);
        }

        // 6. 释放已停止/切换的 BGM/BGS/ME 解码后 PCM AudioBuffer 引用 (单首可达 60~90MB)
        if (window.AudioManager) {
            for (const [method, prop] of [['stopBgm', '_bgmBuffer'], ['stopBgs', '_bgsBuffer'], ['stopMe', '_meBuffer']]) {
                wrap(window.AudioManager, method, original => function (...args) {
                    const prev = this?.[prop];
                    const result = original.apply(this, args);
                    if (prev && this?.[prop] !== prev) {
                        try {
                            prev._buffer = null;
                            prev._data = null;
                            if (Array.isArray(prev._loadListeners)) prev._loadListeners.length = 0;
                        } catch (_) {}
                    }
                    return result;
                });
            }
        }
    }

    function install() {
        wrap(window.Game_Event?.prototype, 'drill_EMS_setupMutiSwitch', original => function (...args) {
            // Legacy Drill EMS initializes only in the constructor, which JsonEx
            // does not rerun when restoring events from older saves.
            if (this._drill_EMS == null) this._drill_EMS = {};
            if (this._drill_EMS.keys == null) this._drill_EMS.keys = {};
            if (this._drill_EMS.locks == null) {
                this._drill_EMS.locks = {};
                // Locks persist across pages: restore their first-page comments
                // before the plugin reads the currently active page.
                this._drill_EMS_isFirstBirth = true;
                log('warning', '已补齐旧存档计数开关数据，地图: ' + this._mapId + '，事件: ' + this._eventId);
            }
            return original.apply(this, args);
        });
        installStorage();
        installViewport();
        installMemoryOptimizer();
        const manager = window.SceneManager;
        // MV's stock scheduler does not retain its RAF handle. A hidden WKWebView
        // can retain the old callback, then resume() adds a second endless loop.
        // Only replace that known scheduler; custom/plugin schedulers stay intact.
        if (manager && /requestAnimationFrame\(this\.update\.bind\(this\)\)/.test(String(manager.requestUpdate))) {
            wrap(manager, 'requestUpdate', () => function () {
                // Boot can finish after the host hid the page. Preserve the
                // intent to start the loop when the user returns.
                if (hostPaused && !this._stopped) {
                    resumeScene = true;
                    this.stop?.();
                }
                if (hostPaused || this._stopped || pendingSceneFrame !== null) return;
                const frame = window.requestAnimationFrame(() => {
                    if (pendingSceneFrame !== frame) return;
                    pendingSceneFrame = null;
                    if (!hostPaused && !this._stopped) this.update();
                });
                pendingSceneFrame = frame;
            });
        }
        wrap(manager, 'stop', original => function (...args) {
            if (pendingSceneFrame !== null) {
                window.cancelAnimationFrame(pendingSceneFrame);
                pendingSceneFrame = null;
            }
            return original.apply(this, args);
        });
        wrap(window.SceneManager, 'updateMain', original => function (...args) {
            if (hostPaused) return;
            if (resumeStartedAt !== null) {
                log('info', '游戏恢复首帧: ' + (Date.now() - resumeStartedAt) + 'ms，场景: ' + (this._scene?.constructor?.name || '未知'));
                resumeStartedAt = null;
            }
            if (performanceEnabled && !hostPaused) {
                const now = window.performance.now();
                if (previousFrameTime && frameIntervals.length < 240) frameIntervals.push(now - previousFrameTime);
                previousFrameTime = now;
            }
            return original.apply(this, args);
        });
        wrap(window.HTMLMediaElement?.prototype, 'play', original => function (...args) {
            const media = this;
            const source = this.currentSrc || this.src || '';
            const caller = new Error('媒体播放调用位置').stack;
            const result = original.apply(this, args);
            if (result && typeof result.then === 'function') {
                asyncSources.set(result, '媒体播放: ' + (source || '未设置地址'));
                // Observe the original promise without converting rejection into
                // success for callers that explicitly await/catch play().
                result.then(undefined, error => {
                    const cancelled = error?.name === 'AbortError' &&
                        (media.paused || !source || (media.currentSrc || media.src || '') !== source);
                    log(cancelled ? 'warning' : 'error',
                        (cancelled ? '媒体播放已取消（暂停/换源/空地址）: ' : '媒体播放失败: ') +
                        (source || '未设置地址') + '\n' + describe(error) + '\n' + caller);
                });
            }
            return result;
        });
        wrap(window.Game_Interpreter?.prototype, 'command122', original => function (...args) {
            const params = this._params;
            if (params?.[0] !== 80 || params[1] !== 80 || params[2] !== 0 ||
                params[3] !== 4 || params[4] !== '""睡觉""') return original.apply(this, args);
            this._params = params.slice();
            this._params[4] = '"睡觉"';
            try { return original.apply(this, args); }
            finally { this._params = params; }
        });
        // MV + PIXI 4 Canvas keeps a pattern from the previous tiling bitmap.
        // Animated title frames change bitmaps but MV only resets tilingTexture.
        wrap(window.TilingSprite?.prototype, '_onBitmapLoad', original => function (...args) {
            this._canvasPattern = null;
            return original.apply(this, args);
        });
        // Drill global files bypass MV's ordinary load/save methods. Install
        // immediately after its core plugin, before title plugins read visibility.
        const sm = window.StorageManager;
        const drillName = settings => {
            if (settings?.url_type !== '当前游戏根目录' || !/^save\/?$/.test(settings.url_path) ||
                settings.suffix !== 'rpgsave') return null;
            return validName(settings.name + '.rpgsave').toLowerCase();
        };
        wrap(sm, 'drill_COGS_loadFromWebStorage', original => function (settings) {
            const name = drillName(settings);
            if (!name) return original.call(this, settings);
            // Do not read shared browser keys from another game's Drill plugins.
            return hasFile(name) ? readRaw(name) : '';
        });
        wrap(sm, 'drill_COGS_saveToWebStorage', original => function (settings, json) {
            const name = drillName(settings);
            if (!name) return original.call(this, settings, json);
            JSON.parse(json);
            writeMV(name, window.LZString.compressToBase64(json));
        });
        wrap(window.Input, 'update', original => function (...args) {
            const result = original.apply(this, args);
            for (const [code, entry] of heldKeys) {
                entry.sampled = true;
                if (entry.release) { heldKeys.delete(code); dispatchKey(entry, false); }
            }
            return result;
        });
        wrap(window.DataManager, 'loadGlobalInfo', original => function (...args) {
            const info = original.apply(this, args);
            return repairMVIndex(info, this);
        });
        wrap(window.DataManager, 'loadGame', original => function (id, ...args) {
            log('info', '开始读取存档: ' + id);
            const failure = error => log('error', '读取存档失败: ' + id + ': ' +
                (error ? describe(error) : '引擎返回失败，请检查存档索引、插件及上方异常日志'));
            try {
                const result = original.call(this, id, ...args);
                if (result && typeof result.then === 'function') return result.then(value => {
                    if (value === false) failure();
                    return value;
                }, error => { failure(error); throw error; });
                if (result === false) failure();
                return result;
            } catch (error) { failure(error); throw error; }
        });
        wrap(window.Window_TitleCommand?.prototype, 'processOk', original => function (...args) {
            if (this.currentSymbol?.() === 'continue' && this.isCurrentItemEnabled?.() === false) {
                log('error', '继续游戏不可用: ' + JSON.stringify(saveDiag()));
            }
            return original.apply(this, args);
        });
        // Observe the engine; preserve plugin implementations and readiness checks.
        wrap(window.SceneManager, 'run', original => function (...args) {
            installStorage();
            log('info', '引擎开始启动: ' + (args[0]?.name || 'unknown'));
            return original.apply(this, args);
        });
        wrap(window.SceneManager, 'catchException', original => function (error) {
            resumeScene = false;
            log('error', '引擎停止: ' + describe(error));
            return original.call(this, error);
        });
        wrap(window.DataManager, 'loadDatabase', original => function (...args) {
            log('info', '开始加载数据库');
            return original.apply(this, args);
        });
        wrap(window.DataManager, 'loadMapData', original => function (id) {
            purgeTransientImages(false);
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
    function scheduleMonitor() {
        clearTimeout(monitor);
        if (!monitorStopped && !hostPaused && !document.hidden) {
            monitor = setTimeout(runMonitor, ready ? 1000 : 100);
        }
    }
    function runMonitor() {
        if (monitorStopped || hostPaused || document.hidden) return;
        install();
        const manager = window.SceneManager;
        const scene = manager?._scene;
        const started = manager && (manager._sceneStarted === true ||
            (typeof scene?.isStarted === 'function' && scene.isStarted() === true));
        const name = scene?.constructor?.name;
        if (!ready && started && name && name !== 'Scene_Boot' && name !== 'Scene_Splash' && !manager._stopped) {
            ready = true;
            log('ready', name);
            if (!diagDone && window.DataManager && window.StorageManager) {
                diagDone = true;
                try { window.__emuSaveDiag(); } catch (_) { /* diagnostic only, never block the game */ }
            }
        }
        scheduleMonitor();
    }
    scheduleMonitor();
    document.addEventListener('visibilitychange', () => {
        clearTimeout(monitor);
        if (!document.hidden && !hostPaused && !monitorStopped) {
            install();
            scheduleMonitor();
        }
    });
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
    window.addEventListener('pagehide', () => { monitorStopped = true; clearTimeout(monitor); clearTimeout(watchdog); });
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

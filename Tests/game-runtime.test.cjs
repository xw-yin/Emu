const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const runtime = fs.readFileSync(path.join(__dirname, '../Services/GameRuntime.js'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

test('MPP choice cancel fix preserves disabled rows and permits synthetic cancel branches', () => {
    const server = fs.readFileSync(path.join(__dirname, '../Services/LocalGameServer.swift'), 'utf8');
    const condition = server.match(/let fixed = "(this\.isCancelEnabled\(\).*?)"/)[1];
    const check = new Function('index', 'type', 'return ' + condition);
    const window = {maxItems: () => 2, isCancelEnabled: () => true,
        isCommandEnabled(index) { return [{enabled: true}, {enabled: false}][index].enabled; }};
    assert.equal(check.call(window, -1, -2), false);
    assert.equal(check.call(window, 2, 3), false);
    assert.equal(check.call(window, 1, 3), true);
    assert.equal(check.call(window, 0, 3), false);
});

function environment({saves = {}, startupSaves = {}, namespace = 'game-a', gameTitle = '', journal = new Map(), fetch: fetchImpl} = {}) {
    const logs = [], requests = [], timers = new Map(), events = new Map();
    let sequence = 0;
    // Bootstrap 带元信息和有上限的小存档缓存，其他正文经 GET /save/<name> 按需拉取。
    const savesMeta = Object.fromEntries(
        Object.entries(saves).map(([name, text]) => [name, {size: text.length}]));
    const ctx = {
        __emuBootstrap: {savesMeta, startupSaves, namespace, gameTitle, session: 'session-a'},
        console: {log() {}, warn() {}, error() {}},
        webkit: {messageHandlers: {emuLog: {postMessage(message) { logs.push(message); }}}},
        AbortController,
        XMLHttpRequest: class {
            open(method, url, async) { this.url = url; this.method = method; this.async = async; }
            send() {
                assert.equal(this.async, false);
                requests.push({url: this.url, method: this.method, synchronous: true});
                const name = decodeURIComponent(this.url.slice(6));
                this.status = Object.prototype.hasOwnProperty.call(saves, name) ? 200 : 404;
                this.responseText = saves[name] || '';
            }
        },
        localStorage: {
            get length() { return journal.size; },
            key(i) { return [...journal.keys()][i]; },
            getItem(key) { return journal.get(key) ?? null; },
            setItem(key, value) { journal.set(key, value); },
            removeItem(key) { journal.delete(key); }
        },
        setTimeout(fn, delay) { timers.set(++sequence, {fn, delay}); return sequence; },
        clearTimeout(id) { timers.delete(id); },
        setInterval(fn, delay) { timers.set(++sequence, {fn, delay}); return sequence; },
        clearInterval(id) { timers.delete(id); },
        addEventListener(name, fn) { if (!events.has(name)) events.set(name, []); events.get(name).push(fn); },
        document: {readyState: 'complete', addEventListener(name, fn) { if (!events.has(name)) events.set(name, []); events.get(name).push(fn); }},
        fetch(url, options) {
            requests.push({url, ...options});
            if (fetchImpl) return fetchImpl(url, options);
            // 默认桩：GET /save/<name> 从 saves 表提供正文（带 text()），写/删一律成功。
            const path = String(url).split('?')[0];
            if (path.startsWith('/save/')) {
                // 写/删一律成功；只有 GET 读才按初始表返回（缺失则 404）。
                if (!options || !options.method || options.method === 'GET') {
                    const name = decodeURIComponent(path.slice(6));
                    if (Object.prototype.hasOwnProperty.call(saves, name)) {
                        return Promise.resolve({ok: true, status: 200, text: async () => saves[name]});
                    }
                    return Promise.resolve({ok: false, status: 404});
                }
                return Promise.resolve({ok: true, status: 200});
            }
            return Promise.resolve({ok: true, status: 200});
        },
        // Codec is intentionally stubbed: tests exercise storage contracts/ordering,
        // not LZString/pako's compression implementation.
        LZString: {compressToBase64: value => 'zip:' + value, decompressFromBase64: value => value.startsWith('zip:') ? value.slice(4) : null}
    };
    ctx.window = ctx;
    vm.createContext(ctx);
    vm.runInContext(runtime, ctx);
    return {ctx, logs, requests, journal, events, timers,
        // No background preload; storage reads must work immediately.
        ready: Promise.resolve(),
        poll() { for (const [id, timer] of [...timers]) if (timer.delay === 100) { timers.delete(id); timer.fn(); } }, timeout() { for (const timer of [...timers.values()]) if (timer.delay === 15000) timer.fn(); }};
}
function mv(env) {
    env.ctx.StorageManager = {load() {}, save() {}, localFilePath() {}};
    env.ctx.__emuInstallRuntime();
    return env.ctx.StorageManager;
}

test('memory hooks attach to late engine classes and report bounded cache diagnostics', () => {
    const env = environment();
    env.ctx.SceneManager = {};
    env.ctx.__emuInstallRuntime();
    let transfers = 0;
    env.ctx.Game_Player = function () {};
    env.ctx.Game_Player.prototype = {isTransferring: () => true, _newMapId: 2,
        performTransfer() { transfers++; return 'transferred'; }};
    env.ctx.$gameMap = {mapId: () => 1};
    env.ctx.ImageCache = {limit: 100000000};
    const bitmap = {width: 1024, height: 1024, isReady: () => true};
    const items = {'img/tilesets/map.png': {bitmap}, 'img/pictures/kept.png': {bitmap, reservationId: 'scene'}};
    env.ctx.ImageManager = {_imageCache: {_items: items}};
    env.ctx.__emuInstallRuntime();
    const method = env.ctx.Game_Player.prototype.performTransfer;
    env.ctx.__emuInstallRuntime();
    assert.equal(env.ctx.Game_Player.prototype.performTransfer, method);
    assert.equal(env.ctx.ImageCache.limit, 12000000);
    const player = new env.ctx.Game_Player();
    assert.equal(player.performTransfer(), 'transferred');
    assert.equal(transfers, 1);
    assert.equal(items['img/tilesets/map.png'], undefined);
    assert.equal(items['img/pictures/kept.png'].bitmap, bitmap);
    const report = env.ctx.__emuMemoryDiag();
    assert.equal(report.cachedImages, 1);
    assert.equal(report.reserved, 1);
    assert.equal(report.pixelMiB, 4);
    assert.equal(report.topFolders[0].folder, 'img/pictures');
    assert.match(report.scope, /不代表进程总内存/);
});

test('memory purge evicts references without mutating readonly or shared Bitmap resources', () => {
    const env = environment();
    let destroyed = 0;
    const texture = {destroy() { destroyed++; }};
    const canvas = {width: 1024, height: 1024};
    const bitmap = Object.freeze({width: 1024, height: 1024,
        get _baseTexture() { return texture; }, get _canvas() { return canvas; },
        isReady: () => true, destroy() { destroyed++; }});
    const loading = {isReady: () => false};
    const items = {
        'img/pictures/active.png': {bitmap},
        'img/pictures/reserved.png': {bitmap, reservationId: 'scene'},
        'img/pictures/loading.png': {bitmap: loading},
        'img/system/Window.png': {bitmap}
    };
    const metadata = {};
    env.ctx.ImageManager = {_imageCache: {_items: items}, _cache: {'img/pictures/shared.png': bitmap, _inner: metadata}};
    env.ctx.__emuPurgeMemory(true);
    assert.equal(items['img/pictures/active.png'], undefined);
    assert.equal(env.ctx.ImageManager._cache['img/pictures/shared.png'], undefined);
    assert.equal(env.ctx.ImageManager._cache._inner, metadata);
    assert.equal(items['img/pictures/reserved.png'].bitmap, bitmap);
    assert.equal(items['img/pictures/loading.png'].bitmap, loading);
    assert.equal(items['img/system/Window.png'].bitmap, bitmap);
    assert.equal(destroyed, 0);
    assert.equal(bitmap._baseTexture, texture);
    assert.equal(canvas.width, 1024);
    assert.equal(canvas.height, 1024);
    assert.ok(env.logs.some(log => log.message.includes('实际释放由引擎回收')));
});

test('legacy Drill EMS restores missing save fields and first-page locks without resetting existing state', () => {
    const env = environment();
    env.ctx.Game_Event = function () {};
    env.ctx.Game_Event.prototype.drill_EMS_setupMutiSwitch = function () {
        if (!this._erased && this._drill_EMS_isFirstBirth) {
            this._drill_EMS_isFirstBirth = false;
            this._drill_EMS.locks.firstPage = {num: 4};
        }
        this._drill_EMS.keys = {};
        if (!this._erased) this._drill_EMS.keys.currentPage = true;
        return 'original result';
    };
    const event = Object.create(env.ctx.Game_Event.prototype);
    event._eventId = 3;
    event._mapId = 7;
    assert.throws(() => event.drill_EMS_setupMutiSwitch(), TypeError);
    env.ctx.__emuInstallRuntime();
    assert.equal(event.drill_EMS_setupMutiSwitch(), 'original result');
    assert.equal(event._drill_EMS.locks.firstPage.num, 4);
    assert.equal(event._drill_EMS.keys.currentPage, true);
    event._drill_EMS.locks.firstPage.num = 9;
    const state = event._drill_EMS;
    event.drill_EMS_setupMutiSwitch();
    assert.equal(event._drill_EMS, state);
    assert.equal(state.locks.firstPage.num, 9);
    assert.equal(env.logs.filter(log => log.message.includes('计数开关')).length, 1);
    const erased = Object.create(env.ctx.Game_Event.prototype);
    erased._erased = true;
    erased.drill_EMS_setupMutiSwitch();
    assert.equal(Object.keys(erased._drill_EMS.keys).length, 0);
    assert.equal(Object.keys(erased._drill_EMS.locks).length, 0);
    assert.equal(env.requests.length, 0);
    env.ctx.Game_Event.prototype.drill_EMS_setupMutiSwitch = () => { throw new Error('unrelated plugin failure'); };
    env.ctx.__emuInstallRuntime();
    assert.throws(() => event.drill_EMS_setupMutiSwitch(), /unrelated plugin failure/);
});
function mz(env) {
    env.ctx.StorageManager = {loadZip() {}, saveZip() {}, loadObject(name) { return this.loadZip(name).then(JSON.parse); }, saveObject(name, object) { return this.saveZip(name, JSON.stringify(object)); }};
    env.ctx.__emuInstallRuntime();
    return env.ctx.StorageManager;
}

test('known malformed sleep expression is repaired without mutating event data or masking other errors', () => {
    const env = environment();
    env.ctx.Game_Interpreter = function () {};
    env.ctx.Game_Interpreter.prototype.command122 = function () { return eval(this._params[4]); };
    env.ctx.__emuInstallRuntime();
    const interpreter = new env.ctx.Game_Interpreter();
    const params = [80, 80, 0, 4, '""睡觉""'];
    interpreter._params = params;
    assert.equal(interpreter.command122(), '睡觉');
    assert.equal(interpreter._params, params);
    assert.equal(params[4], '""睡觉""');
    interpreter._params = [81, 81, 0, 4, '""睡觉""'];
    assert.throws(() => interpreter.command122(), SyntaxError);
    interpreter._params = [80, 80, 0, 4, '40 + 2'];
    assert.equal(interpreter.command122(), 42);
    env.ctx.Game_Interpreter.prototype.command122 = function () { throw new Error('real failure'); };
    env.ctx.__emuInstallRuntime();
    interpreter._params = params;
    assert.throws(() => interpreter.command122(), /real failure/);
    assert.equal(interpreter._params, params);
});

test('media observer classifies cancellations and preserves rejected play promises for callers', async () => {
    const env = environment();
    env.ctx.HTMLMediaElement = function () {};
    let result;
    env.ctx.HTMLMediaElement.prototype.play = () => result;
    env.ctx.__emuInstallRuntime();
    const media = new env.ctx.HTMLMediaElement();
    for (const scenario of [
        {name: 'AbortError', src: '', paused: false, level: 'warning'},
        {name: 'AbortError', src: 'title.webm', paused: true, level: 'warning'},
        {name: 'AbortError', src: 'title.webm', paused: false, level: 'error'},
        {name: 'NotSupportedError', src: 'title.webm', paused: false, level: 'error'}
    ]) {
        Object.assign(media, scenario);
        const error = Object.assign(new Error('play failed'), {name: scenario.name});
        result = Promise.reject(error);
        assert.equal(media.play(), result);
        await assert.rejects(result, value => value === error);
        await tick();
        assert.equal(env.logs.at(-1).level, scenario.level);
        assert.match(env.logs.at(-1).message, /媒体播放调用位置/);
    }
});
test('performance sampling is opt-in, bounded, and labels pixel estimates separately from heap', () => {
    const env = environment();
    let now = 100;
    env.ctx.performance = {now: () => now};
    env.ctx.SceneManager = {updateMain() {}};
    env.ctx.ImageManager = {_imageCache: {_items: {a: {bitmap: {width: 1024, height: 1024}}}}};
    env.ctx.__emuInstallRuntime();
    env.ctx.SceneManager.updateMain();
    assert.equal(env.ctx.__emuPerformance().fps, 0);
    for (let i = 0; i < 61; i++) { now += 1000 / 60; env.ctx.SceneManager.updateMain(); }
    const result = env.ctx.__emuPerformance();
    assert.equal(result.fps, 60);
    assert.equal(result.pixelMiB, 4);
    assert.equal(result.heapMiB, null);
    assert.equal(result.pendingWrites, 0);
    env.ctx.__emuStopPerformance();
    now += 1000;
    env.ctx.SceneManager.updateMain();
    assert.equal(env.ctx.__emuPerformance().fps, 0);
});
test('title frame loader prefetches only a neighbour and does not preload the full animation', () => {
    const env = environment();
    const urls = [];
    env.ctx.Bitmap = {load(url) { urls.push(url); return {isReady: () => true}; }};
    const data = {src_img: Array.from({length: 102}, (_, i) => 'frame' + i), src_img_file: 'img/titles1/', smooth: false};
    const first = env.ctx.__emuTitleFrame(data, 0);
    assert.equal(urls.length, 2);
    assert.equal(env.ctx.__emuTitleFrame(data, 0), first);
    env.ctx.__emuTitleFrame(data, 1);
    assert.equal(urls.length, 3);
    for (let i = 2; i < 102; i++) env.ctx.__emuTitleFrame(data, i);
    assert.equal(urls.length, 103, 'only current and next frames loaded during traversal');
    assert.notEqual(env.ctx.__emuTitleFrame(data, 0), first, 'old frame was evicted rather than pinned');
});
test('MV repeated library round trips cancel hidden frames and keep exactly one update loop', () => {
    const env = environment();
    const frames = new Map();
    let next = 0, updates = 0, now = 1000;
    env.ctx.requestAnimationFrame = fn => { frames.set(++next, fn); return next; };
    env.ctx.cancelAnimationFrame = id => frames.delete(id);
    env.ctx.SceneManager = {
        _stopped: false, _currentTime: 0, _accumulator: 1,
        _getTimeInMs: () => now,
        stop() { this._stopped = true; },
        resume() { this._stopped = false; this.requestUpdate(); },
        update() { this.updateMain(); },
        updateMain() { updates++; this.requestUpdate(); }
    };
    vm.runInContext('SceneManager.requestUpdate = function() { if (!this._stopped) requestAnimationFrame(this.update.bind(this)); };', env.ctx);
    env.ctx.__emuInstallRuntime();
    const manager = env.ctx.SceneManager;
    manager.requestUpdate();
    for (let i = 0; i < 10; i++) {
        assert.equal(frames.size, 1);
        const stale = [...frames.values()][0];
        env.ctx.__emuSetPaused(true);
        assert.equal(frames.size, 0);
        // A callback already dispatched by WebKit must not advance a hidden game.
        stale();
        assert.equal(updates, i);
        now += 60000;
        env.ctx.__emuSetPaused(false);
        stale();
        assert.equal(updates, i);
        assert.equal(manager._currentTime, now);
        assert.equal(manager._accumulator, 0);
        manager.requestUpdate();
        env.ctx.__emuInstallRuntime();
        assert.equal(frames.size, 1);
        const [id, callback] = [...frames.entries()][0];
        frames.delete(id);
        callback();
        assert.equal(updates, i + 1);
        assert.equal(frames.size, 1);
    }
    manager.stop();
    assert.equal(frames.size, 0);
    assert.equal(env.logs.filter(item => item.message.includes('游戏恢复首帧')).length, 10);
});

test('returning to library pauses and resumes the same scene without reviving a stopped engine', () => {
    const env = environment();
    const scene = {progress: 42};
    let stops = 0, resumes = 0;
    env.ctx.SceneManager = {_scene: scene, _stopped: false,
        stop() { this._stopped = true; stops++; },
        resume() { this._stopped = false; resumes++; }};
    env.ctx.__emuSetPaused(true);
    env.ctx.__emuSetPaused(true);
    assert.equal(stops, 1);
    env.ctx.__emuSetPaused(false);
    assert.equal(resumes, 1);
    assert.equal(env.ctx.SceneManager._scene, scene);
    env.ctx.SceneManager._stopped = true;
    env.ctx.__emuSetPaused(true);
    env.ctx.__emuSetPaused(false);
    assert.equal(resumes, 1);
});

test('Drill title globals read directory snapshot and persist through MV journal', async () => {
    const env = environment({saves: {'drill_global.rpgsave': '{"TTG":{"global_visibleTank":[false,true]}}'}});
    const sm = mv(env);
    await env.ready;
    sm.drill_COGS_loadFromWebStorage = () => 'shared browser data';
    sm.drill_COGS_saveToWebStorage = () => { throw new Error('must not use shared keys'); };
    env.ctx.__emuInstallRuntime();
    const settings = {url_type: '当前游戏根目录', url_path: 'save/', name: 'drill_global', suffix: 'rpgsave'};
    assert.deepEqual(JSON.parse(sm.drill_COGS_loadFromWebStorage(settings)).TTG.global_visibleTank, [false, true]);
    sm.drill_COGS_saveToWebStorage(settings, '{"TTG":{"global_visibleTank":[true,false]}}');
    await tick();
    assert.equal(env.requests[0].url, '/save/drill_global.rpgsave');
    assert.deepEqual(JSON.parse(sm.drill_COGS_loadFromWebStorage(settings)).TTG.global_visibleTank, [true, false]);
});
test('MV animated tiling bitmap invalidates PIXI canvas pattern and retains original refresh', () => {
    const env = environment();
    env.ctx.TilingSprite = function () { this._canvasPattern = 'frame 1'; };
    env.ctx.TilingSprite.prototype._onBitmapLoad = function () { this.refreshed = true; };
    env.ctx.__emuInstallRuntime();
    const sprite = new env.ctx.TilingSprite();
    sprite._onBitmapLoad();
    assert.equal(sprite._canvasPattern, null);
    assert.equal(sprite.refreshed, true);
});

test('RPG viewport replaces fixed page width and refreshes engine after settled rotation', () => {
    const env = environment();
    const meta = {content: 'width=816'};
    let resized = 0;
    env.ctx.document.head = {};
    env.ctx.document.querySelector = () => meta;
    env.ctx.Utils = {RPGMAKER_NAME: 'MV'};
    env.ctx.innerWidth = 390; env.ctx.innerHeight = 844;
    env.ctx.Graphics = {_canvas: {}, width: 816, height: 624, _onWindowResize() { resized++; }};
    env.ctx.__emuInstallRuntime();
    assert.match(meta.content, /width=device-width/);
    assert.match(meta.content, /initial-scale=1/);
    env.ctx.innerWidth = 844; env.ctx.innerHeight = 390;
    env.ctx.__emuRefreshViewport();
    assert.equal(resized, 1);
    assert.equal(env.ctx.Graphics.width, 816);
    assert.equal(env.ctx.Graphics.height, 624);
    env.ctx.__emuInstallRuntime();
    assert.equal(env.events.get('orientationchange').length, 1);
    env.ctx.innerWidth = 0;
    env.ctx.__emuRefreshViewport();
    assert.equal(resized, 1, 'ignore transient zero bounds');
});

function keyboardEnvironment() {
    const env = environment();
    const events = [];
    env.ctx.KeyboardEvent = class { constructor(type, values) { this.type = type; Object.assign(this, values); } };
    const input = {keyMapper: {13: 'ok', 37: 'left', 16: 'shift'}, _currentState: {},
        update() { this.sample = {...this._currentState}; }};
    env.ctx.Input = input;
    env.ctx.document.dispatchEvent = event => {
        events.push(event);
        input._currentState[input.keyMapper[event.keyCode]] = event.type === 'keydown';
    };
    env.ctx.__emuInstallRuntime();
    return {env, input, events, send: env.ctx.__emuKeyEvent};
}
test('virtual quick tap survives until engine samples it, then releases exactly once', () => {
    const {env, input, events, send} = keyboardEnvironment();
    send('Enter', 'Enter', true);
    send('Enter', 'Enter', false);
    assert.equal(events.length, 1);
    input.update();
    assert.equal(input.sample.ok, true);
    assert.equal(input._currentState.ok, false);
    assert.deepEqual(events.map(e => e.type), ['keydown', 'keyup']);
    input.update();
    assert.equal(input.sample.ok, false);
    env.ctx.__emuReleaseKeys();
    assert.equal(events.length, 2);
});
test('virtual hold, modifiers, custom quotes and forced cancellation preserve key identity', () => {
    const {env, input, events, send} = keyboardEnvironment();
    send('Shift', 'ShiftLeft', true);
    send('ArrowLeft', 'ArrowLeft', true);
    send('ArrowLeft', 'ArrowLeft', true);
    input.update(); input.update();
    assert.equal(input.sample.left, true);
    assert.equal(events.length, 2);
    assert.equal(events[1].shiftKey, true);
    send("'", 'Quote', true);
    assert.equal(events.at(-1).keyCode, 222);
    assert.equal(events.at(-1).key, "'");
    env.ctx.__emuReleaseKeys();
    assert.equal(input._currentState.left, false);
    assert.equal(input._currentState.shift, false);
    assert.equal(events.filter(e => e.type === 'keyup').length, 3);
});
test('virtual keyboard maps all letter, digit, function and default controller keys', () => {
    const {env, events, send} = keyboardEnvironment();
    const cases = [
        ...Array.from({length: 26}, (_, i) => [String.fromCharCode(97 + i), 'Key' + String.fromCharCode(65 + i), 65 + i]),
        ...Array.from({length: 10}, (_, i) => [String(i), 'Digit' + i, 48 + i]),
        ...Array.from({length: 12}, (_, i) => ['F' + (i + 1), 'F' + (i + 1), 112 + i]),
        ['Enter', 'Enter', 13], ['Escape', 'Escape', 27], [' ', 'Space', 32],
        ['Tab', 'Tab', 9], ['ArrowUp', 'ArrowUp', 38], ['ArrowDown', 'ArrowDown', 40]
    ];
    for (const [key, code, number] of cases) {
        send(key, code, true);
        assert.equal(events.at(-1).keyCode, number, code);
        env.ctx.__emuReleaseKeys();
    }
});

test('MV config/global/file are readable immediately, and cached reads never refetch', async () => {
    const env = environment({saves: {'config.rpgsave': '{"alwaysDash":true}', 'global.rpgsave': '[null,{"title":"test"}]', 'file1.rpgsave': 'zip:{"system":{}}'}});
    const sm = mv(env);
    await env.ready;
    const warmed = env.requests.length;
    assert.equal(warmed, 0, 'startup must not preload saves');
    assert.equal(JSON.parse(sm.load(-1)).alwaysDash, true);
    assert.equal(JSON.parse(sm.load(0))[1].title, 'test');
    assert.equal(sm.exists(1), true);
    assert.equal(sm.load(2), null);
    assert.equal(sm.load(1), '{"system":{}}');
    const readCount = env.requests.length;
    sm.load(-1); sm.load(0); sm.load(1);
    assert.equal(env.requests.length, readCount, 'repeated reads must be served from cache');
});
test('MV writes synchronously journal data, and serializes writes to the same file', async () => {
    const complete = [];
    const env = environment({fetch: () => new Promise(resolve => complete.push(resolve))});
    const sm = mv(env);
    sm.save(1, '{"version":1}');
    sm.save(1, '{"version":2}');
    assert.equal(sm.load(1), '{"version":2}');
    assert.equal(env.journal.size, 1);
    await tick();
    assert.equal(env.requests.length, 1);
    assert.equal(env.requests[0].headers['X-Emu-Session'], 'session-a');
    complete[0]({ok: true});
    await tick();
    assert.equal(env.requests.length, 2);
    assert.equal(env.journal.size, 1, 'older write must not clear newer journal');
    complete[1]({ok: true});
    await tick();
    assert.equal(env.journal.size, 0);
});
test('MV failed writes survive restart and never cross game namespaces', async () => {
    const journal = new Map();
    const env = environment({journal, fetch: async () => ({ok: false, status: 500})});
    mv(env).save(1, '{"newer":true}');
    await tick();
    assert.equal(journal.size, 1);
    assert.match(env.logs.find(item => item.level === 'error').message, /HTTP 500/);
    const other = environment({journal, namespace: 'game-b'});
    assert.equal(mv(other).exists(1), false);
    const reopened = environment({journal, saves: {'file1.rpgsave': '{"old":true}'}});
    assert.equal(mv(reopened).load(1), '{"newer":true}');
    await tick();
    assert.equal(journal.size, 0);
});
test('MV deletion tombstone wins over stale disk snapshot', async () => {
    const journal = new Map();
    const env = environment({journal, saves: {'file1.rpgsave': '{}'}, fetch: async () => ({ok: false, status: 403})});
    const sm = mv(env);
    sm.remove(1);
    assert.equal(sm.exists(1), false);
    await tick();
    const reopened = environment({journal, saves: {'file1.rpgsave': '{}'}});
    assert.equal(mv(reopened).exists(1), false);
    await tick();
});
test('MV quota errors cannot report a successful save or alter the cached file', async () => {
    const env = environment({saves: {'file1.rpgsave': '{"old":true}'}});
    const sm = mv(env);
    await env.ready;
    env.ctx.localStorage.setItem = () => { throw new Error('QuotaExceededError'); };
    assert.throws(() => sm.save(1, '{"new":true}'), /QuotaExceededError/);
    assert.equal(sm.load(1), '{"old":true}');
});
test('MV backup/restore preserves compressed bytes and removes backup', async () => {
    const env = environment({saves: {'file1.rpgsave': 'zip:{"old":true}'}});
    const sm = mv(env);
    await env.ready;
    sm.backup(1);
    sm.save(1, '{"new":true}');
    assert.equal(sm.backupExists(1), true);
    sm.restoreBackup(1);
    assert.equal(sm.load(1), '{"old":true}');
    assert.equal(sm.backupExists(1), false);
    await tick();
});
test('corrupt MV saves fail with the filename rather than returning compressed garbage', async () => {
    const env = environment({saves: {'config.rpgsave': 'broken', 'file1.rpgsave': '{bad json'}});
    await env.ready;
    const sm = mv(env);
    assert.throws(() => sm.load(-1), /config.rpgsave/);
    assert.throws(() => sm.load(1), /file1.rpgsave/);
});
test('MZ keeps boolean exists, Promise load/save, and original object codecs', async () => {
    const env = environment({saves: {'config.rmmzsave': '{"volume":50}'}});
    const sm = mz(env);
    assert.equal(sm.exists('config'), true);
    assert.equal(sm.exists('missing'), false);
    assert.equal((await sm.loadObject('config')).volume, 50);
    await sm.saveObject('file1', {value: 7});
    assert.equal(sm.exists('file1'), true);
    assert.equal((await sm.loadObject('file1')).value, 7);
    await sm.remove('file1');
    assert.equal(sm.exists('file1'), false);
});
test('MZ disk failure rejects save and leaves previous data intact', async () => {
    const env = environment({saves: {'file1.rmmzsave': '{"old":true}'},
        fetch: async (url, options) => options?.method === 'PUT'
            ? {ok: false, status: 500}
            : {ok: true, status: 200, text: async () => '{"old":true}'}});
    const sm = mz(env);
    await env.ready;
    await assert.rejects(sm.saveZip('file1', 'new'), /HTTP 500/);
    assert.equal(await sm.loadZip('file1'), '{"old":true}');
});
test('MZ keeps existing IndexedDB-only saves readable and deletes both copies', async () => {
    const env = environment();
    const legacy = new Map([['file1', 'old']]);
    const sm = mz(env);
    sm.forageExists = name => legacy.has(name);
    sm.loadFromForage = async name => legacy.get(name);
    sm.removeForage = async name => legacy.delete(name);
    assert.equal(sm.exists('file1'), true);
    assert.equal(await sm.loadZip('file1'), 'old');
    await sm.saveZip('file1', 'new');
    assert.equal(await sm.loadZip('file1'), 'new');
    await sm.remove('file1');
    assert.equal(sm.exists('file1'), false);
});
test('MV migrates only matching legacy saves without replacing disk data or resurrecting deletes', async () => {
    const journal = new Map([
        ['RPG Global', 'zip:[null,{"title":"this game","globalId":"RPGMV"},{"title":"other game","globalId":"RPGMV"}]'],
        ['RPG File1', 'zip:{"legacy":true}'], ['RPG File2', 'zip:{"other":true}']
    ]);
    const env = environment({journal, gameTitle: 'this game'});
    env.ctx.DataManager = {_globalId: 'RPGMV'};
    env.ctx.StorageManager = {load() {}, save() {}, localFilePath() {}, webStorageKey: id => id === 0 ? 'RPG Global' : 'RPG File' + id};
    env.ctx.__emuInstallRuntime();
    await env.ready;
    assert.equal(env.ctx.StorageManager.load(1), '{"legacy":true}');
    assert.equal(env.ctx.StorageManager.exists(2), false);
    await tick();
    env.ctx.StorageManager.remove(1);
    await tick();
    const reopened = environment({journal, gameTitle: 'this game'});
    reopened.ctx.DataManager = {_globalId: 'RPGMV'};
    reopened.ctx.StorageManager = {load() {}, save() {}, localFilePath() {}, webStorageKey: env.ctx.StorageManager.webStorageKey};
    reopened.ctx.__emuInstallRuntime();
    assert.equal(reopened.ctx.StorageManager.exists(1), false);
});
test('MV migration preserves an existing disk file while recovering its missing index', async () => {
    const journal = new Map([
        ['RPG Global', 'zip:[null,{"title":"this game","globalId":"RPGMV"}]'],
        ['RPG File1', 'zip:{"legacy":true}']
    ]);
    const env = environment({journal, gameTitle: 'this game', saves: {'file1.rpgsave': '{"disk":true}'}});
    env.ctx.DataManager = {_globalId: 'RPGMV'};
    env.ctx.StorageManager = {load() {}, save() {}, localFilePath() {}, webStorageKey: id => id === 0 ? 'RPG Global' : 'RPG File' + id};
    env.ctx.__emuInstallRuntime();
    await env.ready;
    assert.equal(env.ctx.StorageManager.load(1), '{"disk":true}');
    assert.equal(JSON.parse(env.ctx.StorageManager.load(0))[1].title, 'this game');
    await tick();
});
test('installation is idempotent and preserves engine/plugin map implementations', () => {
    const env = environment();
    env.ctx.Game_Map = function () {};
    env.ctx.Game_Map.prototype.width = () => 123;
    const width = env.ctx.Game_Map.prototype.width;
    const sm = mv(env), load = sm.load;
    for (let i = 0; i < 5; i++) env.poll();
    assert.equal(sm.load, load);
    assert.equal(env.ctx.Game_Map.prototype.width, width);
    assert.equal(env.ctx.DataManager, undefined);
});
test('late/replaced scene start cannot lose ready signal; boot is not game ready', () => {
    const env = environment();
    env.ctx.SceneManager = {_scene: {constructor: {name: 'Scene_Boot'}}, _sceneStarted: true};
    env.poll();
    assert.equal(env.logs.some(item => item.level === 'ready'), false);
    env.ctx.SceneManager._scene = {constructor: {name: 'CustomTitleScene'}};
    env.poll(); env.poll();
    assert.equal(env.logs.filter(item => item.level === 'ready').length, 1);
});
test('captured engine exceptions retain stack and call the original exception handler', () => {
    const env = environment(); let caught;
    env.ctx.SceneManager = {catchException(error) { caught = error; }};
    env.ctx.__emuInstallRuntime();
    const error = new Error('plugin failed');
    env.ctx.SceneManager.catchException(error);
    assert.equal(caught, error);
    assert.match(env.logs.at(-1).message, /Error: plugin failed/);
    env.events.get('unhandledrejection')[0]({reason: error});
    assert.match(env.logs.at(-1).message, /plugin failed/);
    const safariError = {name: 'TypeError', message: 'undefined is not an object', stack: '@http://localhost/rpg_windows.js:1352:29'};
    env.ctx.SceneManager.catchException(safariError);
    assert.match(env.logs.at(-1).message, /TypeError: undefined is not an object/);
    assert.match(env.logs.at(-1).message, /rpg_windows.js:1352:29/);
});
test('watchdog reports missing database/scene without forcing startup', () => {
    const env = environment();
    env.ctx.DataManager = {_databaseFiles: [{name: '$dataSystem', src: 'System.json'}]};
    env.timeout();
    assert.match(env.logs.at(-1).message, /System.json/);
    assert.equal(env.logs.some(item => item.level === 'ready'), false);
});

const completeMVSave = () => JSON.stringify(Object.fromEntries(
    ['system', 'screen', 'timer', 'switches', 'variables', 'selfSwitches', 'actors', 'party', 'map', 'player']
        .map(key => [key, {'@': 'Game_' + key, marker: 'original progress'}])));

function titleEnvironment(saves) {
    const env = environment({saves});
    env.ctx.$dataSystem = {gameTitle: 'Current title'};
    env.ctx.DataManager = {
        _globalId: 'RPGMV', maxSavefiles: () => 20,
        loadGlobalInfo() { return this._globalInfo ||= JSON.parse(env.ctx.StorageManager.load(0) || '[]'); },
        isThisGameFile(id) {
            const info = this.loadGlobalInfo()[id];
            return !!info && info.globalId === this._globalId && info.title === env.ctx.$dataSystem.gameTitle;
        },
        isAnySavefileExists() { return this.loadGlobalInfo().some((info, id) => id > 0 && this.isThisGameFile(id)); }
    };
    mv(env);
    return env;
}
test('MV missing global index enables Continue only for complete game saves, without disk writes', async () => {
    const save = completeMVSave();
    const env = titleEnvironment({'file1.rpgsave': save, 'file2.rpgsave': '{"system":{}}', 'file3.rpgsave': 'broken'});
    await env.ready;
    const warmed = env.requests.length;
    assert.equal(env.ctx.DataManager.isAnySavefileExists(), true);
    assert.equal(env.ctx.DataManager.isThisGameFile(1), true);
    assert.equal(env.ctx.DataManager.isThisGameFile(2), false);
    assert.equal(env.ctx.DataManager.isThisGameFile(3), false);
    assert.equal(env.ctx.StorageManager.load(1), save);
    assert.equal(env.ctx.StorageManager.load(0), null);
    assert.equal(env.requests.length, 3, 'inspect each orphan only once');
    assert.ok(env.requests.every(request => request.method === 'GET'), 'index inspection never writes');
    assert.equal(env.journal.size, 0);
    assert.match(env.logs.find(log => log.message.includes('file3')).message, /解压失败/);
});
test('MV directory-scoped old title index is repaired as a view and refreshed after deletion', async () => {
    const global = '[null,{"title":"Old title","globalId":"old","playtime":"12:34","custom":42}]';
    const env = titleEnvironment({'file1.rpgsave': completeMVSave(), 'global.rpgsave': global});
    await env.ready;
    assert.equal(env.ctx.DataManager.isAnySavefileExists(), true);
    const info = env.ctx.DataManager.loadGlobalInfo()[1];
    assert.equal(info.playtime, '12:34');
    assert.equal(info.custom, 42);
    assert.equal(env.ctx.DataManager._globalInfo[1].title, 'Old title');
    assert.equal(env.ctx.StorageManager.load(0), global);
    env.ctx.StorageManager.remove(1);
    assert.equal(env.ctx.DataManager.isAnySavefileExists(), false);
});
test('Continue rejection and synchronous/asynchronous load failures produce errors without changing results', async () => {
    const env = titleEnvironment({});
    let buzzed = 0;
    env.ctx.Window_TitleCommand = function () {};
    env.ctx.Window_TitleCommand.prototype = {
        currentSymbol: () => 'continue', isCurrentItemEnabled: () => false,
        processOk() { buzzed++; }
    };
    env.ctx.DataManager.loadGame = () => false;
    env.ctx.__emuInstallRuntime();
    new env.ctx.Window_TitleCommand().processOk();
    assert.equal(buzzed, 1);
    assert.ok(env.logs.some(log => log.level === 'error' && log.message.includes('继续游戏不可用')));
    assert.equal(env.ctx.DataManager.loadGame(1), false);
    assert.ok(env.logs.some(log => log.level === 'error' && log.message.includes('读取存档失败: 1')));
    env.ctx.DataManager.loadGame = async () => { throw new Error('plugin extract failed'); };
    env.ctx.__emuInstallRuntime();
    await assert.rejects(env.ctx.DataManager.loadGame(2), /plugin extract failed/);
});

// Optional integration against an unmodified MV corescript checkout. The small
// contract tests above remain fully offline and run on every build.
test('official MV managers read PC saves/config and preserve save availability',
    {skip: !process.env.EMU_MV_SOURCE_DIR}, async () => {
        const source = process.env.EMU_MV_SOURCE_DIR;
        const env = environment();
        for (const name of ['lz-string', 'StorageManager', 'DataManager', 'ConfigManager']) {
            vm.runInContext(fs.readFileSync(path.join(source, name + '.js'), 'utf8'), env.ctx);
        }
        env.ctx.Utils = {isNwjs: () => false};
        env.ctx.AudioManager = {};
        vm.runInContext('Number.prototype.clamp = function(min, max) { return Math.min(max, Math.max(min, this)); };', env.ctx);
        // Use a fresh document: the native snapshot precedes the runtime/engine.
        const codec = env.ctx.LZString;
        const next = environment({saves: {
            'config.rpgsave': codec.compressToBase64('{"alwaysDash":true}'),
            'global.rpgsave': codec.compressToBase64('[null,{"globalId":"RPGMV","title":"测试游戏"}]'),
            'file1.rpgsave': codec.compressToBase64('{"system":{"name":"存档一"}}')
        }});
        for (const name of ['lz-string', 'StorageManager', 'DataManager', 'ConfigManager']) {
            vm.runInContext(fs.readFileSync(path.join(source, name + '.js'), 'utf8'), next.ctx);
        }
        next.ctx.Utils = {isNwjs: () => false};
        next.ctx.AudioManager = {};
        next.ctx.$dataSystem = {gameTitle: '测试游戏'};
        vm.runInContext('Number.prototype.clamp = function(min, max) { return Math.min(max, Math.max(min, this)); };', next.ctx);
        next.ctx.__emuInstallRuntime();
        await next.ready;
        next.ctx.ConfigManager.load();
        assert.equal(next.ctx.ConfigManager.alwaysDash, true);
        assert.equal(next.ctx.DataManager.isAnySavefileExists(), true);
        assert.equal(next.ctx.DataManager.isThisGameFile(1), true);
        assert.equal(JSON.parse(next.ctx.StorageManager.load(1)).system.name, '存档一');
    });

test('official MV reproduces disabled Continue and loads repaired orphan/renamed-title saves',
    {skip: !process.env.EMU_MV_SOURCE_DIR}, async () => {
        for (const global of [null, '[null,{"title":"Old title","globalId":"RPGMV"}]']) {
            const env = environment({saves: {'file1.rpgsave': completeMVSave(),
                ...(global ? {'global.rpgsave': global} : {})}});
            for (const name of ['lz-string', 'StorageManager', 'DataManager']) {
                vm.runInContext(fs.readFileSync(path.join(process.env.EMU_MV_SOURCE_DIR, name + '.js'), 'utf8'), env.ctx);
            }
            env.ctx.Utils = {isNwjs: () => false};
            env.ctx.$dataSystem = {gameTitle: 'Current title'};
            // Reproduce the existing failure using the untouched MV index logic.
            env.ctx.StorageManager.load = id => id === 0 ? global : completeMVSave();
            env.ctx.StorageManager.exists = id => id === 1;
            assert.equal(env.ctx.DataManager.isAnySavefileExists(), false);
            env.ctx.__emuInstallRuntime();
            await env.ready;
            assert.equal(env.ctx.DataManager.isAnySavefileExists(), true);
            const warmed = env.requests.length;
            // This test exercises MV's real load/extract flow; object construction
            // and JsonEx class revival belong to device/game-specific checks.
            env.ctx.DataManager.createGameObjects = () => {};
            env.ctx.JsonEx = {parse: JSON.parse};
            assert.equal(env.ctx.DataManager.loadGame(1), true);
            assert.equal(env.ctx.$gameSystem.marker, 'original progress');
            assert.equal(env.ctx.$gamePlayer.marker, 'original progress');
            assert.equal(env.ctx.Utils.isNwjs(), false);
            assert.equal(env.requests.length, warmed, 'reads must be served from cache');
        }
    });


test('MV startup plugin can synchronously read an existing save before any fetch settles', () => {
    const env = environment({saves: {'file1.rpgsave': 'zip:{"system":{"ready":true}}'},
        fetch: () => new Promise(() => {})});
    const sm = mv(env);
    assert.equal(env.requests.length, 0);
    assert.equal(sm.exists(1), true);
    assert.equal(JSON.parse(sm.load(1)).system.ready, true);
    assert.equal(env.requests.length, 1);
    assert.equal(env.requests[0].synchronous, true);
});
test('MV cache stays bounded and evicted saves and backups remain readable', () => {
    const payload = JSON.stringify({value: 'x'.repeat(2 * 1024 * 1024)});
    const saves = Object.fromEntries([1, 2, 3, 4].map(id => ['file' + id + '.rpgsave', payload]));
    saves['file4.rpgsave.bak'] = 'zip:{"backup":true}';
    const env = environment({saves});
    const sm = mv(env);
    assert.equal(env.requests.length, 0);
    for (let id = 1; id <= 4; id++) assert.equal(sm.load(id), payload);
    const stats = env.ctx.__emuSaveCacheStats();
    assert.ok(stats.bytes <= stats.limit);
    assert.ok(stats.files < 4);
    const before = env.requests.length;
    assert.equal(sm.load(1), payload);
    assert.equal(env.requests.length, before + 1, 'evicted save is read again');
    assert.equal(sm.backupExists(4), true);
    sm.restoreBackup(4);
    assert.equal(sm.load(4), '{"backup":true}');
});
test('MZ does not preload unrelated saves or hide disk read errors behind IndexedDB', async () => {
    const env = environment({saves: {'file1.rmmzsave': '{}', 'file2.rmmzsave': '{}'},
        fetch: async () => ({ok: false, status: 500})});
    const sm = mz(env);
    sm.loadFromForage = async () => 'stale';
    assert.equal(env.requests.length, 0);
    await assert.rejects(sm.loadZip('file1'), /HTTP 500/);
    assert.equal(env.requests.length, 1);
});
test('MZ in-flight read cannot resurrect a deleted save', async () => {
    let release;
    const env = environment({saves: {'file1.rmmzsave': 'old'}, fetch: (url, options) => {
        if (options?.method === 'DELETE') return Promise.resolve({ok: true});
        return new Promise(resolve => { release = resolve; });
    }});
    const sm = mz(env);
    const reading = sm.loadZip('file1');
    await sm.remove('file1');
    release({ok: true, text: async () => 'old'});
    await assert.rejects(reading, /存档不存在/);
    assert.equal(sm.exists('file1'), false);
});

test('oversized pending MV writes survive eviction pressure and release after disk flush', async () => {
    let release;
    const huge = JSON.stringify({value: 'x'.repeat(5 * 1024 * 1024)});
    const env = environment({saves: {'file2.rpgsave': '{}'},
        fetch: () => new Promise(resolve => { release = resolve; })});
    const sm = mv(env);
    sm.save(1, huge);
    await tick();
    sm.load(2);
    assert.equal(sm.load(1), huge);
    assert.equal(env.journal.size, 1);
    release({ok: true});
    await env.ctx.__emuFlushSaves();
    const stats = env.ctx.__emuSaveCacheStats();
    assert.equal(env.journal.size, 0);
    assert.ok(stats.bytes <= stats.limit);
});
test('MV disk read failure throws instead of returning a nonexistent save', () => {
    const env = environment({saves: {'file1.rpgsave': '{}'}});
    const sm = mv(env);
    env.ctx.XMLHttpRequest.prototype.send = function () { this.status = 500; };
    assert.equal(sm.exists(1), true);
    assert.throws(() => sm.load(1), /HTTP 500.*file1/);
});

test('compatibility monitor slows after readiness, stops while paused/hidden, and reinstalls late plugins', () => {
    const env = environment();
    const bootTimers = () => [...env.timers.values()].filter(timer => timer.delay === 100);
    const readyTimers = () => [...env.timers.values()].filter(timer => timer.delay === 1000);
    env.ctx.SceneManager = {_scene: {constructor: {name: 'Scene_Title'}}, _sceneStarted: true, _stopped: false};
    assert.equal(bootTimers().length, 1);
    env.poll();
    assert.equal(bootTimers().length, 0);
    assert.equal(readyTimers().length, 1);
    env.ctx.__emuSetPaused(true);
    assert.equal(readyTimers().length, 0);
    env.ctx.__emuSetPaused(false);
    assert.equal(readyTimers().length, 1);
    const original = () => 'late plugin';
    env.ctx.DataManager = {loadDatabase: original};
    readyTimers()[0].fn();
    assert.notEqual(env.ctx.DataManager.loadDatabase, original);
    assert.equal(env.ctx.DataManager.loadDatabase(), 'late plugin');
    env.ctx.document.hidden = true;
    env.events.get('visibilitychange').forEach(fn => fn());
    assert.equal(readyTimers().length, 0);
    env.ctx.document.hidden = false;
    env.events.get('visibilitychange').forEach(fn => fn());
    assert.equal(readyTimers().length, 1);
    env.events.get('pagehide').forEach(fn => fn());
    env.events.get('visibilitychange').forEach(fn => fn());
    assert.equal(readyTimers().length, 0);
});

test('native small-save snapshot lets startup plugins read synchronously even when HTTP is unavailable', () => {
    const text = '{"globalSwitches":[true]}';
    const env = environment({saves: {'plugin_globaldata.rpgsave': text}, startupSaves: {'plugin_globaldata.rpgsave': text}});
    env.ctx.XMLHttpRequest = class { open() {} send() { throw new Error('Timed out'); } };
    const sm = mv(env);
    assert.deepEqual(JSON.parse(sm.load('globalData')), {globalSwitches: [true]});
    assert.equal(env.requests.length, 0);
    assert.equal(env.ctx.__emuBootstrap.startupSaves, undefined);
});

test('legacy mixed-case plugin journals remain readable and are cleared only after durable flush', async () => {
    const text = '{"progress":42}';
    const oldKey = 'emu.pending.game-a.plugin_GlobalData.rpgsave';
    const journal = new Map([[oldKey, JSON.stringify(text)]]);
    const env = environment({journal});
    const sm = mv(env);
    assert.equal(sm.load('GlobalData'), text);
    assert.equal(journal.has(oldKey), true);
    await tick();
    assert.equal(journal.size, 0);
    assert.equal(env.requests[0].url, '/save/plugin_globaldata.rpgsave');
});

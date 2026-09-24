const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const runtime = fs.readFileSync(path.join(__dirname, '../Services/GameRuntime.js'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

function environment({saves = {}, namespace = 'game-a', gameTitle = '', journal = new Map(), fetch: fetchImpl} = {}) {
    const logs = [], requests = [], timers = new Map(), events = new Map();
    let sequence = 0;
    const ctx = {
        __emuBootstrap: {saves, namespace, gameTitle, session: 'session-a'},
        console: {log() {}, warn() {}, error() {}},
        webkit: {messageHandlers: {emuLog: {postMessage(message) { logs.push(message); }}}},
        AbortController,
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
        document: {readyState: 'complete', addEventListener() {}},
        fetch(url, options) {
            requests.push({url, ...options});
            return fetchImpl ? fetchImpl(url, options) : Promise.resolve({ok: true, status: 200});
        },
        // Codec is intentionally stubbed: tests exercise storage contracts/ordering,
        // not LZString/pako's compression implementation.
        LZString: {compressToBase64: value => 'zip:' + value, decompressFromBase64: value => value.startsWith('zip:') ? value.slice(4) : null}
    };
    ctx.window = ctx;
    vm.createContext(ctx);
    vm.runInContext(runtime, ctx);
    return {ctx, logs, requests, journal, events, poll() { for (const timer of [...timers.values()]) if (timer.delay === 100) timer.fn(); }, timeout() { for (const timer of [...timers.values()]) if (timer.delay === 15000) timer.fn(); }};
}
function mv(env) {
    env.ctx.StorageManager = {load() {}, save() {}, localFilePath() {}};
    env.ctx.__emuInstallRuntime();
    return env.ctx.StorageManager;
}
function mz(env) {
    env.ctx.StorageManager = {loadZip() {}, saveZip() {}, loadObject(name) { return this.loadZip(name).then(JSON.parse); }, saveObject(name, object) { return this.saveZip(name, JSON.stringify(object)); }};
    env.ctx.__emuInstallRuntime();
    return env.ctx.StorageManager;
}

test('MV config/global/file are available on the first read, without a fetch race', () => {
    const env = environment({saves: {'config.rpgsave': '{"alwaysDash":true}', 'global.rpgsave': '[null,{"title":"test"}]', 'file1.rpgsave': 'zip:{"system":{}}'}});
    const sm = mv(env);
    assert.equal(JSON.parse(sm.load(-1)).alwaysDash, true);
    assert.equal(JSON.parse(sm.load(0))[1].title, 'test');
    assert.equal(sm.exists(1), true);
    assert.equal(sm.load(2), null);
    assert.equal(sm.load(1), '{"system":{}}');
    assert.equal(env.requests.length, 0);
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
test('MV quota errors cannot report a successful save or alter the cached file', () => {
    const env = environment({saves: {'file1.rpgsave': '{"old":true}'}});
    const sm = mv(env);
    env.ctx.localStorage.setItem = () => { throw new Error('QuotaExceededError'); };
    assert.throws(() => sm.save(1, '{"new":true}'), /QuotaExceededError/);
    assert.equal(sm.load(1), '{"old":true}');
});
test('MV backup/restore preserves compressed bytes and removes backup', async () => {
    const env = environment({saves: {'file1.rpgsave': 'zip:{"old":true}'}});
    const sm = mv(env);
    sm.backup(1);
    sm.save(1, '{"new":true}');
    assert.equal(sm.backupExists(1), true);
    sm.restoreBackup(1);
    assert.equal(sm.load(1), '{"old":true}');
    assert.equal(sm.backupExists(1), false);
    await tick();
});
test('corrupt MV saves fail with the filename rather than returning compressed garbage', () => {
    const sm = mv(environment({saves: {'config.rpgsave': 'broken', 'file1.rpgsave': '{bad json'}}));
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
    const env = environment({saves: {'file1.rmmzsave': '{"old":true}'}, fetch: async () => ({ok: false, status: 500})});
    const sm = mz(env);
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
});
test('watchdog reports missing database/scene without forcing startup', () => {
    const env = environment();
    env.ctx.DataManager = {_databaseFiles: [{name: '$dataSystem', src: 'System.json'}]};
    env.timeout();
    assert.match(env.logs.at(-1).message, /System.json/);
    assert.equal(env.logs.some(item => item.level === 'ready'), false);
});

// Optional integration against an unmodified MV corescript checkout. The small
// contract tests above remain fully offline and run on every build.
test('official MV managers read PC saves/config and preserve save availability',
    {skip: !process.env.EMU_MV_SOURCE_DIR}, () => {
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
        next.ctx.ConfigManager.load();
        assert.equal(next.ctx.ConfigManager.alwaysDash, true);
        assert.equal(next.ctx.DataManager.isAnySavefileExists(), true);
        assert.equal(next.ctx.DataManager.isThisGameFile(1), true);
        assert.equal(JSON.parse(next.ctx.StorageManager.load(1)).system.name, '存档一');
    });

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
test('MV missing global index enables Continue only for complete game saves, without disk writes', () => {
    const save = completeMVSave();
    const env = titleEnvironment({'file1.rpgsave': save, 'file2.rpgsave': '{"system":{}}', 'file3.rpgsave': 'broken'});
    assert.equal(env.ctx.DataManager.isAnySavefileExists(), true);
    assert.equal(env.ctx.DataManager.isThisGameFile(1), true);
    assert.equal(env.ctx.DataManager.isThisGameFile(2), false);
    assert.equal(env.ctx.DataManager.isThisGameFile(3), false);
    assert.equal(env.ctx.StorageManager.load(1), save);
    assert.equal(env.ctx.StorageManager.load(0), null);
    assert.equal(env.requests.length, 0);
    assert.equal(env.journal.size, 0);
    assert.match(env.logs.find(log => log.message.includes('file3')).message, /解压失败/);
});
test('MV directory-scoped old title index is repaired as a view and refreshed after deletion', () => {
    const global = '[null,{"title":"Old title","globalId":"old","playtime":"12:34","custom":42}]';
    const env = titleEnvironment({'file1.rpgsave': completeMVSave(), 'global.rpgsave': global});
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

test('official MV reproduces disabled Continue and loads repaired orphan/renamed-title saves',
    {skip: !process.env.EMU_MV_SOURCE_DIR}, () => {
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
            assert.equal(env.ctx.DataManager.isAnySavefileExists(), true);
            // This test exercises MV's real load/extract flow; object construction
            // and JsonEx class revival belong to device/game-specific checks.
            env.ctx.DataManager.createGameObjects = () => {};
            env.ctx.JsonEx = {parse: JSON.parse};
            assert.equal(env.ctx.DataManager.loadGame(1), true);
            assert.equal(env.ctx.$gameSystem.marker, 'original progress');
            assert.equal(env.ctx.$gamePlayer.marker, 'original progress');
            assert.equal(env.ctx.Utils.isNwjs(), false);
            assert.equal(env.requests.length, 0);
        }
    });

const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const swift = fs.readFileSync(path.join(__dirname, '../Views/Player/GameWebView.swift'), 'utf8');
const source = swift.match(/let audioCompatSource = """\r?\n([\s\S]*?)\r?\n        """/)[1];
function audio({native, vorbis} = {}) {
    const timers = new Map(); let id = 0;
    class AudioContext {
        constructor() { this.sampleRate = 44100; }
        decodeAudioData(buffer, success, error) { return native(buffer, success, error); }
        createBuffer(channels, length, rate) { return {channels, length, rate, copyToChannel() {}}; }
    }
    const context = {AudioContext, console: {warn() {}}, Uint8Array, stbvorbis: {decode: vorbis},
        setTimeout(fn) { timers.set(++id, fn); return id; }, clearTimeout(key) { timers.delete(key); }};
    context.window = context;
    vm.runInNewContext(source, context);
    return {ctx: new AudioContext(), timers};
}
const ogg = () => new Uint8Array([0x4f, 0x67, 0x67, 0x53]).buffer;
test('OGG worker timeout resolves a fallback exactly once, even after a late result', async () => {
    let finish;
    const env = audio({vorbis: () => new Promise(resolve => { finish = resolve; })});
    let successes = 0;
    const result = env.ctx.decodeAudioData(ogg(), () => successes++);
    [...env.timers.values()][0]();
    assert.equal((await result).length, 4410);
    finish({data: [new Float32Array(20)], sampleRate: 44100});
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(successes, 1);
    assert.equal(env.timers.size, 0);
});
test('native callback plus rejected Promise produces one fallback, no unhandled rejection', async () => {
    const env = audio({native: (_, success, error) => {
        const failure = new Error('decode failed');
        error(failure);
        return Promise.reject(failure);
    }});
    let calls = 0;
    await env.ctx.decodeAudioData(new ArrayBuffer(8), () => calls++);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls, 1);
    assert.equal(env.timers.size, 0);
});
test('OGG success retains the original input and clears its timeout', async () => {
    const input = ogg(); let received;
    const env = audio({vorbis: buffer => {
        received = buffer;
        return Promise.resolve({data: [new Float32Array(20)], sampleRate: 22050});
    }});
    const result = await env.ctx.decodeAudioData(input);
    assert.notEqual(input, received);
    assert.equal(result.length, 20);
    assert.equal(result.rate, 22050);
    assert.equal(env.timers.size, 0);
});

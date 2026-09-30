import AppKit
import WebKit

final class GameLogManager {
    static let shared = GameLogManager()
    enum Level { case info, success, warning, error, server }
    func reset() {}
    func log(_ message: String, level: Level = .info) { print(message) }
}

// Run on a logged-in macOS desktop to exercise actual WebKit, not a JS double.
@main
@MainActor
struct GameWebKitChecks {
    static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("emu-webkit-check-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("save"), withIntermediateDirectories: true)
        defer { LocalGameServer.shared.stop(); try? fm.removeItem(at: root) }
        try Data("{\"system\":{\"ready\":true}}".utf8).write(to: root.appendingPathComponent("save/file1.rpgsave"))
        try Data("<html><body>startup check</body></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        var preparation: Result<Void, Error>?
        LocalGameServer.shared.start(serving: root) { preparation = $0 }
        try wait { preparation != nil }
        try preparation!.get()
        try wait { LocalGameServer.shared.isRunning }
        var bootstrap: Result<Data, Error>?
        LocalGameServer.shared.loadBootstrap { bootstrap = $0 }
        try wait { bootstrap != nil }
        let json = String(decoding: try bootstrap!.get(), as: UTF8.self)
        let runtime = try String(contentsOfFile: "Services/GameRuntime.js", encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: "window.__emuBootstrap = \(json);\n" + runtime,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(LocalGameServer.shared.port)/index.html")!))
        try wait { web.url != nil && !web.isLoading }
        var result: Result<Any, Error>?
        web.evaluateJavaScript("""
            window.LZString = {compressToBase64: value => value};
            window.StorageManager = {load() {}, save() {}, localFilePath() {}};
            window.__emuInstallRuntime();
            if (window.__emuSaveCacheStats().files !== 0) throw new Error('Unexpected preload');
            if (!StorageManager.exists(1)) throw new Error('Save missing');
            const first = JSON.parse(StorageManager.load(1));
            if (!first.system.ready) throw new Error('Synchronous startup read failed');
            StorageManager.backup(1);
            StorageManager.save(1, '{"system":{"ready":false}}');
            StorageManager.restoreBackup(1);
            if (!JSON.parse(StorageManager.load(1)).system.ready) throw new Error('Restore failed');
            'startup-and-backup-ok';
            """) { value, error in
                if let error { result = .failure(error) }
                else { result = .success(value as Any) }
            }
        try wait { result != nil }
        guard try result!.get() as? String == "startup-and-backup-ok" else { throw URLError(.cannotParseResponse) }
        var flushed: Result<Any, Error>?
        web.callAsyncJavaScript("await window.__emuFlushSaves(); return true;", arguments: [:], in: nil, in: .page) { flushed = $0 }
        try wait { flushed != nil }
        _ = try flushed!.get()
        let disk = try String(contentsOf: root.appendingPathComponent("save/file1.rpgsave"), encoding: .utf8)
        guard disk == "{\"system\":{\"ready\":true}}" else { throw URLError(.cannotDecodeContentData) }
        print("PASS: real WebKit synchronous startup read, backup/restore and disk flush")
    }

    static func wait(_ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while !done() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

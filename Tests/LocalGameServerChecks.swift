import Foundation

// Compile alongside the production server on macOS. No UIKit or simulator needed.
final class GameLogManager {
    static let shared = GameLogManager()
    enum Level { case info, success, warning, error, server }
    func reset() {}
    func log(_ message: String, level: Level = .info) { print(message) }
}

@main
struct LocalGameServerChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ServerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor
    static func waitForServer(_ server: LocalGameServer) async throws {
        for _ in 0..<200 {
            if server.isRunning { return }
            if let error = server.lastError { throw NSError(domain: "ServerChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw URLError(.timedOut)
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("emu-server-check-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("save"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("js"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("<html>game</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("var StorageManager = {};".utf8).write(to: root.appendingPathComponent("js/rpg_managers.js"))
        try Data("abcdef".utf8).write(to: root.appendingPathComponent("audio.ogg"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("save/Config.rpgsave"))
        let server = LocalGameServer.shared
        defer { server.stop() }
        try server.start(serving: root)
        try await waitForServer(server)

        func bootstrap() async throws -> [String: Any] {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                server.loadBootstrap { continuation.resume(with: $0) }
            }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func request(_ path: String, method: String = "GET", body: String? = nil,
                     session: String? = nil, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)" + path)!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            request.timeoutInterval = 5
            request.setValue(session, forHTTPHeaderField: "X-Emu-Session")
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }

        let initial = try await bootstrap()
        let session = initial["session"] as! String
        try require((initial["saves"] as! [String: String])["config.rpgsave"] == "{}", "Snapshot normalizes filename case")
        let (script, _) = try await request("/js/rpg_managers.js")
        try require(String(decoding: script, as: UTF8.self).contains("window.__emuInstallRuntime"), "Manager hook must execute before main.js")
        let (_, missing) = try await request("/js/missing.js")
        try require(missing.statusCode == 404, "Missing JS must not be replaced with success stubs")
        let (tail, partial) = try await request("/audio.ogg", range: "bytes=-3")
        try require(partial.statusCode == 206 && String(decoding: tail, as: UTF8.self) == "def", "Suffix range")
        let (_, invalidRange) = try await request("/audio.ogg", range: "bytes=-1-2")
        try require(invalidRange.statusCode == 416, "Malformed range must not crash")
        let (empty, head) = try await request("/audio.ogg", method: "HEAD")
        try require(empty.isEmpty && head.value(forHTTPHeaderField: "Content-Length") == "6", "HEAD framing")
        let (_, unauthorized) = try await request("/save/file1.rpgsave", method: "PUT", body: "{}")
        try require(unauthorized.statusCode == 409, "Reject writes without a game session")
        let (_, written) = try await request("/save/file1.rpgsave", method: "PUT", body: "{\"name\":\"存档\"}", session: session)
        try require(written.statusCode == 200, "Save write")
        let saved = try String(contentsOf: root.appendingPathComponent("save/file1.rpgsave"), encoding: .utf8)
        try require(saved == "{\"name\":\"存档\"}", "Response must follow durable UTF-8 write")
        let (_, outside) = try await request("/index.html", method: "PUT", body: "oops", session: session)
        try require(outside.statusCode == 403, "Writes are limited to saves")
        try fm.createSymbolicLink(at: root.appendingPathComponent("save/escape.rpgsave"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("escape.rpgsave"))
        let (_, symlink) = try await request("/save/escape.rpgsave", method: "PUT", body: "oops", session: session)
        try require(symlink.statusCode == 403, "Reject symlink escape")
        try fm.removeItem(at: root.appendingPathComponent("save/escape.rpgsave"))
        let (_, removed) = try await request("/save/file1.rpgsave", method: "DELETE", session: session)
        try require(removed.statusCode == 200 && !fm.fileExists(atPath: root.appendingPathComponent("save/file1.rpgsave").path), "Delete save")
        try server.start(serving: root)
        try await waitForServer(server)
        let (_, stale) = try await request("/save/file1.rpgsave", method: "PUT", body: "{}", session: session)
        try require(stale.statusCode == 409, "Old game session cannot write after restart")
        print("PASS: LocalGameServer integration checks")
    }
}

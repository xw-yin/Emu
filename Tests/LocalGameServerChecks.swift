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
    static func start(_ server: LocalGameServer, root: URL, saves: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.start(serving: root, saveDirectory: saves) { continuation.resume(with: $0) }
        }
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
        // A cancelled preparation must never publish a listener or stale error.
        let cancelled: Result<Void, Error> = await withCheckedContinuation { continuation in
            var returned = false
            server.start(serving: root) { result in
                precondition(returned, "Preparation must not complete inline on the UI thread")
                continuation.resume(returning: result)
            }
            returned = true
            server.stop()
        }
        if case .success = cancelled { throw URLError(.unknown) }
        try require(!server.isRunning && server.lastError == nil, "Cancelled startup cannot revive server")
        try await start(server, root: root)
        try await waitForServer(server)

        func bootstrap() async throws -> [String: Any] {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                server.loadBootstrap { continuation.resume(with: $0) }
            }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func request(_ path: String, method: String = "GET", body: String? = nil,
                     session: String? = nil, range: String? = nil, extraHeaders: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)" + path)!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            request.timeoutInterval = 5
            request.setValue(session, forHTTPHeaderField: "X-Emu-Session")
            request.setValue(range, forHTTPHeaderField: "Range")
            for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }

        let initial = try await bootstrap()
        let session = initial["session"] as! String
        try require(initial["saves"] == nil, "Bootstrap must not embed full save contents (memory)")
        let startupSaves = initial["startupSaves"] as! [String: String]
        try require(startupSaves["config.rpgsave"] == "{}", "Small MV saves are ready before engine scripts")
        let initialMeta = initial["savesMeta"] as! [String: [String: Any]]
        try require((initialMeta["config.rpgsave"]?["size"] as? Int) == 2, "Snapshot normalizes filename case")
        let (initialRead, saveResponse) = try await request("/save/config.rpgsave")
        try require(String(decoding: initialRead, as: UTF8.self) == "{}", "On-demand save fetch serves content")
        try require(saveResponse.value(forHTTPHeaderField: "Cache-Control") == "no-store", "Saves never cache")
        try require(saveResponse.value(forHTTPHeaderField: "ETag") == nil, "Saves have no cache validator")
        // Simulate a provider holding one asset: saves must remain responsive.
        let blockedURL = root.appendingPathComponent("blocked.bin")
        try Data("blocked asset".utf8).write(to: blockedURL)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: blockedURL, options: .forReplacing, error: &error) { _ in
                    ready.resume()
                    _ = release.wait(timeout: .now() + 5)
                }
            }
        }
        let blockedRequest = Task { try await request("/blocked.bin") }
        try await Task.sleep(nanoseconds: 150_000_000)
        let beforeSave = Date()
        let (responsiveSave, _) = try await request("/save/config.rpgsave")
        let saveLatency = Date().timeIntervalSince(beforeSave)
        release.signal()
        print("Save read during held asset coordination: \(saveLatency)s")
        _ = try await blockedRequest.value
        try require(responsiveSave == Data("{}".utf8) && saveLatency < 1,
                    "Provider coordination must not stall save reads (\(saveLatency)s)")
        let (script, _) = try await request("/js/rpg_managers.js")
        try require(String(decoding: script, as: UTF8.self).contains("window.__emuInstallRuntime"), "Manager hook must execute before main.js")
        try Data("// global save plugin".utf8).write(to: root.appendingPathComponent("js/Drill_CoreOfGlobalSave.js"))
        let (drill, _) = try await request("/js/Drill_CoreOfGlobalSave.js")
        try require(String(decoding: drill, as: UTF8.self).contains("window.__emuInstallRuntime"), "Drill bridge before title plugins")
        let emsSource = "// legacy EMS plugin"
        let emsURL = root.appendingPathComponent("js/Drill_EventMutiSwitch.js")
        try Data(emsSource.utf8).write(to: emsURL)
        let (ems, _) = try await request("/js/Drill_EventMutiSwitch.js")
        try require(String(decoding: ems, as: UTF8.self).contains("window.__emuInstallRuntime"), "EMS compatibility installs before event refresh")
        let originalEMS = try String(contentsOf: emsURL, encoding: .utf8)
        try require(originalEMS == emsSource, "EMS adapter must not edit game files")
        let glowSource = "DrillUp.g_DCOG_shadowColorIndex = Number(DrillUp.parameters[\"默认外发光颜色ID(全局)\"] || 1);\nif( color_index == 0 ){ color_index = 11; }"
        try Data(glowSource.utf8).write(to: root.appendingPathComponent("js/Drill_DialogCharOuterGlow.js"))
        let (glow, _) = try await request("/js/Drill_DialogCharOuterGlow.js")
        try require(String(decoding: glow, as: UTF8.self).contains("|| 1) - 1;"), "Convert one-based default color")
        let untouchedGlow = try String(contentsOf: root.appendingPathComponent("js/Drill_DialogCharOuterGlow.js"), encoding: .utf8)
        try require(untouchedGlow == glowSource, "Compatibility response does not edit original plugin")
        let choiceSource = "if (this.isCancelEnabled() && index !== type && !this.isCommandEnabled(index)) { this.playBuzzerSound(); }"
        try Data(choiceSource.utf8).write(to: root.appendingPathComponent("js/MPP_ChoiceEX.js"))
        let (choice, _) = try await request("/js/MPP_ChoiceEX.js")
        try require(String(decoding: choice, as: UTF8.self).contains("index >= 0 && index < this.maxItems()"), "Guard synthetic cancel choice indices")
        let titleSource = """
        this._drill_TTG_preloadTank.push( ImageManager.loadBitmap( temp_data['src_img_file'], src_img_list[j], temp_data['tint'], temp_data['smooth'] ) );
        temp_sprite_data['src_bitmaps'].push( ImageManager.loadBitmap( temp_sprite_data['src_img_file'], temp_sprite_data['src_img'][j], temp_sprite_data['tint'], temp_sprite_data['smooth'] ) );
        temp_sprite.bitmap = temp_sprite_data['src_bitmaps'][0];
        temp_sprite.bitmap = temp_data['src_bitmaps'][inter];
        temp_sprite['_time'] += 1;
        """
        try Data(titleSource.utf8).write(to: root.appendingPathComponent("js/Drill_TitleTiledGif.js"))
        let (title, _) = try await request("/js/Drill_TitleTiledGif.js")
        let adaptedTitle = String(decoding: title, as: UTF8.self)
        try require(!adaptedTitle.contains("ImageManager.loadBitmap"), "No full-animation preload")
        try require(adaptedTitle.contains("window.__emuTitleFrame(temp_data, inter)"), "Demand-loaded title frame")
        try require(adaptedTitle.contains("if (!temp_sprite.visible) continue;"), "Skip hidden animations")
        let (_, missing) = try await request("/js/missing.js")
        try require(missing.statusCode == 404, "Missing JS must not be replaced with success stubs")
        let (tail, partial) = try await request("/audio.ogg", range: "bytes=-3")
        try require(partial.statusCode == 206 && String(decoding: tail, as: UTF8.self) == "def", "Suffix range")
        let (_, invalidRange) = try await request("/audio.ogg", range: "bytes=-1-2")
        try require(invalidRange.statusCode == 416, "Malformed range must not crash")
        let (empty, head) = try await request("/audio.ogg", method: "HEAD")
        try require(empty.isEmpty && head.value(forHTTPHeaderField: "Content-Length") == "6", "HEAD framing")
        // Cross multiple 64 KiB sends; ranges must seek rather than start at byte zero.
        let large = Data((0..<(256 * 1024 + 37)).map { UInt8($0 % 251) })
        try large.write(to: root.appendingPathComponent("large.bin"))
        let (full, fullResponse) = try await request("/large.bin")
        try require(full == large && fullResponse.statusCode == 200, "Chunked full response is byte-exact")
        let etag = fullResponse.value(forHTTPHeaderField: "ETag")!
        try require(fullResponse.value(forHTTPHeaderField: "Cache-Control") == "private, no-cache", "Static assets revalidate")
        let (unchangedBody, unchanged) = try await request("/large.bin", extraHeaders: ["If-None-Match": etag])
        try require(unchanged.statusCode == 304 && unchangedBody.isEmpty, "Unchanged assets return no body")
        let (ranged, rangedResponse) = try await request("/large.bin", range: "bytes=65530-196620")
        try require(ranged == large.subdata(in: 65530..<196621) && rangedResponse.statusCode == 206, "Range crosses send boundaries")
        let (openEnded, _) = try await request("/large.bin", range: "bytes=262140-")
        try require(openEnded == large.subdata(in: 262140..<large.count), "Open-ended range")
        let (headRangeBody, headRange) = try await request("/large.bin", method: "HEAD", range: "bytes=1-8")
        try require(headRangeBody.isEmpty && headRange.statusCode == 206 && headRange.value(forHTTPHeaderField: "Content-Length") == "8", "HEAD range metadata")
        let (ifRangeBody, ifRange) = try await request("/large.bin", range: "bytes=0-1", extraHeaders: ["If-Range": etag])
        try require(ifRange.statusCode == 200 && ifRangeBody == large, "Weak validators cannot authorize If-Range")
        try Data("changed".utf8).write(to: root.appendingPathComponent("large.bin"), options: .atomic)
        let (changedBody, changedResponse) = try await request("/large.bin", extraHeaders: ["If-None-Match": etag])
        try require(changedResponse.statusCode == 200 && changedBody == Data("changed".utf8), "Changed asset invalidates validator")
        try Data().write(to: root.appendingPathComponent("empty.bin"))
        let (emptyBody, emptyResponse) = try await request("/empty.bin")
        try require(emptyResponse.statusCode == 200 && emptyBody.isEmpty, "Empty files complete without hanging")
        // Startup bootstrap remains bounded when many small save slots exist.
        for i in 100..<106 { try Data(repeating: 65, count: 256 * 1024).write(to: root.appendingPathComponent("save/file\(i).rpgsave")) }
        try Data(repeating: 66, count: 256 * 1024 + 1).write(to: root.appendingPathComponent("save/plugin_large.rpgsave"))
        let bounded = try await bootstrap()["startupSaves"] as! [String: String]
        try require(bounded.values.reduce(0) { $0 + $1.utf8.count } <= 1024 * 1024, "Startup snapshot cap")
        try require(bounded["config.rpgsave"] == "{}" && bounded["plugin_large.rpgsave"] == nil, "Small plugin/config data take precedence; large files stay lazy")
        for i in 100..<106 { try fm.removeItem(at: root.appendingPathComponent("save/file\(i).rpgsave")) }
        try fm.removeItem(at: root.appendingPathComponent("save/plugin_large.rpgsave"))
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
        try await start(server, root: root)
        try await waitForServer(server)
        let (_, newSessionAsset) = try await request("/large.bin", extraHeaders: ["If-None-Match": changedResponse.value(forHTTPHeaderField: "ETag")!])
        try require(newSessionAsset.statusCode == 200, "Restart invalidates previous game resource cache")
        let (_, stale) = try await request("/save/file1.rpgsave", method: "PUT", body: "{}", session: session)
        try require(stale.statusCode == 409, "Old game session cannot write after restart")
        let privateSaves = root.appendingPathComponent("app-saves")
        try Data("original".utf8).write(to: root.appendingPathComponent("save/file2.rpgsave"))
        try await start(server, root: root, saves: privateSaves)
        try await waitForServer(server)
        let imported = try await bootstrap()
        let privateSession = imported["session"] as! String
        let importedMeta = imported["savesMeta"] as! [String: [String: Any]]
        try require((importedMeta["file2.rpgsave"]?["size"] as? Int) == 8, "Import original saves")
        let (importedRead, _) = try await request("/save/file2.rpgsave")
        try require(String(decoding: importedRead, as: UTF8.self) == "original", "On-demand fetch reads from private save directory")
        let (_, privateWrite) = try await request("/save/file2.rpgsave", method: "PUT", body: "new progress", session: privateSession)
        try require(privateWrite.statusCode == 200, "Write independent save")
        let original = try String(contentsOf: root.appendingPathComponent("save/file2.rpgsave"), encoding: .utf8)
        try require(original == "original", "Never alter external originals")
        let (privateRead, _) = try await request("/save/file2.rpgsave")
        try require(String(decoding: privateRead, as: UTF8.self) == "new progress", "HTTP reads agree with private snapshot")
        try await start(server, root: root, saves: privateSaves)
        try await waitForServer(server)
        let reopened = try await bootstrap()
        let reopenedMeta = reopened["savesMeta"] as! [String: [String: Any]]
        try require((reopenedMeta["file2.rpgsave"]?["size"] as? Int) == 12, "Reopen retains progress")
        let (_, privateDelete) = try await request("/save/file2.rpgsave", method: "DELETE", session: reopened["session"] as? String)
        try require(privateDelete.statusCode == 200, "Delete private save")
        try await start(server, root: root, saves: privateSaves)
        try await waitForServer(server)
        let afterDelete = try await bootstrap()
        let afterDeleteMeta = afterDelete["savesMeta"] as! [String: [String: Any]]
        try require(afterDeleteMeta["file2.rpgsave"] == nil, "Do not resurrect deleted imports")
        print("PASS: LocalGameServer integration checks")
    }
}

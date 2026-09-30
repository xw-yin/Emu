import Foundation
import Combine

final class GameLogManager {
    static let shared = GameLogManager()
    enum Level { case error }
    func log(_ message: String, level: Level) {}
}

@main
struct GameLibraryChecks {
    @MainActor
    static func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "LibraryChecks", code: line, userInfo: [NSLocalizedDescriptionKey: "Timed out at line \(line)"])
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "emu-library-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        for name in ["A", "B"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<title>\(name)</title>".utf8).write(to: folder.appendingPathComponent("index.html"))
        }
        let library = GameLibraryManager(directoryURL: root, defaults: defaults)
        try await waitUntil { library.games.count == 2 }
        // Older stored records predate cover metadata and still decode.
        var oldRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library.games[0])) as! [String: Any]
        oldRecord.removeValue(forKey: "coverImageModifiedAt")
        _ = try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: oldRecord))
        let first = library.games
        var updates = 0
        let observer = library.$games.dropFirst().sink { _ in updates += 1 }
        for _ in 0..<50 { library.loadGames() }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(library.games == first && updates == 0, "Unchanged refreshes preserve identity and skip publication")
        let reopened = GameLibraryManager(directoryURL: root, defaults: defaults)
        try await waitUntil { reopened.games.count == 2 }
        precondition(reopened.games == first, "Sandbox identity persists across manager recreation")
        let cover = root.appendingPathComponent("B/cover.png")
        try Data("cover".utf8).write(to: cover)
        library.loadGames()
        try await waitUntil { library.games[1].coverImageRelativePath?.hasSuffix(root.lastPathComponent + "/B/cover.png") == true }
        let coverDate = library.games[1].coverImageModifiedAt!
        try FileManager.default.setAttributes([.modificationDate: coverDate.addingTimeInterval(10)], ofItemAtPath: cover.path)
        library.loadGames()
        try await waitUntil { library.games[1].coverImageModifiedAt != coverDate }
        precondition(library.games[1].id == first[1].id, "Updating covers keeps the card identity")
        let survivor = library.games[1]
        library.loadGames()
        library.removeGame(first[0])
        try await waitUntil { library.games.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(library.games == [survivor], "Stale refresh cannot resurrect a removed game")
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/index.html").path))
        withExtendedLifetime(observer) {}
        print("PASS: stable library IDs, unchanged refreshes and removal race")
    }
}

import Foundation
import Combine

@main
struct GameLogChecks {
    @MainActor
    static func older(_ manager: GameLogManager) async {
        await withCheckedContinuation { continuation in manager.loadOlder { continuation.resume() } }
    }
    @MainActor
    static func export(_ manager: GameLogManager) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            manager.exportLogs { continuation.resume(with: $0) }
        }
    }
    @MainActor
    static func main() async throws {
        let manager = GameLogManager.shared
        manager.reset()
        var updates = 0
        let observer = manager.objectWillChange.sink { updates += 1 }
        manager.log("startup", level: .success)
        manager.log("warning", level: .warning)
        manager.log("failure", level: .error)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(updates == 1, "A batch publishes logs and counters once")
        precondition(manager.count(for: nil) == 3)
        precondition(manager.count(for: .warning) == 1)
        manager.selectedLevel = .warning
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(manager.visibleLogs.count == 1)
        let filtered = try await export(manager)
        precondition(filtered.contains("warning") && !filtered.contains("failure"))
        manager.preserveStartupLogs()
        for index in 0..<2100 { manager.log("runtime \(index)") }
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(manager.logs.count == 1, "Paused history remains stable as logs arrive")
        precondition(manager.count(for: nil) == 2103)
        manager.selectedLevel = nil
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(manager.logs.count == 200, "Only one page is decoded initially")
        let latestIDs = manager.logs.map(\.id)
        await older(manager)
        precondition(manager.logs.count == 400)
        precondition(Array(manager.logs.suffix(200)).map(\.id) == latestIDs, "Older pages preserve row identity")
        while manager.hasOlderLogs { await older(manager) }
        precondition(manager.logs.count == 2103 && Set(manager.logs.map(\.id)).count == 2103)
        precondition(manager.logs.first?.message == "startup" && manager.logs.last?.message == "runtime 2099")
        manager.followsLatest = true
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(manager.logs.count == 200)
        let complete = try await export(manager)
        precondition(complete.contains("startup") && complete.contains("runtime 0") && complete.contains("runtime 2099"),
                     "Export includes history outside the loaded page")
        precondition(manager.count(for: .error) == 1)
        precondition(manager.count(for: .error) == 1, "Cached counts must not accumulate")
        manager.reset()
        precondition(manager.count(for: nil) == 0)
        manager.log("stale session", level: .error)
        manager.reset()
        manager.log("new session", level: .success)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(manager.logs.map(\.message) == ["new session"] && manager.errorCount == 0,
                     "A reset must invalidate the previous scheduled flush")
        manager.reset()
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            GameLogManager.shared.log("concurrent \(index)", level: .success)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(manager.logs.count == 200 && manager.count(for: nil) == 500 && manager.loadedCount == 500,
                     "Concurrent producers lose no logs and keep a bounded live page")
        for index in 0..<450 { manager.log("warning page \(index)", level: .warning) }
        try await Task.sleep(nanoseconds: 350_000_000)
        manager.selectedLevel = .warning
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(manager.count(for: .warning) == 450 && manager.visibleLogs.count == 200)
        while manager.hasOlderLogs { await older(manager) }
        precondition(manager.visibleLogs.count == 450 && manager.visibleLogs.allSatisfy { $0.level == .warning })
        precondition(manager.visibleLogs.first?.message == "warning page 0")
        let warnings = try await export(manager)
        precondition(warnings.contains("warning page 449") && !warnings.contains("concurrent"))
        // Reset while an archive write/read is queued, not just before its timer fires.
        manager.log("queued old write")
        manager.preserveStartupLogs()
        manager.selectedLevel = nil
        manager.reset()
        manager.log("isolated new history")
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(manager.count(for: nil) == 1 && manager.logs.first?.message == "isolated new history")
        let isolated = try await export(manager)
        precondition(!isolated.contains("queued old write"))
        withExtendedLifetime(observer) {}
        print("PASS: full log counts, lazy pages, complete export, filtering, concurrent producers and reset isolation")
    }
}

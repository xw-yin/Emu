import Foundation
import Combine

@main
struct GameLogChecks {
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
        precondition(manager.visibleLogs.count == 1)
        precondition(manager.filteredText.contains("warning"))
        precondition(!manager.filteredText.contains("failure"))
        manager.preserveStartupLogs()
        for index in 0..<2100 { manager.log("runtime \(index)") }
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(manager.logs.count == 2000)
        precondition(manager.count(for: nil) == 2003)
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
        precondition(manager.logs.count == 500 && manager.loadedCount == 500, "Concurrent producers lose no logs")
        withExtendedLifetime(observer) {}
        print("PASS: log batching, filtering, concurrent producers and reset isolation")
    }
}

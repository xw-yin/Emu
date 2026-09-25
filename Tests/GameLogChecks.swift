import Foundation

@main
struct GameLogChecks {
    @MainActor
    static func main() async throws {
        let manager = GameLogManager.shared
        manager.reset()
        manager.log("startup", level: .success)
        manager.log("warning", level: .warning)
        manager.log("failure", level: .error)
        try await Task.sleep(nanoseconds: 250_000_000)
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
        print("PASS: log batching, filtering and retained startup checks")
    }
}

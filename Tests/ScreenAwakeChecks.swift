import Foundation

@main
struct ScreenAwakeChecks {
    @MainActor
    static func main() async {
        var foreground = true
        var actual = false
        var writes = 0
        let controller = ScreenAwakeController(isForeground: { foreground }, read: { actual },
            write: { actual = $0; writes += 1 }, report: { _ in })
        let first = UUID(), second = UUID()
        controller.update(owner: first, enabled: true)
        precondition(actual)
        controller.refresh()
        precondition(writes == 1, "Do not repeatedly reset an already enabled timer")
        actual = false // Simulate a system/WebKit override between lifecycle callbacks.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(actual, "Timer must recover an overwritten native flag")
        foreground = false
        controller.refresh()
        precondition(!actual, "Background must release idle timer")
        foreground = true
        controller.refresh()
        precondition(actual, "Foreground restores the retained request")
        controller.update(owner: second, enabled: true)
        controller.update(owner: first, enabled: false)
        precondition(actual, "Stale session cleanup must not disable the new owner")
        controller.update(owner: second, enabled: false)
        precondition(!actual, "Returning to library or switching off releases the request")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(!actual, "Cancelled timer must not re-enable idle prevention")
        print("Screen awake ownership, recovery and lifecycle checks passed")
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Owns the process-wide idle timer so stale player callbacks cannot undo a new session.
@MainActor
final class ScreenAwakeController {
    private var owner: UUID?
    private var requested = false
    private var timer: Timer?
    private let isForeground: () -> Bool
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private let report: (String) -> Void

    init(isForeground: @escaping () -> Bool, read: @escaping () -> Bool,
         write: @escaping (Bool) -> Void, report: @escaping (String) -> Void) {
        self.isForeground = isForeground
        self.read = read
        self.write = write
        self.report = report
    }

    func update(owner: UUID, enabled: Bool) {
        if enabled {
            self.owner = owner
            requested = true
            if timer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            guard self.owner == owner else { return }
            self.owner = nil
            requested = false
            timer?.invalidate()
            timer = nil
        }
        refresh()
    }

    func refresh() {
        let desired = requested && isForeground()
        guard read() != desired else { return }
        write(desired)
        report("屏幕常亮：请求\(desired ? "开启" : "关闭")，系统状态\(read() ? "开启" : "关闭")")
    }

    #if canImport(UIKit)
    static let shared = ScreenAwakeController(
        // Keep the request through temporary inactive states (sheets/system UI).
        // A background scene must never keep the display awake.
        isForeground: {
            UIApplication.shared.applicationState != .background &&
            UIApplication.shared.connectedScenes.contains {
                $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
            }
        },
        read: { UIApplication.shared.isIdleTimerDisabled },
        write: { UIApplication.shared.isIdleTimerDisabled = $0 },
        report: { GameLogManager.shared.log($0, level: .info) }
    )
    #endif
}

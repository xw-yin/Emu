import SwiftUI
import UIKit

@main
struct EmuApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientationDelegate
    var body: some Scene {
        WindowGroup {
            GameLibraryView()
        }
    }
}

@MainActor
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.mask
    }

    static func apply(_ mode: String) {
        switch mode {
        case "portrait": mask = .portrait
        case "portraitUpsideDown": mask = .portraitUpsideDown
        case "landscapeLeft": mask = .landscapeLeft
        case "landscapeRight": mask = .landscapeRight
        case "landscape": mask = .landscape
        default: mask = .allButUpsideDown
        }
        guard UIApplication.shared.applicationState == .active else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // Lock/unlock changes allowed orientations, not the current geometry.
            // Avoid asking windowed iPad scenes to rotate on every presentation.
            let current = UIInterfaceOrientationMask(rawValue: 1 << scene.interfaceOrientation.rawValue)
            guard !mask.contains(current) else { continue }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                GameLogManager.shared.log("屏幕方向切换失败: \(error.localizedDescription)", level: .warning)
            }
        }
    }
}

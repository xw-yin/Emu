import SwiftUI
import WebKit

/// 游戏全屏主界面：整合本地流媒体服务器、WebKit 画布与次世代悬浮控制器
struct GamePlayerView: View {
    let game: Game
    let isPresented: Bool
    let closeRequest: Int
    let onDismiss: () -> Void
    let onClose: () -> Void
    @State private var hasLaunched = false
    @State private var isClosing = false
    
    @State private var webView: WKWebView? = nil
    @ObservedObject private var server = LocalGameServer.shared
    @State private var errorMessage: String? = nil
    @State private var didCleanup = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("gameOrientation") private var gameOrientation = "auto"
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if server.isRunning, let url = URL(string: "http://127.0.0.1:\(server.port)/index.html") {
                // 底层：游戏画面
                GameWebView(url: url, webView: $webView, isGameVisible: isPresented)
                    .ignoresSafeArea()
                
                // 次层：流体玻璃虚拟控制器浮层
                VirtualControllerOverlay(gameTitle: game.title, webView: webView,
                    onExitGame: onDismiss, onCloseGame: exitGame)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.yellow)
                    
                    Text("启动游戏失败")
                        .font(.headline)
                        .foregroundStyle(.white)
                    
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("返回游戏库", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                }
            } else {
                // 正在拉起服务与等待端口就绪
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                        .scaleEffect(1.2)
                    
                    Text("正在拉起本地流媒体内核...")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            
            // 顶层：加载与运行实时日志终端浮层（充当实时极客进度条，可在进入场景后自动折叠）
            GameLogConsoleOverlay()
        }
        .onAppear {
            if !hasLaunched { hasLaunched = true; launchGame() }
        }
        .onDisappear {
            cleanup()
        }
        .onReceive(server.$lastError) { message in
            if let message = message { errorMessage = message }
        }
        .onChange(of: gameOrientation) { _ in OrientationDelegate.apply(isPresented ? gameOrientation : "auto") }
        .onChange(of: keepScreenAwake) { _ in updateIdleTimer() }
        .onChange(of: scenePhase) { _ in updateIdleTimer() }
        .onChange(of: closeRequest) { _ in exitGame() }
        .onChange(of: isPresented) { _ in updatePresentation() }
        .onChange(of: webView) { _ in updatePresentation() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.async { updatePresentation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            UIApplication.shared.isIdleTimerDisabled = false
            webView?.evaluateJavaScript("window.__emuSetPaused?.(true)", completionHandler: nil)
        }
        .statusBarHidden(isPresented)
    }
    
    private func launchGame() {
        didCleanup = false
        errorMessage = nil
        // 保持屏幕常亮
        updateIdleTimer()
        
        guard let rootURL = GameLibraryManager.shared.getGameRootURL(for: game) else {
            let msg = "未找到游戏根目录或 index.html"
            errorMessage = msg
            GameLogManager.shared.log(msg, level: .error)
            return
        }
        
        do {
            let saveDirectory: URL? = game.isExternalStorage
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("GameSaves", isDirectory: true)
                    .appendingPathComponent(game.id.uuidString, isDirectory: true)
                : nil
            try LocalGameServer.shared.start(serving: rootURL, saveDirectory: saveDirectory)
        } catch {
            let msg = "本地服务启动失败: \(error.localizedDescription)"
            errorMessage = msg
            GameLogManager.shared.log(msg, level: .error)
        }
    }
    
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !didCleanup && isPresented && keepScreenAwake && UIApplication.shared.applicationState == .active
    }

    private func updatePresentation() {
        updateIdleTimer()
        OrientationDelegate.apply(isPresented ? gameOrientation : "auto")
        let paused = !isPresented || UIApplication.shared.applicationState != .active
        webView?.evaluateJavaScript("window.__emuSetPaused?.(\(paused ? "true" : "false"))", completionHandler: nil)
    }

    private func exitGame() {
        guard !isClosing else { return }
        isClosing = true
        guard let webView = webView else { cleanup(); onClose(); return }
        webView.callAsyncJavaScript("window.__emuSetPaused?.(true); window.__emuReleaseKeys?.(); if(window.__emuFlushSaves) await window.__emuFlushSaves(); return true;",
            arguments: [:], in: nil, in: .page) { _ in
                cleanup()
                onClose()
            }
    }
    
    private func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        OrientationDelegate.apply("auto")
        LocalGameServer.shared.stop()
        GameLibraryManager.shared.releaseGameAccess()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

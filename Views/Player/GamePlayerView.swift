import SwiftUI
import WebKit

/// 游戏全屏主界面：整合本地流媒体服务器、WebKit 画布与次世代悬浮控制器
struct GamePlayerView: View {
    let game: Game
    let onDismiss: () -> Void
    
    @State private var webView: WKWebView? = nil
    @State private var isServerReady: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if isServerReady, let url = URL(string: "http://127.0.0.1:\(LocalGameServer.shared.port)/index.html") {
                // 底层：游戏画面
                GameWebView(url: url, webView: $webView)
                    .ignoresSafeArea()
                
                // 顶层：流体玻璃虚拟控制器浮层
                VirtualControllerOverlay(gameTitle: game.title, webView: webView) {
                    exitGame()
                }
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
                // 加载中光效
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                        .scaleEffect(1.4)
                    
                    Text("正在载入虚拟世界...")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .onAppear {
            launchGame()
        }
        .onDisappear {
            cleanup()
        }
        .statusBarHidden(true)
    }
    
    private func launchGame() {
        // 保持屏幕常亮
        UIApplication.shared.isIdleTimerDisabled = true
        
        guard let rootURL = GameLibraryManager.shared.getGameRootURL(for: game) else {
            errorMessage = "未找到游戏根目录或 index.html"
            return
        }
        
        do {
            try LocalGameServer.shared.start(serving: rootURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.isServerReady = true
            }
        } catch {
            errorMessage = "本地服务启动失败: \(error.localizedDescription)"
        }
    }
    
    private func exitGame() {
        cleanup()
        onDismiss()
    }
    
    private func cleanup() {
        LocalGameServer.shared.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

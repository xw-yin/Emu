import SwiftUI
import UniformTypeIdentifiers

/// 游戏库主界面：符合 iOS 标准大标题收缩、全透明沉浸导航与双模响应式适配
struct GameLibraryView: View {
    @StateObject private var libraryManager = GameLibraryManager.shared
    @State private var selectedGame: Game? = nil
    @State private var gameVisible = false
    @State private var pendingGame: Game? = nil
    @State private var confirmSwitch = false
    @State private var closeRequest = 0
    @State private var isImporting: Bool = false
    @State private var importErrorMessage: String? = nil
    @State private var showImportError: Bool = false
    @State private var gamePendingRemoval: Game? = nil
    @State private var showRemoveDialog: Bool = false
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    
    // 响应式自适应网格
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isLandscape ? 175 : 160, maximum: 230), spacing: 18)]
    }
    
    init() {
        // 全面清除导航栏的死板分层背景与阴影，实现 100% 全透明自然融合
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear
        appearance.backgroundColor = .clear
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景：纯白色，随系统深浅色自适应（浅色纯白，深色纯黑/深邃）
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                // 主体卡片画廊
                ScrollView(showsIndicators: false) {
                    if libraryManager.games.isEmpty {
                        emptyStateView
                            .padding(.top, isLandscape ? 24 : 60)
                    } else {
                        VStack(spacing: 20) {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(libraryManager.games) { game in
                                    GameCardView(game: game) {
                                        if let active = selectedGame,
                                           active.rootDirectoryName != game.rootDirectoryName || active.isExternalStorage != game.isExternalStorage {
                                            pendingGame = game
                                            confirmSwitch = true
                                        } else {
                                            if selectedGame == nil { selectedGame = game }
                                            gameVisible = true
                                        }
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            HapticManager.shared.buttonPress()
                                            gamePendingRemoval = game
                                            showRemoveDialog = true
                                        } label: {
                                            Label("从游戏库移除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            
                            Text("Emu v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") (Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                        }
                        // 横屏下避开灵动岛与顶部悬浮标题，竖屏保持黄金边距
                        .padding(.horizontal, isLandscape ? 64 : 20)
                        .padding(.top, isLandscape ? 48 : 14)
                        .padding(.bottom, isLandscape ? 24 : 90)
                    }
                }
                
                // 仅在竖屏状态下显示底部悬浮操作岛，横屏时自动收纳至顶部导航栏以最大化视野
                if !isLandscape {
                    VStack {
                        Spacer()
                        floatingControlBar
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("游戏")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar) // 强制消除任何分层毛玻璃横条
            .toolbar {
                // 横屏时：与游戏内视觉高度统一的超薄液态玻璃胶囊按钮组 (深色与浅色模式均完美呈现)
                if isLandscape {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 8) {
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                libraryManager.loadGames()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("刷新")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.85) : Color.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                HapticManager.shared.actionBurst()
                                isImporting = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("导入")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(4)
                        .liquidGlass(cornerRadius: 24, strokeOpacity: 0.28)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .overlay {
            if let game = selectedGame {
                GamePlayerView(game: game, isPresented: gameVisible, closeRequest: closeRequest, onDismiss: {
                    gameVisible = false
                }, onClose: {
                    gameVisible = false
                    selectedGame = nil
                    libraryManager.loadGames()
                    if let next = pendingGame {
                        pendingGame = nil
                        DispatchQueue.main.async {
                            selectedGame = next
                            gameVisible = true
                        }
                    }
                })
                .id(game.id)
                .opacity(gameVisible ? 1 : 0)
                .allowsHitTesting(gameVisible)
                .accessibilityHidden(!gameVisible)
            }
        }
        .alert("关闭当前游戏并打开另一款？", isPresented: $confirmSwitch) {
            Button("取消", role: .cancel) { pendingGame = nil }
            Button("关闭并打开", role: .destructive) {
                closeRequest += 1
            }
        } message: { Text("当前游戏未保存的进度会丢失。") }
        .alert("导入提示", isPresented: $showImportError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "未知错误")
        }
        .confirmationDialog("移除游戏", isPresented: $showRemoveDialog, presenting: gamePendingRemoval) { game in
            Button("从游戏库移除", role: .destructive) {
                HapticManager.shared.buttonPress()
                libraryManager.removeGame(game)
            }
            Button("取消", role: .cancel) {}
        } message: { game in
            Text("将「\(game.title)」从游戏库中移除，仅删除库内条目，不会删除任何游戏文件。")
        }
    }
    
    // MARK: - 空状态自适应视图
    private var emptyStateView: some View {
        Group {
            if isLandscape {
                // 横屏紧凑横向排布
                HStack(spacing: 20) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("游戏库空空如也")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("点击右上角文件夹图标选择游戏文件夹即可开始游玩")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
            } else {
                // 竖屏经典纵向排布
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 90, height: 90)
                        
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                    }
                    
                    VStack(spacing: 6) {
                        Text("游戏库空空如也")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        
                        Text("点击下方按钮选择游戏文件夹即可开始游玩")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("Emu v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") (Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 40)
            }
        }
    }
    
    // MARK: - 竖屏底部悬浮控制岛
    private var floatingControlBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                HapticManager.shared.buttonPress()
                libraryManager.loadGames()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                    Text("刷新")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemFill))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            
            Button(action: {
                HapticManager.shared.actionBurst()
                isImporting = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16, weight: .bold))
                    Text("选择游戏文件夹")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.blue)
                .clipShape(Capsule())
                .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 14, y: 5)
    }
    
    // MARK: - 导入处理
    private func handleImport(result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let selectedURL = urls.first else { return }
            
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDir), isDir.boolValue {
                let success = libraryManager.linkExternalDirectory(at: selectedURL)
                if success {
                    HapticManager.shared.actionBurst()
                } else {
                    importErrorMessage = "该目录及其子目录中未检测到 index.html 网页文件，请确保选中包含游戏内容的文件夹。"
                    showImportError = true
                }
            } else if selectedURL.pathExtension.lowercased() == "zip" {
                importErrorMessage = "检测到 ZIP 压缩包：请在 iOS「文件」App 中轻触该压缩包解压为文件夹后，直接点击这里选择该文件夹，即可 0 秒免拷贝秒开！"
                showImportError = true
            }
        } catch {
            importErrorMessage = "导入授权失败: \(error.localizedDescription)"
            showImportError = true
        }
    }
}

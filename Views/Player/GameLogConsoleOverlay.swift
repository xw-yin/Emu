import SwiftUI
import UIKit

/// 游戏加载与运行实时日志终端浮层（可在加载黑屏期充当极客进度条，直观排查任何白屏/黑屏/脚本错误）
struct GameLogConsoleOverlay: View {
    @ObservedObject var logManager = GameLogManager.shared
    @State private var browsingHistory = false
    @State private var copyingLogs = false
    @State private var copyError: String?
    @State private var scrollToLatestPage = true

    
    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            if logManager.isVisible {
                if logManager.isCollapsed {
                    // 折叠态：左上角超小型灵动胶囊徽标
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            logManager.isCollapsed = false
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("日志 \(logManager.count(for: nil))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            if logManager.errorCount > 0 {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 66)
                } else {
                    // 展开态：极具科幻感的暗黑半透明毛玻璃日志终端
                    VStack(alignment: .leading, spacing: 0) {
                        // 顶部状态栏
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(logManager.isGameReady ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                if geometry.size.width > geometry.size.height {
                                Text(logManager.isGameReady ? "游戏已就绪" : "正在加载资源...")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                }
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                filterButton("全部", level: nil)
                                filterButton("警告", level: .warning)
                                filterButton("错误", level: .error)

                                Button {
                                    copyingLogs = true
                                    logManager.exportLogs { result in
                                        copyingLogs = false
                                        switch result {
                                        case .success(let text): UIPasteboard.general.string = text
                                        case .failure(let error): copyError = error.localizedDescription
                                        }
                                    }
                                    HapticManager.shared.buttonPress()
                                } label: {
                                    Image(systemName: "doc.on.doc.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.black.opacity(0.8))
                                        .frame(width: 16, height: 16)
                                        .background(Color.white.opacity(0.8), in: Circle())
                                }
                                .disabled(copyingLogs)
                                .accessibilityLabel("复制当前筛选的完整日志")

                                Button {
                                    browsingHistory = false
                                    logManager.followsLatest.toggle()
                                } label: {
                                    Image(systemName: logManager.followsLatest ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(logManager.followsLatest ? Color.cyan : Color.white.opacity(0.8))
                                }
                                .accessibilityLabel("跟随最新日志")
                                .accessibilityValue(logManager.followsLatest ? "已开启" : "已关闭")

                                // 最小化按钮
                                Button(action: {
                                    HapticManager.shared.buttonPress()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        logManager.isCollapsed = true
                                    }
                                }) {
                                    Image(systemName: "chevron.up.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                
                                // 关闭按钮
                                Button(action: {
                                    HapticManager.shared.buttonPress()
                                    withAnimation {
                                        logManager.isVisible = false
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.65))
                        
                        Divider()
                            .background(Color.white.opacity(0.12))
                        
                        // 日志列表滚动区
                        ScrollViewReader { scrollProxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    if let error = logManager.storageError {
                                        Text("日志保存失败：\(error)").foregroundStyle(.red)
                                    }
                                    if logManager.hasOlderLogs {
                                        Button {
                                            loadOlder(using: scrollProxy)
                                        } label: {
                                            Text(logManager.isLoadingHistory ? "正在加载…" : "加载更早日志")
                                                .font(.system(size: 11))
                                        }
                                        .disabled(logManager.isLoadingHistory)
                                        .background(GeometryReader { proxy in
                                            Color.clear.preference(key: LogHistoryPosition.self,
                                                value: proxy.frame(in: .named("logScroll")).minY)
                                        })
                                    }
                                    if logManager.visibleLogs.isEmpty {
                                        Text(logManager.selectedLevel == nil ? "暂无日志" : "当前分类暂无日志")
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(logManager.visibleLogs) { item in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(logManager.formatTime(item.timestamp))
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                                .padding(.top, 1)
                                            
                                            Text("[\(item.level.tag)]")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundStyle(item.level.color)
                                                .padding(.top, 1)
                                            
                                            Text(item.message)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(item.level.color)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .textSelection(.enabled)
                                        }
                                        .contextMenu {
                                            Button("复制此条") { UIPasteboard.general.string = item.message }
                                        }
                                        .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .coordinateSpace(name: "logScroll")
                            .simultaneousGesture(DragGesture().onChanged { _ in
                                browsingHistory = true
                                scrollToLatestPage = false
                                logManager.followsLatest = false
                            })
                            .onPreferenceChange(LogHistoryPosition.self) { position in
                                if browsingHistory, position >= 0, position < 260 {
                                    loadOlder(using: scrollProxy)
                                }
                            }
                            .onAppear {
                                scrollToLatestPage = true
                                if let last = logManager.visibleLogs.last { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                            }
                            .onChange(of: logManager.followsLatest) { _, following in
                                if following, let last = logManager.visibleLogs.last { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                            }
                            .onChange(of: logManager.selectedLevel) {
                                browsingHistory = false
                                scrollToLatestPage = true
                            }
                            .onChange(of: logManager.logs.last?.id) {
                                if logManager.followsLatest || scrollToLatestPage, let last = logManager.visibleLogs.last {
                                    withAnimation(.easeOut(duration: 0.1)) {
                                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                    scrollToLatestPage = false
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.cyan.opacity(0.5), Color.white.opacity(0.1), Color.cyan.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                    }
                    .shadow(color: Color.black.opacity(0.6), radius: 20, y: 10)
                    .padding(.horizontal, 16)
                    .padding(.top, 66)
                }
            }
        }
        .allowsHitTesting(true)
        .alert("复制日志失败", isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })) {
            Button("确定") { copyError = nil }
        } message: { Text(copyError ?? "") }
        }
    }
    private func loadOlder(using proxy: ScrollViewProxy) {
        guard logManager.hasOlderLogs, !logManager.isLoadingHistory else { return }
        let anchor = logManager.visibleLogs.first?.id
        browsingHistory = false
        scrollToLatestPage = false
        logManager.loadOlder {
            DispatchQueue.main.async {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    private func filterButton(_ title: String, level: GameLogManager.LogItem.Level?) -> some View {
        Button {
            logManager.selectedLevel = level
            logManager.followsLatest = false
        } label: {
            Text("\(title) \(logManager.count(for: level))")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(logManager.selectedLevel == level ? 0.28 : 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityValue(logManager.selectedLevel == level ? "已选中" : "未选中")
    }

}

private struct LogHistoryPosition: PreferenceKey {
    static var defaultValue: CGFloat = -1000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

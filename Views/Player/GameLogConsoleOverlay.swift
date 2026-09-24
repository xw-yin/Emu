import SwiftUI

/// 游戏加载与运行实时日志终端浮层（可在加载黑屏期充当极客进度条，直观排查任何白屏/黑屏/脚本错误）
struct GameLogConsoleOverlay: View {
    @ObservedObject var logManager = GameLogManager.shared
    @State private var isCollapsed: Bool = false
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if logManager.isVisible {
                if isCollapsed {
                    // 折叠态：左上角超小型灵动胶囊徽标
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isCollapsed = false
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("日志 \(logManager.loadedCount)")
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
                                Text(logManager.isGameReady ? "游戏已就绪" : "正在加载资源...")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                // 统计标签
                                HStack(spacing: 4) {
                                    Text("已加载")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text("\(logManager.loadedCount)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.green)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                
                                if logManager.errorCount > 0 {
                                    HStack(spacing: 4) {
                                        Text("异常")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Text("\(logManager.errorCount)")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.red)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.red.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                
                                // 最小化按钮
                                Button(action: {
                                    HapticManager.shared.buttonPress()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        isCollapsed = true
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
                                    ForEach(logManager.logs) { item in
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
                                        .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .onChange(of: logManager.logs.count) { _ in
                                if let last = logManager.logs.last {
                                    withAnimation(.easeOut(duration: 0.1)) {
                                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                                    }
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
    }
}

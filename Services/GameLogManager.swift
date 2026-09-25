import SwiftUI
import Combine

/// 游戏加载与运行实时日志管理器（支持从原生服务器和 WebKit JavaScript 核心双向收集日志）
final class GameLogManager: ObservableObject {
    static let shared = GameLogManager()
    
    struct LogItem: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String
        
        enum Level: String {
            case info
            case success
            case warning
            case error
            case server
            
            var color: Color {
                switch self {
                case .info: return Color.white.opacity(0.85)
                case .success: return Color.green
                case .warning: return Color.yellow
                case .error: return Color.red
                case .server: return Color.cyan
                }
            }
            
            var tag: String {
                switch self {
                case .info: return "INFO"
                case .success: return "OK"
                case .warning: return "WARN"
                case .error: return "ERR"
                case .server: return "HTTP"
                }
            }
        }
    }
    
    @Published var logs: [LogItem] = []
    @Published var isVisible: Bool = true
    @Published var loadedCount: Int = 0
    @Published var errorCount: Int = 0
    @Published var isGameReady: Bool = false
    
    @Published var isCollapsed = false
    @Published var followsLatest = true
    @Published var manuallyOpened = false
    @Published var errorsOnly = false
    @Published private var startupLogs: [LogItem] = []
    private let maxLogCount = 2000

    var retainedLogs: [LogItem] {
        let startupIDs = Set(startupLogs.map(\.id))
        return startupLogs + logs.filter { !startupIDs.contains($0.id) }
    }

    var exportedText: String {
        retainedLogs.map { "[\(formatTime($0.timestamp))] [\($0.level.tag)] \($0.message)" }.joined(separator: "\n")
    }

    var visibleLogs: [LogItem] {
        errorsOnly ? retainedLogs.filter { $0.level == .error } : retainedLogs
    }

    var filteredText: String {
        visibleLogs.map { "[\(formatTime($0.timestamp))] [\($0.level.tag)] \($0.message)" }.joined(separator: "\n")
    }

    func preserveStartupLogs() { startupLogs = logs }

    func openConsole() {
        manuallyOpened = true
        followsLatest = false
        isCollapsed = false
        isVisible = true
    }
    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SS"
        return df
    }()
    
    private init() {}
    
    func reset() {
        logs.removeAll()
        startupLogs.removeAll()
        manuallyOpened = false
        errorsOnly = false
        followsLatest = true
        isCollapsed = false
        loadedCount = 0
        errorCount = 0
        isGameReady = false
        isVisible = true
    }
    
    func log(_ message: String, level: LogItem.Level = .info) {
        let now = Date()
        DispatchQueue.main.async {
            let item = LogItem(timestamp: now, level: level, message: message)
            self.logs.append(item)
            if self.logs.count > self.maxLogCount {
                self.logs.removeFirst(self.logs.count - self.maxLogCount)
            }
            if level == .success {
                self.loadedCount += 1
            } else if level == .error {
                self.errorCount += 1
                self.isVisible = true
            }
        }
    }
    
    func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

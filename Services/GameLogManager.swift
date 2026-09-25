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
    
    @Published var logs: [LogItem] = [] { didSet { invalidateDerivedLogs() } }
    @Published var isVisible: Bool = true
    @Published var loadedCount: Int = 0
    @Published var errorCount: Int = 0
    @Published var isGameReady: Bool = false
    
    @Published var isCollapsed = false
    @Published var followsLatest = true
    @Published var manuallyOpened = false
    @Published var selectedLevel: LogItem.Level? = nil { didSet { cachedVisible = nil } }
    @Published private var startupLogs: [LogItem] = [] { didSet { invalidateDerivedLogs() } }
    private let maxLogCount = 2000

    private var cachedRetained: [LogItem]?
    private var cachedVisible: [LogItem]?
    private var cachedCounts: [LogItem.Level: Int] = [:]
    private var pendingLogs: [LogItem] = []
    private var flushWork: DispatchWorkItem?

    private func invalidateDerivedLogs() {
        cachedRetained = nil
        cachedVisible = nil
        cachedCounts.removeAll(keepingCapacity: true)
    }

    var retainedLogs: [LogItem] {
        if let cached = cachedRetained { return cached }
        let startupIDs = Set(startupLogs.map(\.id))
        let result = startupLogs + logs.filter { !startupIDs.contains($0.id) }
        cachedRetained = result
        for item in result { cachedCounts[item.level, default: 0] += 1 }
        return result
    }

    func count(for level: LogItem.Level?) -> Int {
        let all = retainedLogs
        return level.map { cachedCounts[$0, default: 0] } ?? all.count
    }

    var exportedText: String {
        retainedLogs.map { "[\(formatTime($0.timestamp))] [\($0.level.tag)] \($0.message)" }.joined(separator: "\n")
    }

    var visibleLogs: [LogItem] {
        if let cached = cachedVisible { return cached }
        let result = selectedLevel.map { level in retainedLogs.filter { $0.level == level } } ?? retainedLogs
        cachedVisible = result
        return result
    }

    var filteredText: String {
        visibleLogs.map { "[\(formatTime($0.timestamp))] [\($0.level.tag)] \($0.message)" }.joined(separator: "\n")
    }

    func preserveStartupLogs() { flushPendingLogs(); startupLogs = logs }

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
        flushWork?.cancel()
        flushWork = nil
        pendingLogs.removeAll()
        logs.removeAll()
        startupLogs.removeAll()
        manuallyOpened = false
        selectedLevel = nil
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
            self.pendingLogs.append(item)
            if level == .error { self.isVisible = true }
            if self.flushWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.flushPendingLogs() }
                self.flushWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
        }
    }
    
    private func flushPendingLogs() {
        flushWork?.cancel()
        flushWork = nil
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll(keepingCapacity: true)
        loadedCount += batch.filter { $0.level == .success }.count
        errorCount += batch.filter { $0.level == .error }.count
        var next = logs + batch
        if next.count > maxLogCount { next.removeFirst(next.count - maxLogCount) }
        logs = next
    }

    func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

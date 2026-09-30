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
    
    private struct LogBatch {
        var logs: [LogItem] = []
        var loadedCount = 0
        var errorCount = 0
    }
    @Published private var batch = LogBatch() { didSet { invalidateDerivedLogs() } }
    var logs: [LogItem] { batch.logs }
    var loadedCount: Int { batch.loadedCount }
    var errorCount: Int { batch.errorCount }
    @Published var isVisible: Bool = true
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
    private let pendingLock = NSLock()
    private var flushToken: UUID?

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
        pendingLock.lock()
        flushToken = nil
        pendingLogs.removeAll()
        pendingLock.unlock()
        batch = LogBatch()
        startupLogs.removeAll()
        manuallyOpened = false
        selectedLevel = nil
        followsLatest = true
        isCollapsed = false
        isGameReady = false
        isVisible = true
    }
    
    func log(_ message: String, level: LogItem.Level = .info) {
        let item = LogItem(timestamp: Date(), level: level, message: message)
        pendingLock.lock()
        pendingLogs.append(item)
        let token: UUID?
        if flushToken == nil {
            token = UUID()
            flushToken = token
        } else { token = nil }
        pendingLock.unlock()
        // Producers share a buffer; only the first log schedules a main-thread hop.
        if let token {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.flushPendingLogs(expectedToken: token)
            }
        }
    }

    private func flushPendingLogs(expectedToken: UUID? = nil) {
        pendingLock.lock()
        if let expectedToken, flushToken != expectedToken {
            pendingLock.unlock()
            return
        }
        let pending = pendingLogs
        pendingLogs.removeAll(keepingCapacity: true)
        flushToken = nil
        pendingLock.unlock()
        guard !pending.isEmpty else { return }
        var next = batch.logs + pending
        if next.count > maxLogCount { next.removeFirst(next.count - maxLogCount) }
        // A single published value keeps log rows and counters in one UI update.
        batch = LogBatch(logs: next,
                         loadedCount: batch.loadedCount + pending.filter { $0.level == .success }.count,
                         errorCount: batch.errorCount + pending.filter { $0.level == .error }.count)
        if pending.contains(where: { $0.level == .error }), !isVisible { isVisible = true }
    }

    func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

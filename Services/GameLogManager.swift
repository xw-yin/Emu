import SwiftUI
import Combine

/// 游戏加载与运行实时日志管理器（支持从原生服务器和 WebKit JavaScript 核心双向收集日志）
final class GameLogManager: ObservableObject {
    static let shared = GameLogManager()
    
    struct LogItem: Identifiable, Equatable, Codable {
        var id = UUID()
        let timestamp: Date
        let level: Level
        let message: String
        
        enum Level: String, Codable {
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
        var counts: [LogItem.Level: Int] = [:]
        var oldest = Int.max
    }
    @Published private var batch = LogBatch()
    var logs: [LogItem] { batch.logs }
    var visibleLogs: [LogItem] { batch.logs }
    var loadedCount: Int { count(for: .success) }
    var errorCount: Int { count(for: .error) }
    @Published var isVisible = true
    @Published var isGameReady = false
    @Published var isCollapsed = false
    @Published var followsLatest = true {
        didSet { if followsLatest && !oldValue { loadLatest() } }
    }
    @Published var manuallyOpened = false
    @Published var selectedLevel: LogItem.Level? {
        didSet { if selectedLevel != oldValue { loadLatest() } }
    }
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var storageError: String?
    var hasOlderLogs: Bool { batch.logs.count < count(for: selectedLevel) && batch.oldest > 0 }
    private let pageSize = 200
    private let archive = LogArchive()
    private var session = UUID()
    private var viewRevision = UUID()
    private var pendingLogs: [LogItem] = []
    private let pendingLock = NSLock()
    private var flushToken: UUID?

    func count(for level: LogItem.Level?) -> Int {
        level.map { batch.counts[$0, default: 0] } ?? batch.counts.values.reduce(0, +)
    }

    // Read the entire selected history off the UI thread, including unloaded pages.
    func exportLogs(completion: @escaping (Result<String, Error>) -> Void) {
        flushPendingLogs()
        let generation = session
        let level = selectedLevel
        archive.queue.async {
            let result = Result { try self.archive.export(level: level) }
            DispatchQueue.main.async {
                guard self.session == generation else {
                    completion(.failure(CocoaError(.userCancelled)))
                    return
                }
                completion(result)
            }
        }
    }

    func preserveStartupLogs() { flushPendingLogs() }

    func loadOlder(completion: @escaping () -> Void = {}) {
        guard hasOlderLogs, !isLoadingHistory else { completion(); return }
        followsLatest = false
        readPage(before: batch.oldest, prepend: true, completion: completion)
    }

    private func loadLatest() {
        viewRevision = UUID()
        isLoadingHistory = false
        readPage(before: Int.max, prepend: false)
    }

    private func readPage(before: Int, prepend: Bool, completion: @escaping () -> Void = {}) {
        let generation = session
        let revision = viewRevision
        let level = selectedLevel
        isLoadingHistory = true
        archive.queue.async {
            let result = Result { try self.archive.page(level: level, before: before, limit: self.pageSize) }
            DispatchQueue.main.async {
                guard self.session == generation, self.viewRevision == revision else { completion(); return }
                self.isLoadingHistory = false
                switch result {
                case .success(let page):
                    self.batch.logs = prepend ? page.logs + self.batch.logs : page.logs
                    self.batch.oldest = page.oldest
                case .failure(let error): self.storageError = error.localizedDescription
                }
                completion()
            }
        }
    }

    func openConsole() {
        manuallyOpened = true
        followsLatest = false
        isCollapsed = false
        isVisible = true
        loadLatest()
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
        session = UUID()
        viewRevision = UUID()
        archive.queue.async { self.archive.reset() }
        batch = LogBatch()
        manuallyOpened = false
        selectedLevel = nil
        followsLatest = true
        isLoadingHistory = false
        storageError = nil
        isCollapsed = false
        isGameReady = false
        isVisible = true
    }

    func log(_ message: String, level: LogItem.Level = .info) {
        let item = LogItem(timestamp: Date(), level: level, message: message)
        pendingLock.lock()
        pendingLogs.append(item)
        let token: UUID?
        if flushToken == nil { token = UUID(); flushToken = token }
        else { token = nil }
        pendingLock.unlock()
        if let token {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.flushPendingLogs(expectedToken: token)
            }
        }
    }

    private func flushPendingLogs(expectedToken: UUID? = nil) {
        pendingLock.lock()
        if let expectedToken, flushToken != expectedToken { pendingLock.unlock(); return }
        let pending = pendingLogs
        pendingLogs.removeAll(keepingCapacity: true)
        flushToken = nil
        pendingLock.unlock()
        guard !pending.isEmpty else { return }
        let generation = session
        let revision = viewRevision
        let level = selectedLevel
        let following = followsLatest
        archive.queue.async {
            let result = Result { () -> LogBatch in
                try self.archive.append(pending)
                let page = following ? try self.archive.page(level: level, before: Int.max, limit: self.pageSize)
                    : (logs: [], oldest: Int.max)
                return LogBatch(logs: page.logs, counts: self.archive.counts, oldest: page.oldest)
            }
            DispatchQueue.main.async {
                guard self.session == generation else { return }
                switch result {
                case .success(var next):
                    if !self.followsLatest || self.viewRevision != revision {
                        next.logs = self.batch.logs
                        next.oldest = self.batch.oldest
                    }
                    self.batch = next
                case .failure(let error): self.storageError = error.localizedDescription
                }
                if pending.contains(where: { $0.level == .error }), !self.isVisible { self.isVisible = true }
            }
        }
    }

    func formatTime(_ date: Date) -> String { timeFormatter.string(from: date) }
}

/// Only compact offsets remain in memory; log messages live in a session file.
private final class LogArchive {
    let queue = DispatchQueue(label: "com.emu.logs.archive", qos: .utility)
    private struct Record { let offset: UInt64; let length: Int }
    private var records: [Record] = []
    private var indices: [GameLogManager.LogItem.Level: [Int]] = [:]
    private(set) var counts: [GameLogManager.LogItem.Level: Int] = [:]
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmuSessionLogs", isDirectory: true)
    private var url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func reset() {
        try? handle?.close()
        handle = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        records.removeAll()
        indices.removeAll()
        counts.removeAll()
        offset = 0
    }

    private func open() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A new process starts a new game session; remove its predecessor's journal.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        let file = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        url = file
        let opened = try FileHandle(forUpdating: file)
        handle = opened
        return opened
    }

    func append(_ items: [GameLogManager.LogItem]) throws {
        let file = try open()
        try file.seek(toOffset: offset)
        for item in items {
            var data = try encoder.encode(item)
            data.append(10)
            try file.write(contentsOf: data)
            indices[item.level, default: []].append(records.count)
            records.append(Record(offset: offset, length: data.count))
            counts[item.level, default: 0] += 1
            offset += UInt64(data.count)
        }
    }

    private func read(_ index: Int) throws -> GameLogManager.LogItem {
        let record = records[index]
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        try handle.seek(toOffset: record.offset)
        guard let data = try handle.read(upToCount: record.length), data.count == record.length else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try decoder.decode(GameLogManager.LogItem.self, from: data)
    }

    func page(level: GameLogManager.LogItem.Level?, before: Int, limit: Int) throws -> (logs: [GameLogManager.LogItem], oldest: Int) {
        // Binary search avoids rescanning the full history on every scroll page.
        let candidates = level.map { indices[$0, default: []] }
        let count = candidates?.count ?? records.count
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if (candidates?[mid] ?? mid) < before { low = mid + 1 } else { high = mid }
        }
        let start = max(0, low - limit)
        let selected = (start..<low).map { candidates?[$0] ?? $0 }
        return (try selected.map { try read($0) }, selected.first ?? 0)
    }

    func export(level: GameLogManager.LogItem.Level?) throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        let selected = level.map { indices[$0, default: []] } ?? Array(records.indices)
        var text = ""
        for index in selected {
            let item = try read(index)
            if !text.isEmpty { text += "\n" }
            text += "[\(formatter.string(from: item.timestamp))] [\(item.level.tag)] \(item.message)"
        }
        return text
    }
}

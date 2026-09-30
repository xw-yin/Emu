import Foundation
import Combine

/// 游戏库管理器：统一调度沙盒内置游戏与外部“下载”目录零拷贝直读游戏
final class GameLibraryManager: ObservableObject {
    static let shared = GameLibraryManager()
    
    @Published var games: [Game] = []
    
    private let gamesDirectoryName = "Games"
    private let externalGamesKey = "com.emu.external_games_v1"
    private let ignoredSandboxGamesKey = "com.emu.ignored_sandbox_games_v1"
    private let scanQueue = DispatchQueue(label: "com.emu.library.scan", qos: .userInitiated)
    private let refreshLock = NSLock()
    private var refreshGeneration = 0
    private let sandboxIDsKey = "com.emu.sandbox_game_ids_v1"
    private let directoryOverride: URL?
    private let defaults: UserDefaults
    private var activeSecurityScopedURL: URL?
    
    private var gamesDirectoryURL: URL {
        if let directoryOverride { return directoryOverride }
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documentsURL.appendingPathComponent(gamesDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    init(directoryURL: URL? = nil, defaults: UserDefaults = .standard) {
        directoryOverride = directoryURL
        self.defaults = defaults
        loadGames()
    }
    
    /// 加载并刷新全部游戏（沙盒内部 + 外部下载目录）
    func loadGames() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadGames() }
            return
        }
        refreshLock.lock()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshLock.unlock()
        // Snapshot mutable preferences before background work. A newer refresh
        // invalidates older scans, including scans preceding remove/import.
        let ignored = ignoredSandboxGameNames()
        let external = loadExternalBookmarkGames()
        scanQueue.async {
            guard self.isCurrentRefresh(generation) else { return }
            let allGames = self.scanSandboxGames(ignored: ignored, generation: generation) + self.refreshExternalCovers(external)
            DispatchQueue.main.async {
                guard self.isCurrentRefresh(generation) else { return }
                if self.games != allGames { self.games = allGames }
            }
        }
    }

    /// 核心功能：直接关联外部文件夹（如“我的iPhone/下载/某个游戏”），零拷贝原地直读
    func linkExternalDirectory(at url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else {
            print("[GameLibrary] 无法获取外部目录安全权限")
            return false
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        guard let gameRoot = findGameRoot(within: url) else {
            print("[GameLibrary] 外部目录中未找到 index.html")
            return false
        }
        
        // 生成永久持久化安全书签
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            print("[GameLibrary] 创建安全书签失败")
            return false
        }
        
        let engine = detectEngine(at: gameRoot)
        let title = extractGameTitle(from: gameRoot) ?? url.lastPathComponent
        let coverPath = findCoverImage(at: gameRoot)
        
        var currentExternal = loadSavedExternalGames()
        let existingID = currentExternal.first { $0.rootDirectoryName == url.lastPathComponent }?.id
        let externalGame = Game(
            id: existingID ?? UUID(),
            title: title,
            rootDirectoryName: url.lastPathComponent,
            engineType: engine,
            coverImageRelativePath: coverPath,
            coverImageModifiedAt: coverModificationDate(coverPath),
            isExternalStorage: true,
            securityBookmarkData: bookmark
        )
        
        // 去重
        currentExternal.removeAll { $0.rootDirectoryName == externalGame.rootDirectoryName }
        currentExternal.append(externalGame)
        saveExternalGames(currentExternal)
        
        loadGames()
        return true
    }
    
    /// 获取某个游戏的启动真实 URL（自动处理外部安全作用域权限激活）
    func getGameRootURL(for game: Game) -> URL? {
        releaseGameAccess()
        let root: URL?
        if game.isExternalStorage, let bookmarkData = game.securityBookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                // 激活外部访问权限
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    GameLogManager.shared.log("游戏目录授权失效，请在游戏库重新关联原文件夹", level: .error)
                    return nil
                }
                activeSecurityScopedURL = resolvedURL
                if isStale, let refreshed = try? resolvedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    var saved = loadSavedExternalGames()
                    if let index = saved.firstIndex(where: { $0.id == game.id }) {
                        saved[index].securityBookmarkData = refreshed
                        saveExternalGames(saved)
                    }
                }
                root = findGameRoot(within: resolvedURL)
            } else {
                root = nil
            }
        } else {
            let folder = gamesDirectoryURL.appendingPathComponent(game.rootDirectoryName)
            root = findGameRoot(within: folder)
        }
        
        if let rootURL = root, !game.isExternalStorage {
            // 确保 save 目录预先存在，方便存放与读写存档
            let saveDir = rootURL.appendingPathComponent("save", isDirectory: true)
            if !FileManager.default.fileExists(atPath: saveDir.path) {
                try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            }
        }
        return root
    }

    func releaseGameAccess() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }
    
    // MARK: - 私有辅助
    private func isCurrentRefresh(_ generation: Int) -> Bool {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        return refreshGeneration == generation
    }

    private func scanSandboxGames(ignored: Set<String>, generation: Int) -> [Game] {
        var scanned: [Game] = []
        let fileManager = FileManager.default
        var savedIDs = defaults.dictionary(forKey: sandboxIDsKey) as? [String: String] ?? [:]
        let oldIDs = savedIDs
        guard let contents = try? fileManager.contentsOfDirectory(at: gamesDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        for folder in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isCurrentRefresh(generation) else { return [] }
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                if ignored.contains(folder.lastPathComponent) { continue }
                if let gameRoot = findGameRoot(within: folder) {
                    let engine = detectEngine(at: gameRoot)
                    let title = extractGameTitle(from: gameRoot) ?? folder.lastPathComponent
                    let cover = findCoverImage(at: gameRoot)
                    let name = folder.lastPathComponent
                    let id = savedIDs[name].flatMap(UUID.init(uuidString:)) ?? UUID()
                    savedIDs[name] = id.uuidString
                    let added = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    scanned.append(Game(
                        id: id,
                        title: title,
                        rootDirectoryName: folder.lastPathComponent,
                        engineType: engine,
                        dateAdded: added,
                        coverImageRelativePath: cover,
                        coverImageModifiedAt: coverModificationDate(cover),
                        isExternalStorage: false
                    ))
                }
            }
        }
        if savedIDs != oldIDs { defaults.set(savedIDs, forKey: sandboxIDsKey) }
        return scanned
    }
    
    private func refreshExternalCovers(_ games: [Game]) -> [Game] {
        games.map { game in
            guard let bookmark = game.securityBookmarkData else { return game }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { return game }
            defer { url.stopAccessingSecurityScopedResource() }
            var updated = game
            updated.coverImageModifiedAt = coverModificationDate(game.coverImageRelativePath)
            return updated
        }
    }

    private func loadExternalBookmarkGames() -> [Game] {
        return loadSavedExternalGames()
    }
    
    private func loadSavedExternalGames() -> [Game] {
        guard let data = defaults.data(forKey: externalGamesKey),
              let list = try? JSONDecoder().decode([Game].self, from: data) else {
            return []
        }
        return list
    }
    
    private func saveExternalGames(_ list: [Game]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: externalGamesKey)
        }
    }
    
    /// 从游戏库中移除条目：仅删除库内记录，不删除任何游戏文件。
    /// 外部游戏删除持久化书签条目；沙盒游戏记入忽略名单（扫描时跳过）。
    func removeGame(_ game: Game) {
        if game.isExternalStorage {
            var saved = loadSavedExternalGames()
            saved.removeAll { $0.id == game.id }
            saveExternalGames(saved)
        } else {
            var ignored = ignoredSandboxGameNames()
            ignored.insert(game.rootDirectoryName)
            defaults.set(Array(ignored), forKey: ignoredSandboxGamesKey)
        }
        loadGames()
    }
    
    private func ignoredSandboxGameNames() -> Set<String> {
        Set(defaults.stringArray(forKey: ignoredSandboxGamesKey) ?? [])
    }
    
    private func findGameRoot(within folder: URL) -> URL? {
        let directIndex = folder.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: directIndex.path) {
            return folder
        }
        
        guard let subdirs = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        
        for sub in subdirs {
            let nestedIndex = sub.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: nestedIndex.path) {
                return sub
            }
        }
        return nil
    }
    
    private func detectEngine(at rootURL: URL) -> GameEngineType {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootURL.appendingPathComponent("js/rmmz_core.js").path) {
            return .rpgMakerMZ
        }
        if fm.fileExists(atPath: rootURL.appendingPathComponent("js/rpg_core.js").path) {
            return .rpgMakerMV
        }
        if fm.fileExists(atPath: rootURL.appendingPathComponent("game/config.txt").path) ||
           fm.fileExists(atPath: rootURL.appendingPathComponent("webgal").path) {
            return .webGal
        }
        return .unknown
    }
    
    private func extractGameTitle(from rootURL: URL) -> String? {
        let indexFile = rootURL.appendingPathComponent("index.html")
        guard let content = try? String(contentsOf: indexFile, encoding: .utf8) else { return nil }
        if let range = content.range(of: "(?<=<title>)(.*?)(?=</title>)", options: .regularExpression) {
            let title = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty && title != "RPG Maker MV" && title != "RPG Maker MZ" {
                return title
            }
        }
        return nil
    }
    
    private func coverModificationDate(_ path: String?) -> Date? {
        guard let path else { return nil }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func findCoverImage(at rootURL: URL) -> String? {
        let candidates = ["icon/icon.png", "img/system/IconSet.png", "cover.jpg", "cover.png"]
        for c in candidates {
            let fullURL = rootURL.appendingPathComponent(c)
            if FileManager.default.fileExists(atPath: fullURL.path) {
                return fullURL.path
            }
        }
        return nil
    }
}

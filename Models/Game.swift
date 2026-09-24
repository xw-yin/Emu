import Foundation

enum GameEngineType: String, Codable {
    case rpgMakerMV = "RPG Maker MV"
    case rpgMakerMZ = "RPG Maker MZ"
    case webGal = "WebGal / HTML5"
    case unknown = "HTML5 Unknown"
    
    var iconName: String {
        switch self {
        case .rpgMakerMV: return "gamecontroller.fill"
        case .rpgMakerMZ: return "sparkles.tv.fill"
        case .webGal: return "character.book.closed.fill"
        case .unknown: return "cube.transparent"
        }
    }
}

/// 游戏元数据模型（支持沙盒内部与外部下载目录零拷贝直读）
struct Game: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var rootDirectoryName: String
    var engineType: GameEngineType
    var dateAdded: Date
    var lastPlayed: Date?
    var coverImageRelativePath: String?
    
    // 零拷贝直读外部目录专属字段
    var isExternalStorage: Bool = false
    var securityBookmarkData: Data? = nil
    
    init(
        id: UUID = UUID(),
        title: String,
        rootDirectoryName: String,
        engineType: GameEngineType,
        dateAdded: Date = Date(),
        lastPlayed: Date? = nil,
        coverImageRelativePath: String? = nil,
        isExternalStorage: Bool = false,
        securityBookmarkData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.rootDirectoryName = rootDirectoryName
        self.engineType = engineType
        self.dateAdded = dateAdded
        self.lastPlayed = lastPlayed
        self.coverImageRelativePath = coverImageRelativePath
        self.isExternalStorage = isExternalStorage
        self.securityBookmarkData = securityBookmarkData
    }
}

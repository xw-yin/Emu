import Foundation
import Combine

/// 按键配置文件持久化服务
final class KeyMappingManager: ObservableObject {
    static let shared = KeyMappingManager()
    
    private let storageKeyPrefix = "com.emu.keyprofile."
    
    private init() {}
    
    /// 加载指定游戏的键位方案（如果没有保存过则返回默认的 ARPG 预设）
    func loadProfile(for gameTitle: String) -> GameKeyProfile {
        let key = storageKeyPrefix + gameTitle
        if let data = UserDefaults.standard.data(forKey: key),
           let profile = try? JSONDecoder().decode(GameKeyProfile.self, from: data) {
            return profile
        }
        return .actionRPG
    }
    
    /// 保存某个游戏的自定义键位配置
    func saveProfile(_ profile: GameKeyProfile, for gameTitle: String) {
        let key = storageKeyPrefix + gameTitle
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    /// 重置为预设方案
    func resetProfile(to preset: GameKeyProfile, for gameTitle: String) -> GameKeyProfile {
        saveProfile(preset, for: gameTitle)
        return preset
    }
}

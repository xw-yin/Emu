import SwiftUI

/// 单个自定义动作按键定义
struct CustomActionButton: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String              // 按键显示文字 (如 "Q", "TAB", "ATK")
    var subLabel: String?          // 副标题 (如 "PageDown")
    var key: String                // 键盘 key (如 "q", "Tab", "1")
    var code: String               // 键盘 code (如 "KeyQ", "Tab", "Digit1")
    var colorName: String          // 主题色 (cyan, pink, mint, orange, purple, yellow)
    var relativeX: CGFloat         // 相对屏幕右下角的水平偏移 (负数)
    var relativeY: CGFloat         // 相对屏幕底部的垂直偏移 (负数)
    var size: CGFloat = 58         // 按钮大小
    var isDeletable: Bool = true   // 是否允许删除
    
    var color: Color {
        switch colorName.lowercased() {
        case "pink": return .pink
        case "mint": return .mint
        case "orange": return .orange
        case "purple": return .purple
        case "yellow": return .yellow
        default: return .cyan
        }
    }
}

/// 某款游戏的按键方案配置文件
struct GameKeyProfile: Identifiable, Codable {
    var id: UUID = UUID()
    var profileName: String
    var dpadRelativeX: CGFloat = 28    // 十字键距左边距
    var dpadRelativeY: CGFloat = 24    // 十字键距底边距
    var actionButtons: [CustomActionButton]
    
    /// 标准 RPG Maker 预设 (Z, X, Shift)
    static var standardRPG: GameKeyProfile {
        GameKeyProfile(
            profileName: "标准 JRPG",
            actionButtons: [
                CustomActionButton(label: "A", subLabel: "OK", key: "Enter", code: "Enter", colorName: "cyan", relativeX: -28, relativeY: -32, isDeletable: false),
                CustomActionButton(label: "B", subLabel: "MENU", key: "Escape", code: "Escape", colorName: "pink", relativeX: -108, relativeY: -56, isDeletable: false),
                CustomActionButton(label: "RUN", subLabel: "Shift", key: "Shift", code: "ShiftLeft", colorName: "mint", relativeX: -188, relativeY: -20, isDeletable: false)
            ]
        )
    }
    
    /// 动作 / 扩展 RPG 预设 (增加 Q/W 翻页、Tab、空格)
    static var actionRPG: GameKeyProfile {
        GameKeyProfile(
            profileName: "扩展 ARPG (翻页/快捷栏)",
            actionButtons: [
                // 基础三键
                CustomActionButton(label: "A", subLabel: "OK", key: "Enter", code: "Enter", colorName: "cyan", relativeX: -28, relativeY: -32, isDeletable: false),
                CustomActionButton(label: "B", subLabel: "MENU", key: "Escape", code: "Escape", colorName: "pink", relativeX: -108, relativeY: -56, isDeletable: false),
                CustomActionButton(label: "RUN", subLabel: "Shift", key: "Shift", code: "ShiftLeft", colorName: "mint", relativeX: -188, relativeY: -20, isDeletable: false),
                // 快捷扩展按键
                CustomActionButton(label: "Q", subLabel: "Prev", key: "q", code: "KeyQ", colorName: "orange", relativeX: -188, relativeY: -86),
                CustomActionButton(label: "W", subLabel: "Next", key: "w", code: "KeyW", colorName: "orange", relativeX: -108, relativeY: -122),
                CustomActionButton(label: "TAB", subLabel: "Map", key: "Tab", code: "Tab", colorName: "purple", relativeX: -28, relativeY: -98)
            ]
        )
    }
    
    /// 数字快捷栏预设 (1, 2, 3, 4 + Space)
    static var numberedHotbar: GameKeyProfile {
        GameKeyProfile(
            profileName: "数字技能栏 (1~4 + 跳过)",
            actionButtons: [
                CustomActionButton(label: "A", subLabel: "OK", key: "Enter", code: "Enter", colorName: "cyan", relativeX: -28, relativeY: -32, isDeletable: false),
                CustomActionButton(label: "B", subLabel: "MENU", key: "Escape", code: "Escape", colorName: "pink", relativeX: -108, relativeY: -56, isDeletable: false),
                CustomActionButton(label: "1", subLabel: "Skill", key: "1", code: "Digit1", colorName: "yellow", relativeX: -248, relativeY: -20),
                CustomActionButton(label: "2", subLabel: "Skill", key: "2", code: "Digit2", colorName: "yellow", relativeX: -188, relativeY: -76),
                CustomActionButton(label: "3", subLabel: "Skill", key: "3", code: "Digit3", colorName: "yellow", relativeX: -108, relativeY: -122),
                CustomActionButton(label: "SPC", subLabel: "Skip", key: " ", code: "Space", colorName: "purple", relativeX: -28, relativeY: -98)
            ]
        )
    }
}

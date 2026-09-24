import SwiftUI

/// 单个自定义动作按键定义
struct CustomActionButton: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String              // 按键显示文字 (如 "Q", "TAB", "ATK", "M")
    var subLabel: String?          // 副标题 (如 "PageDown", "地图", "背包")
    var key: String                // 键盘 key (如 "q", "Tab", "m")
    var code: String               // 键盘 code (如 "KeyQ", "Tab", "KeyM")
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
    
    /// 动作 / 扩展 RPG 预设 (增加 Q/W 翻页、Tab、空格、C 确定等)
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

// MARK: - 全量按键注册表与分类 (支持 A~Z 全 26 字母、0~9 数字、功能键与自定义键位)

/// 单个键盘键位原型定义
struct KeyDefinition: Identifiable, Hashable {
    let id: String
    let label: String              // 如 "A", "Tab", "Space"
    let key: String                // DOM key 属性 (如 "a", "Tab", " ")
    let code: String               // DOM code 属性 (如 "KeyA", "Tab", "Space")
    let description: String        // 说明 (如 "字母 A", "空格跳过")
    let category: KeyCategory
}

enum KeyCategory: String, CaseIterable, Identifiable {
    case letters = "字母 A-Z"
    case numbers = "数字 0-9"
    case controls = "控制与常用"
    case function = "功能 F1-F12"
    case custom = "自定义自由输入"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .letters: return "textformat"
        case .numbers: return "number"
        case .controls: return "gamecontroller"
        case .function: return "f.cursive"
        case .custom: return "pencil.and.outline"
        }
    }
}

/// 键位仓库：完整收录 A-Z 26 个字母、0-9 数字、F1-F12 功能键及常用控制键
struct KeyRegistry {
    /// 完整 26 个英文字母按键定义 (A 到 Z 无遗漏)
    static let letters: [KeyDefinition] = {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        return chars.map { char in
            let letter = String(char)
            let lower = letter.lowercased()
            return KeyDefinition(
                id: "key_\(lower)",
                label: letter,
                key: lower,
                code: "Key\(letter)",
                description: "字母 \(letter)",
                category: .letters
            )
        }
    }()
    
    /// 0 到 9 数字键
    static let numbers: [KeyDefinition] = {
        (0...9).map { d in
            KeyDefinition(
                id: "digit_\(d)",
                label: "\(d)",
                key: "\(d)",
                code: "Digit\(d)",
                description: "数字键 \(d)",
                category: .numbers
            )
        }
    }()
    
    /// 常用控制与导航键位
    static let controls: [KeyDefinition] = [
        KeyDefinition(id: "ctrl_enter", label: "Enter", key: "Enter", code: "Enter", description: "确认 / 决定 (OK)", category: .controls),
        KeyDefinition(id: "ctrl_esc", label: "Esc", key: "Escape", code: "Escape", description: "取消 / 菜单 (Menu)", category: .controls),
        KeyDefinition(id: "ctrl_space", label: "Space", key: " ", code: "Space", description: "空格 / 跳过 / 确认", category: .controls),
        KeyDefinition(id: "ctrl_shift", label: "Shift", key: "Shift", code: "ShiftLeft", description: "加速 / 奔跑 (Run)", category: .controls),
        KeyDefinition(id: "ctrl_tab", label: "Tab", key: "Tab", code: "Tab", description: "切换 / 地图 (Map)", category: .controls),
        KeyDefinition(id: "ctrl_ctrl", label: "Ctrl", key: "Control", code: "ControlLeft", description: "控制键 (Control)", category: .controls),
        KeyDefinition(id: "ctrl_alt", label: "Alt", key: "Alt", code: "AltLeft", description: "Alt 键", category: .controls),
        KeyDefinition(id: "ctrl_backspace", label: "Back", key: "Backspace", code: "Backspace", description: "退格键", category: .controls),
        KeyDefinition(id: "ctrl_pageup", label: "PgUp", key: "PageUp", code: "PageUp", description: "上一页 / 翻页", category: .controls),
        KeyDefinition(id: "ctrl_pagedown", label: "PgDn", key: "PageDown", code: "PageDown", description: "下一页 / 翻页", category: .controls),
        KeyDefinition(id: "ctrl_up", label: "↑", key: "ArrowUp", code: "ArrowUp", description: "方向键 上", category: .controls),
        KeyDefinition(id: "ctrl_down", label: "↓", key: "ArrowDown", code: "ArrowDown", description: "方向键 下", category: .controls),
        KeyDefinition(id: "ctrl_left", label: "←", key: "ArrowLeft", code: "ArrowLeft", description: "方向键 左", category: .controls),
        KeyDefinition(id: "ctrl_right", label: "→", key: "ArrowRight", code: "ArrowRight", description: "方向键 右", category: .controls)
    ]
    
    /// F1 到 F12 功能键
    static let functionKeys: [KeyDefinition] = {
        (1...12).map { f in
            KeyDefinition(
                id: "func_f\(f)",
                label: "F\(f)",
                key: "F\(f)",
                code: "F\(f)",
                description: "功能键 F\(f)",
                category: .function
            )
        }
    }()
    
    static var allKeys: [KeyDefinition] {
        letters + numbers + controls + functionKeys
    }
    
    /// 根据输入的字符智能解析 key / code / label
    static func resolve(input: String) -> (key: String, code: String, label: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (key: "Enter", code: "Enter", label: "OK")
        }
        
        // 1. 精确匹配已有键位
        if let match = allKeys.first(where: {
            $0.label.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.key.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.code.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return (key: match.key, code: match.code, label: match.label)
        }
        
        // 2. 单个英文字母 (如 "c", "g", "m", "z")
        if trimmed.count == 1, let char = trimmed.first, char.isLetter {
            let letter = String(char).uppercased()
            return (key: letter.lowercased(), code: "Key\(letter)", label: letter)
        }
        
        // 3. 单个数字 (如 "5", "8")
        if trimmed.count == 1, let char = trimmed.first, char.isNumber {
            let num = String(char)
            return (key: num, code: "Digit\(num)", label: num)
        }
        
        // 4. F1 - F12
        if trimmed.uppercased().hasPrefix("F"), let num = Int(trimmed.dropFirst()), num >= 1 && num <= 12 {
            return (key: "F\(num)", code: "F\(num)", label: "F\(num)")
        }
        
        // 5. 兜底任意自定义按键
        return (key: trimmed, code: trimmed, label: trimmed.uppercased())
    }
}

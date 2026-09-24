import SwiftUI

/// 常见键盘键位快速选择选项
struct KeyOption: Identifiable {
    let id: String
    let label: String
    let key: String
    let code: String
}

let commonKeyOptions: [KeyOption] = [
    KeyOption(id: "tab", label: "Tab (切换/地图)", key: "Tab", code: "Tab"),
    KeyOption(id: "space", label: "Space (空格/跳过)", key: " ", code: "Space"),
    KeyOption(id: "q", label: "Q (左翻页/技能)", key: "q", code: "KeyQ"),
    KeyOption(id: "w", label: "W (右翻页/技能)", key: "w", code: "KeyW"),
    KeyOption(id: "e", label: "E (交互/背包)", key: "e", code: "KeyE"),
    KeyOption(id: "r", label: "R (换弹/大招)", key: "r", code: "KeyR"),
    KeyOption(id: "c", label: "C (确认/副动作)", key: "c", code: "KeyC"),
    KeyOption(id: "f", label: "F (交互/调查)", key: "f", code: "KeyF"),
    KeyOption(id: "1", label: "数字 1", key: "1", code: "Digit1"),
    KeyOption(id: "2", label: "数字 2", key: "2", code: "Digit2"),
    KeyOption(id: "3", label: "数字 3", key: "3", code: "Digit3"),
    KeyOption(id: "4", label: "数字 4", key: "4", code: "Digit4"),
    KeyOption(id: "f5", label: "F5 (快速重载)", key: "F5", code: "F5"),
    KeyOption(id: "f12", label: "F12 (游戏复位)", key: "F12", code: "F12")
]

/// 次世代流体玻璃按键配置面板
struct KeyMappingEditorSheet: View {
    let gameTitle: String
    @Binding var currentProfile: GameKeyProfile
    @Binding var isLayoutEditModeActive: Bool
    let onProfileUpdated: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAddKeySheet: Bool = false
    @State private var newKeyLabel: String = "C"
    @State private var newKeySubLabel: String = "ACT"
    @State private var selectedOptionIndex: Int = 0
    @State private var selectedColor: String = "cyan"
    
    private let availableColors = ["cyan", "pink", "mint", "orange", "purple", "yellow"]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 1. 快速预设方案切换
                        VStack(alignment: .leading, spacing: 12) {
                            Text("预设方案模板")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            HStack(spacing: 12) {
                                presetButton(title: "标准 JRPG", preset: .standardRPG)
                                presetButton(title: "扩展 ARPG", preset: .actionRPG)
                                presetButton(title: "数字快捷栏", preset: .numberedHotbar)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        
                        // 2. 屏幕自由拖拽排布模式开关
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("自由拖拽排布按键")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("开启后可直接在游戏画面上拖拽任意按键位置")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: $isLayoutEditModeActive)
                                .labelsHidden()
                                .tint(.cyan)
                        }
                        .padding(16)
                        .liquidGlass(cornerRadius: 18, strokeOpacity: 0.2)
                        .padding(.horizontal, 20)
                        
                        // 3. 当前按键清单与管理
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("当前动作按键列表 (\(currentProfile.actionButtons.count))")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .textCase(.uppercase)
                                
                                Spacer()
                                
                                Button(action: { showingAddKeySheet = true }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle.fill")
                                        Text("添加快捷键")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    .foregroundStyle(.cyan)
                                }
                            }
                            
                            ForEach($currentProfile.actionButtons) { $btn in
                                HStack(spacing: 14) {
                                    // 模拟按键小图标
                                    ZStack {
                                        Circle()
                                            .fill(btn.color.opacity(0.2))
                                            .frame(width: 42, height: 42)
                                        Text(btn.label)
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundStyle(btn.color)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text("按键: \(btn.label)")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(.white)
                                            if let sub = btn.subLabel {
                                                Text("(\(sub))")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            }
                                        }
                                        
                                        Text("映射键盘: \(btn.code)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.cyan.opacity(0.8))
                                    }
                                    
                                    Spacer()
                                    
                                    if btn.isDeletable {
                                        Button(action: {
                                            HapticManager.shared.buttonRelease()
                                            currentProfile.actionButtons.removeAll { $0.id == btn.id }
                                            saveAndSync()
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.pink.opacity(0.8))
                                                .padding(8)
                                        }
                                    } else {
                                        Text("核心键")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.3))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(12)
                                .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("按键与快捷键定制")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        saveAndSync()
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.cyan)
                }
            }
            .sheet(isPresented: $showingAddKeySheet) {
                addCustomKeyModal
            }
        }
    }
    
    // MARK: - 预设按钮
    private func presetButton(title: String, preset: GameKeyProfile) -> some View {
        Button(action: {
            HapticManager.shared.actionBurst()
            currentProfile = preset
            saveAndSync()
        }) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
        }
    }
    
    // MARK: - 新增按键弹窗
    private var addCustomKeyModal: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()
                
                Form {
                    Section("按钮显示") {
                        TextField("按键名称 (如 C, F, Q)", text: $newKeyLabel)
                        TextField("副标题说明 (如 技能, 翻页)", text: $newKeySubLabel)
                    }
                    
                    Section("映射键盘键位") {
                        Picker("选择目标键位", selection: $selectedOptionIndex) {
                            ForEach(0..<commonKeyOptions.count, id: \.self) { idx in
                                Text(commonKeyOptions[idx].label).tag(idx)
                            }
                        }
                    }
                    
                    Section("发光色彩主题") {
                        HStack(spacing: 12) {
                            ForEach(availableColors, id: \.self) { color in
                                Circle()
                                    .fill(colorFromName(color))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if selectedColor == color {
                                            Circle().stroke(Color.white, lineWidth: 2)
                                        }
                                    }
                                    .onTapGesture {
                                        selectedColor = color
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("添加快捷按键")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showingAddKeySheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        let opt = commonKeyOptions[selectedOptionIndex]
                        let newBtn = CustomActionButton(
                            label: newKeyLabel.isEmpty ? opt.key.uppercased() : newKeyLabel,
                            subLabel: newKeySubLabel.isEmpty ? nil : newKeySubLabel,
                            key: opt.key,
                            code: opt.code,
                            colorName: selectedColor,
                            relativeX: -140,
                            relativeY: -90
                        )
                        currentProfile.actionButtons.append(newBtn)
                        saveAndSync()
                        showingAddKeySheet = false
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(.cyan)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private func colorFromName(_ name: String) -> Color {
        switch name {
        case "pink": return .pink
        case "mint": return .mint
        case "orange": return .orange
        case "purple": return .purple
        case "yellow": return .yellow
        default: return .cyan
        }
    }
    
    private func saveAndSync() {
        KeyMappingManager.shared.saveProfile(currentProfile, for: gameTitle)
        onProfileUpdated()
    }
}

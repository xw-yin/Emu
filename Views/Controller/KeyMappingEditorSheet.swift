import SwiftUI

/// 次世代流体玻璃按键定制面板（支持 A~Z 全量字母、数字、功能键与任意键位自由定制）
struct KeyMappingEditorSheet: View {
    let gameTitle: String
    @Binding var currentProfile: GameKeyProfile
    @Binding var isLayoutEditModeActive: Bool
    let onProfileUpdated: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingKeyModal: Bool = false
    @State private var editingButton: CustomActionButton? = nil
    
    // 模态弹窗表单状态
    @State private var selectedCategory: KeyCategory = .letters
    @State private var selectedKeyDefinition: KeyDefinition = KeyRegistry.letters.first(where: { $0.label == "C" }) ?? KeyRegistry.letters[2]
    @State private var customKeyInput: String = ""
    @State private var buttonLabel: String = "C"
    @State private var buttonSubLabel: String = "ACT"
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
                        
                        // 3. 当前按键清单与管理 (支持点击直接编辑)
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("当前动作按键列表 (\(currentProfile.actionButtons.count))")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .textCase(.uppercase)
                                
                                Spacer()
                                
                                Button(action: openAddKeyModal) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle.fill")
                                        Text("添加快捷键")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    .foregroundStyle(.cyan)
                                }
                            }
                            
                            ForEach($currentProfile.actionButtons) { $btn in
                                buttonRowView(btn: $btn)
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
            .sheet(isPresented: $showingKeyModal) {
                keyEditModal
            }
        }
    }
    
    // MARK: - 按键单行卡片 (点击编辑)
    @ViewBuilder
    private func buttonRowView(btn: Binding<CustomActionButton>) -> some View {
        Button(action: {
            openEditKeyModal(for: btn.wrappedValue)
        }) {
            HStack(spacing: 14) {
                // 模拟按键发光徽章
                ZStack {
                    Circle()
                        .fill(btn.wrappedValue.color.opacity(0.2))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Circle().stroke(btn.wrappedValue.color.opacity(0.6), lineWidth: 1.5)
                        }
                    Text(btn.wrappedValue.label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(btn.wrappedValue.color)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("按键: \(btn.wrappedValue.label)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        if let sub = btn.wrappedValue.subLabel, !sub.isEmpty {
                            Text("(\(sub))")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Text("映射键位: \(btn.wrappedValue.code)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.9))
                        
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                        
                        Text("轻触编辑")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                
                Spacer()
                
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(6)
                
                if btn.wrappedValue.isDeletable {
                    Button(action: {
                        HapticManager.shared.buttonRelease()
                        currentProfile.actionButtons.removeAll { $0.id == btn.wrappedValue.id }
                        saveAndSync()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.pink.opacity(0.85))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
    
    // MARK: - 打开新增弹窗
    private func openAddKeyModal() {
        editingButton = nil
        selectedCategory = .letters
        let defaultKey = KeyRegistry.letters.first(where: { $0.label == "C" }) ?? KeyRegistry.letters[0]
        selectedKeyDefinition = defaultKey
        customKeyInput = ""
        buttonLabel = defaultKey.label
        buttonSubLabel = "交互"
        selectedColor = "cyan"
        showingKeyModal = true
    }
    
    // MARK: - 打开编辑弹窗
    private func openEditKeyModal(for btn: CustomActionButton) {
        editingButton = btn
        buttonLabel = btn.label
        buttonSubLabel = btn.subLabel ?? ""
        selectedColor = btn.colorName
        
        // 查找现有匹配按键
        if let match = KeyRegistry.allKeys.first(where: { $0.code == btn.code || $0.key == btn.key }) {
            selectedCategory = match.category
            selectedKeyDefinition = match
            customKeyInput = ""
        } else {
            selectedCategory = .custom
            customKeyInput = btn.key
        }
        showingKeyModal = true
    }
    
    // MARK: - 新增 / 编辑按键全能弹窗
    private var keyEditModal: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // 1. 实时晶体按键预览
                        VStack(spacing: 8) {
                            Text("按键视觉效果预览")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                            
                            ZStack {
                                Circle()
                                    .fill(colorFromName(selectedColor).opacity(0.2))
                                    .frame(width: 72, height: 72)
                                    .overlay {
                                        Circle().stroke(colorFromName(selectedColor).opacity(0.8), lineWidth: 2)
                                    }
                                    .shadow(color: colorFromName(selectedColor).opacity(0.5), radius: 12)
                                
                                VStack(spacing: 2) {
                                    Text(buttonLabel.isEmpty ? "?" : buttonLabel)
                                        .font(.system(size: 20, weight: .black, design: .rounded))
                                        .foregroundStyle(colorFromName(selectedColor))
                                    
                                    if !buttonSubLabel.isEmpty {
                                        Text(buttonSubLabel)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .padding(.top, 10)
                        
                        // 2. 键位大分类切换 Picker
                        Picker("键位类别", selection: $selectedCategory) {
                            ForEach(KeyCategory.allCases) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        
                        // 3. 分类下的键盘选择矩阵
                        VStack(alignment: .leading, spacing: 10) {
                            switch selectedCategory {
                            case .letters:
                                lettersKeyboardGrid
                            case .numbers:
                                numbersKeyboardGrid
                            case .controls:
                                controlsKeyList
                            case .function:
                                functionKeyGrid
                            case .custom:
                                customInputSection
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        // 4. 按键标签与副说明定制
                        VStack(alignment: .leading, spacing: 14) {
                            Text("外观与文字定制")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            VStack(spacing: 12) {
                                HStack {
                                    Text("按钮显示文字:")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                    TextField("如 C, Q, BAG, MAP", text: $buttonLabel)
                                        .textFieldStyle(.roundedBorder)
                                        .textInputAutocapitalization(.characters)
                                }
                                
                                HStack {
                                    Text("副标题说明 (可选):")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                    TextField("如 地图, 背包, 技能", text: $buttonSubLabel)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(14)
                            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
                        }
                        .padding(.horizontal, 16)
                        
                        // 5. 发光流体色彩定制
                        VStack(alignment: .leading, spacing: 12) {
                            Text("流光色彩主题")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            HStack(spacing: 14) {
                                ForEach(availableColors, id: \.self) { color in
                                    Circle()
                                        .fill(colorFromName(color))
                                        .frame(width: 36, height: 36)
                                        .overlay {
                                            if selectedColor == color {
                                                Circle()
                                                    .stroke(Color.white, lineWidth: 2.5)
                                                    .shadow(color: colorFromName(color), radius: 6)
                                            }
                                        }
                                        .onTapGesture {
                                            HapticManager.shared.buttonPress()
                                            selectedColor = color
                                        }
                                }
                            }
                            .padding(14)
                            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle(editingButton == nil ? "添加快捷按键" : "编辑按键属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showingKeyModal = false }
                        .foregroundStyle(.white.opacity(0.8))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editingButton == nil ? "添加" : "保存") {
                        saveButtonConfiguration()
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.cyan)
                }
            }
        }
        .presentationDetents([.large])
    }
    
    // MARK: - 字母 A-Z 全键盘网格 (7 列响应式排布)
    private var lettersKeyboardGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择字母按键 (26 键完整收录)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(KeyRegistry.letters) { def in
                    let isSelected = selectedCategory == .letters && selectedKeyDefinition.id == def.id
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        selectedKeyDefinition = def
                        buttonLabel = def.label
                        buttonSubLabel = ""
                    }) {
                        Text(def.label)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(isSelected ? Color.cyan : Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.15), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
        }
    }
    
    // MARK: - 数字 0-9 键盘网格
    private var numbersKeyboardGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择数字按键")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(KeyRegistry.numbers) { def in
                    let isSelected = selectedCategory == .numbers && selectedKeyDefinition.id == def.id
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        selectedKeyDefinition = def
                        buttonLabel = def.label
                        buttonSubLabel = "数字"
                    }) {
                        Text(def.label)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(isSelected ? Color.cyan : Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
        }
    }
    
    // MARK: - 控制与常用按键列表
    private var controlsKeyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择常用功能按键")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(KeyRegistry.controls) { def in
                    let isSelected = selectedCategory == .controls && selectedKeyDefinition.id == def.id
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        selectedKeyDefinition = def
                        buttonLabel = def.label
                        buttonSubLabel = def.description.components(separatedBy: " ").first ?? ""
                    }) {
                        HStack {
                            Text(def.label)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? .black : .cyan)
                            Spacer()
                            Text(def.description)
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? .black.opacity(0.8) : .white.opacity(0.6))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 42)
                        .background(isSelected ? Color.cyan : Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
        }
    }
    
    // MARK: - F1~F12 功能键网格
    private var functionKeyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择 F 功能键")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(KeyRegistry.functionKeys) { def in
                    let isSelected = selectedCategory == .function && selectedKeyDefinition.id == def.id
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        selectedKeyDefinition = def
                        buttonLabel = def.label
                        buttonSubLabel = ""
                    }) {
                        Text(def.label)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(isSelected ? Color.cyan : Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
        }
    }
    
    // MARK: - 自由自定义输入区域
    private var customInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自由输入任意键盘字母或按键")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            
            VStack(alignment: .leading, spacing: 10) {
                TextField("输入任意字母 (如 G, M, I, F7, Tab)", text: $customKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customKeyInput) { _, newValue in
                        let resolved = KeyRegistry.resolve(input: newValue)
                        if buttonLabel.isEmpty || buttonLabel.count <= 2 {
                            buttonLabel = resolved.label
                        }
                    }
                
                let resolved = KeyRegistry.resolve(input: customKeyInput)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.cyan)
                    Text("自动解析 Key: \"\(resolved.key)\", Code: \"\(resolved.code)\"")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 16, strokeOpacity: 0.15)
        }
    }
    
    // MARK: - 保存按键配置
    private func saveButtonConfiguration() {
        let key: String
        let code: String
        
        if selectedCategory == .custom {
            let res = KeyRegistry.resolve(input: customKeyInput)
            key = res.key
            code = res.code
        } else {
            key = selectedKeyDefinition.key
            code = selectedKeyDefinition.code
        }
        
        let finalLabel = buttonLabel.trimmingCharacters(in: .whitespaces).isEmpty ?
            (selectedCategory == .custom ? customKeyInput.uppercased() : selectedKeyDefinition.label) : buttonLabel
        let finalSubLabel = buttonSubLabel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : buttonSubLabel
        
        if var btn = editingButton {
            // 编辑已有按键
            btn.label = finalLabel
            btn.subLabel = finalSubLabel
            btn.key = key
            btn.code = code
            btn.colorName = selectedColor
            
            if let idx = currentProfile.actionButtons.firstIndex(where: { $0.id == btn.id }) {
                currentProfile.actionButtons[idx] = btn
            }
        } else {
            // 新增按键
            let newBtn = CustomActionButton(
                label: finalLabel,
                subLabel: finalSubLabel,
                key: key,
                code: code,
                colorName: selectedColor,
                relativeX: -140,
                relativeY: -90
            )
            currentProfile.actionButtons.append(newBtn)
        }
        
        HapticManager.shared.actionBurst()
        saveAndSync()
        showingKeyModal = false
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

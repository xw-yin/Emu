import SwiftUI
import WebKit

/// 次世代流体玻璃虚拟控制器浮层（支持全按键自定义与屏幕自由拖拽）
struct VirtualControllerOverlay: View {
    let gameTitle: String
    weak var webView: WKWebView?
    let onExitGame: () -> Void
    
    @State private var profile: GameKeyProfile = .actionRPG
    @State private var controllerOpacity: Double = 0.85
    @State private var showKeymapSheet: Bool = false
    @State private var isLayoutEditMode: Bool = false
    @State private var isFastForwardActive: Bool = false
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 顶部：悬浮动态岛控制条 (Dynamic Glass Island)
                VStack {
                    HStack(spacing: 12) {
                        // 退出按钮
                        Button(action: onExitGame) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        // 灵动胶囊工具栏
                        HStack(spacing: 14) {
                            // 自定义按键与映射配置入口
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                showKeymapSheet = true
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "gamecontroller.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("按键定制")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                            }
                            
                            // 2X 快进按键
                            Button(action: toggleFastForward) {
                                HStack(spacing: 4) {
                                    Image(systemName: isFastForwardActive ? "forward.fill" : "forward")
                                    Text(isFastForwardActive ? "2.0x" : "1.0x")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(isFastForwardActive ? Color.orange : Color.white.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                            }
                            
                            // 透明度调节
                            Menu {
                                Button("清晰 (100%)") { controllerOpacity = 1.0 }
                                Button("沉浸 (70%)") { controllerOpacity = 0.70 }
                                Button("幽灵 (40%)") { controllerOpacity = 0.40 }
                            } label: {
                                Image(systemName: "slider.horizontal.below.square.and.square.filled")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                        }
                        .padding(6)
                        .liquidGlass(cornerRadius: 30, strokeOpacity: 0.2)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    
                    if isLayoutEditMode {
                        // 编辑模式提示栏
                        HStack(spacing: 8) {
                            Image(systemName: "hand.draw.fill")
                                .foregroundStyle(.yellow)
                            Text("自由摆放模式：手指按住按键即可拖拽到任意位置")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            
                            Spacer()
                            
                            Button("完成保存") {
                                withAnimation {
                                    isLayoutEditMode = false
                                }
                                KeyMappingManager.shared.saveProfile(profile, for: gameTitle)
                                HapticManager.shared.actionBurst()
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.yellow)
                            .clipShape(Capsule())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(Color.yellow.opacity(0.4), lineWidth: 1) }
                        .padding(.top, 6)
                    }
                    
                    Spacer()
                }
                
                // 左下角：流体十字键
                VStack {
                    Spacer()
                    HStack {
                        GlassDpadView { direction, isDown in
                            guard let dir = direction else { return }
                            sendKeyEvent(key: dir.rawValue, code: dir.rawValue, isDown: isDown)
                        }
                        .padding(.leading, 28)
                        .padding(.bottom, 24)
                        
                        Spacer()
                    }
                }
                .opacity(controllerOpacity)
                
                // 右下角：动态自定义动作按键群 (根据坐标定位)
                ForEach($profile.actionButtons) { $btn in
                    renderDraggableButton(btn: $btn, screenSize: proxy.size)
                }
                .opacity(controllerOpacity)
            }
        }
        .onAppear {
            self.profile = KeyMappingManager.shared.loadProfile(for: gameTitle)
        }
        .sheet(isPresented: $showKeymapSheet) {
            KeyMappingEditorSheet(
                gameTitle: gameTitle,
                currentProfile: $profile,
                isLayoutEditModeActive: $isLayoutEditMode
            ) {
                // 刷新配置
                self.profile = KeyMappingManager.shared.loadProfile(for: gameTitle)
            }
        }
        .ignoresSafeArea(.keyboard)
    }
    
    // MARK: - 渲染动态可拖拽按键
    @ViewBuilder
    private func renderDraggableButton(btn: Binding<CustomActionButton>, screenSize: CGSize) -> some View {
        let posX = screenSize.width + btn.wrappedValue.relativeX
        let posY = screenSize.height + btn.wrappedValue.relativeY
        
        ZStack {
            GlassActionButton(
                label: btn.wrappedValue.label,
                subLabel: btn.wrappedValue.subLabel,
                primaryColor: btn.wrappedValue.color
            ) { isDown in
                if !isLayoutEditMode {
                    sendKeyEvent(key: btn.wrappedValue.key, code: btn.wrappedValue.code, isDown: isDown)
                }
            }
            
            if isLayoutEditMode {
                // 编辑模式高光外圈提示
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(Color.yellow.opacity(0.8))
                    .frame(width: 70, height: 70)
            }
        }
        .position(x: posX, y: posY)
        .gesture(
            isLayoutEditMode ?
            DragGesture()
                .onChanged { value in
                    let newRelX = value.location.x - screenSize.width
                    let newRelY = value.location.y - screenSize.height
                    btn.wrappedValue.relativeX = newRelX
                    btn.wrappedValue.relativeY = newRelY
                }
                .onEnded { _ in
                    HapticManager.shared.buttonRelease()
                    KeyMappingManager.shared.saveProfile(profile, for: gameTitle)
                }
            : nil
        )
    }
    
    // MARK: - 发送键盘事件到 WebKit
    private func sendKeyEvent(key: String, code: String, isDown: Bool) {
        let type = isDown ? "keydown" : "keyup"
        let js = """
        (function() {
            const evt = new KeyboardEvent('\(type)', {
                key: '\(key)',
                code: '\(code)',
                bubbles: true,
                cancelable: true
            });
            window.dispatchEvent(evt);
            document.dispatchEvent(evt);
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    // MARK: - 游戏倍速快进
    private func toggleFastForward() {
        isFastForwardActive.toggle()
        HapticManager.shared.actionBurst()
        let speed = isFastForwardActive ? 2.0 : 1.0
        
        let js = """
        (function() {
            const media = document.querySelectorAll('audio, video');
            media.forEach(m => m.playbackRate = \(speed));
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

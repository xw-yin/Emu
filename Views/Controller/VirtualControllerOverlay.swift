import SwiftUI
import WebKit

/// 次世代流体玻璃虚拟控制器浮层（支持全按键自定义与屏幕自由拖拽）
struct VirtualControllerOverlay: View {
    let gameTitle: String
    weak var webView: WKWebView?
    let onExitGame: () -> Void
    let onCloseGame: () -> Void
    @State private var confirmClose = false
    @State private var toolbarCollapsed = false
    @State private var dpadDragStart: CGPoint?
    @State private var actionDragStart: [UUID: CGPoint] = [:]
    @AppStorage("gameOrientation") private var gameOrientation = "auto"
    
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @State private var profile: GameKeyProfile = .actionRPG
    @State private var controllerOpacity: Double = 0.85
    @State private var showKeymapSheet: Bool = false
    @State private var isLayoutEditMode: Bool = false
    @State private var isFastForwardActive: Bool = false
    @AppStorage("isVirtualControllerHidden") private var isControllerHidden: Bool = false
    
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
                        
                        Button { releaseKeys(); confirmClose = true } label: {
                            Image(systemName: "power")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("关闭游戏")

                        Spacer(minLength: 8)
                        
                        // 灵动胶囊工具栏：宽度充足时完整并列，宽度受限/横屏一行展示不下时支持丝滑横向滑动
                        if !toolbarCollapsed {
                        ViewThatFits(in: .horizontal) {
                            toolbarButtons
                                .padding(6)
                                .liquidGlass(cornerRadius: 30, strokeOpacity: 0.2)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                toolbarButtons
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: 48)
                            .liquidGlass(cornerRadius: 30, strokeOpacity: 0.2)
                            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        }
                        }
                        Button { withAnimation { toolbarCollapsed.toggle() } } label: {
                            Image(systemName: toolbarCollapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(toolbarCollapsed ? "展开工具栏" : "折叠工具栏")
                    }
                    .padding(.horizontal, 20)
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
                
                GlassDpadView { direction, isDown in
                    guard !isLayoutEditMode, let dir = direction else { return }
                    sendKeyEvent(key: dir.rawValue, code: dir.rawValue, isDown: isDown)
                }
                .allowsHitTesting(!isLayoutEditMode)
                .overlay {
                    if isLayoutEditMode {
                        Circle().strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                            .contentShape(Circle())
                            .gesture(DragGesture().onChanged { value in
                                if dpadDragStart == nil {
                                    dpadDragStart = CGPoint(x: profile.dpadRelativeX, y: profile.dpadRelativeY)
                                }
                                guard let start = dpadDragStart else { return }
                                profile.dpadRelativeX = min(max(0, start.x + value.translation.width), max(0, proxy.size.width - 160))
                                profile.dpadRelativeY = min(max(0, start.y - value.translation.height), max(0, proxy.size.height - 230))
                            }.onEnded { _ in
                                dpadDragStart = nil
                                KeyMappingManager.shared.saveProfile(profile, for: gameTitle)
                            })
                    }
                }
                .frame(width: 160, height: 160)
                .position(x: min(max(80, profile.dpadRelativeX + 80), max(80, proxy.size.width - 80)),
                          y: min(max(150, proxy.size.height - profile.dpadRelativeY - 80), max(150, proxy.size.height - 80)))
                .opacity(isControllerHidden ? 0 : controllerOpacity)
                .allowsHitTesting(!isControllerHidden)

                // 右下角：动态自定义动作按键群 (根据坐标定位)
                ForEach($profile.actionButtons) { $btn in
                    renderDraggableButton(btn: $btn, screenSize: proxy.size)
                }
                .opacity(isControllerHidden ? 0 : controllerOpacity)
                .allowsHitTesting(!isControllerHidden)
            }
        }
        .alert("关闭游戏？", isPresented: $confirmClose) {
            Button("取消", role: .cancel) {}
            Button("关闭游戏", role: .destructive, action: onCloseGame)
        } message: {
            Text("关闭后将结束当前游戏，未保存的进度会丢失。返回游戏库则可以稍后继续。")
        }
        .onAppear {
            self.profile = KeyMappingManager.shared.loadProfile(for: gameTitle)
        }
        .onDisappear { releaseKeys() }
        .onChange(of: scenePhase) { phase in if phase != .active { releaseKeys() } }
        .onChange(of: isControllerHidden) { _ in releaseKeys() }
        .onChange(of: isLayoutEditMode) { _ in releaseKeys() }
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
        let margin: CGFloat = 38
        let posX = min(max(margin, screenSize.width + btn.wrappedValue.relativeX), max(margin, screenSize.width - margin))
        let posY = min(max(100, screenSize.height + btn.wrappedValue.relativeY), max(100, screenSize.height - margin))
        
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
                    let id = btn.wrappedValue.id
                    if actionDragStart[id] == nil { actionDragStart[id] = CGPoint(x: posX, y: posY) }
                    guard let start = actionDragStart[id] else { return }
                    btn.wrappedValue.relativeX = min(max(margin, start.x + value.translation.width), max(margin, screenSize.width - margin)) - screenSize.width
                    btn.wrappedValue.relativeY = min(max(100, start.y + value.translation.height), max(100, screenSize.height - margin)) - screenSize.height
                }
                .onEnded { _ in
                    actionDragStart[btn.wrappedValue.id] = nil
                    HapticManager.shared.buttonRelease()
                    KeyMappingManager.shared.saveProfile(profile, for: gameTitle)
                }
            : nil
        )
    }
    
    // MARK: - 发送键盘事件到 WebKit
    private func sendKeyEvent(key: String, code: String, isDown: Bool) {
        guard let webView = webView else { return }
        webView.callAsyncJavaScript(
            "if (!window.__emuKeyEvent) throw new Error('输入桥尚未就绪'); window.__emuKeyEvent(key, code, isDown); return true;",
            arguments: ["key": key, "code": code, "isDown": isDown],
            in: nil, in: .page
        ) { result in
            if case .failure(let error) = result {
                GameLogManager.shared.log("虚拟按键发送失败: \(code): \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func releaseKeys() {
        webView?.evaluateJavaScript("window.__emuReleaseKeys?.()", completionHandler: nil)
    }
    // MARK: - 顶部工具栏胶囊内容
    @ViewBuilder
    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            Button {
                releaseKeys()
                GameLogManager.shared.openConsole()
            } label: {
                Label("日志", systemImage: "terminal")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.cyan)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("查看和复制游戏日志")

            Button { keepScreenAwake.toggle() } label: {
                Label(keepScreenAwake ? "常亮开" : "常亮关", systemImage: keepScreenAwake ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(keepScreenAwake ? Color.yellow : Color.white)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            // 虚拟按键显隐切换
            Button(action: {
                HapticManager.shared.buttonPress()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isControllerHidden.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isControllerHidden ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(isControllerHidden ? "显示按键" : "隐藏按键")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(isControllerHidden ? Color.yellow : Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            
            // 自定义按键与映射配置入口
            Button(action: {
                HapticManager.shared.buttonPress()
                releaseKeys()
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
            
            Menu {
                Picker("屏幕方向", selection: $gameOrientation) {
                    Text("自动旋转").tag("auto")
                    Text("锁定竖屏").tag("portrait")
                    Text("锁定横屏").tag("landscape")
                }
            } label: {
                Image(systemName: gameOrientation == "auto" ? "rotate.right" : "lock.rotation")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .accessibilityLabel("屏幕方向锁定")

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
        .fixedSize(horizontal: true, vertical: false)
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

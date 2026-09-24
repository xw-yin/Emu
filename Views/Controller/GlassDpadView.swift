import SwiftUI

enum DpadDirection: String, CaseIterable {
    case up = "ArrowUp"
    case down = "ArrowDown"
    case left = "ArrowLeft"
    case right = "ArrowRight"
}

/// 次世代流体悬浮十字方向键 (Liquid Glass D-Pad)
struct GlassDpadView: View {
    let onDirectionChanged: (DpadDirection?, Bool) -> Void
    
    @State private var activeDirection: DpadDirection? = nil
    @State private var touchLocation: CGPoint = .zero
    @State private var isTouching: Bool = false
    
    private let dpadSize: CGFloat = 160
    
    var body: some View {
        ZStack {
            // 底部磨砂基座圆盘
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: dpadSize, height: dpadSize)
                .overlay {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.4), Color.white.opacity(0.05), Color.cyan.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                }
                .shadow(color: Color.black.opacity(0.3), radius: 14, x: 0, y: 6)
            
            // 四个方向的高光指示扇区
            directionIndicator(direction: .up, icon: "chevron.up", offset: CGSize(width: 0, height: -46))
            directionIndicator(direction: .down, icon: "chevron.down", offset: CGSize(width: 0, height: 46))
            directionIndicator(direction: .left, icon: "chevron.left", offset: CGSize(width: -46, height: 0))
            directionIndicator(direction: .right, icon: "chevron.right", offset: CGSize(width: 46, height: 0))
            
            // 中心触觉凹点 (Center Pivot)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.02)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: 38, height: 38)
                .overlay {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleTouch(location: value.location)
                }
                .onEnded { _ in
                    releaseTouch()
                }
        )
    }
    
    @ViewBuilder
    private func directionIndicator(direction: DpadDirection, icon: String, offset: CGSize) -> some View {
        let isActive = activeDirection == direction
        
        Image(systemName: icon)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(isActive ? Color.cyan : Color.white.opacity(0.7))
            .frame(width: 44, height: 44)
            .background {
                if isActive {
                    Circle()
                        .fill(Color.cyan.opacity(0.25))
                        .blur(radius: 6)
                }
            }
            .scaleEffect(isActive ? 1.25 : 1.0)
            .offset(offset)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.6), value: isActive)
    }
    
    private func handleTouch(location: CGPoint) {
        let center = CGPoint(x: dpadSize / 2, y: dpadSize / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // 死区判定：太靠近中心不触发
        guard distance > 14 else {
            if activeDirection != nil {
                releaseTouch()
            }
            return
        }
        
        // 计算角度判断方向
        let angle = atan2(dy, dx) * 180 / .pi
        let newDirection: DpadDirection
        
        if angle >= -135 && angle <= -45 {
            newDirection = .up
        } else if angle >= 45 && angle <= 135 {
            newDirection = .down
        } else if abs(angle) > 135 {
            newDirection = .left
        } else {
            newDirection = .right
        }
        
        if activeDirection != newDirection {
            // 先释放上一个方向
            if let prev = activeDirection {
                onDirectionChanged(prev, false)
            }
            activeDirection = newDirection
            HapticManager.shared.directionChange()
            onDirectionChanged(newDirection, true)
        }
    }
    
    private func releaseTouch() {
        if let current = activeDirection {
            onDirectionChanged(current, false)
            HapticManager.shared.buttonRelease()
        }
        activeDirection = nil
    }
}

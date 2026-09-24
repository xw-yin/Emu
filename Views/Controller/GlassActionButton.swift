import SwiftUI

/// 次世代流体玻璃动作按键 (Glass Action Button)
struct GlassActionButton: View {
    let label: String
    let subLabel: String?
    let primaryColor: Color
    let onStateChange: (Bool) -> Void
    
    @State private var isPressed: Bool = false
    
    var body: some View {
        ZStack {
            // 背景微光光晕（按下时爆发）
            Circle()
                .fill(primaryColor.opacity(isPressed ? 0.45 : 0.08))
                .frame(width: 66, height: 66)
                .blur(radius: isPressed ? 14 : 4)
            
            // 玻璃按键本体
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 58, height: 58)
                .overlay {
                    // 内发光镜面环
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isPressed ? 0.9 : 0.4),
                                    primaryColor.opacity(isPressed ? 0.8 : 0.2),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isPressed ? 2.0 : 1.2
                        )
                }
                .overlay {
                    VStack(spacing: 1) {
                        Text(label)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(isPressed ? primaryColor : Color.white.opacity(0.92))
                        
                        if let sub = subLabel {
                            Text(sub)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                }
                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                .scaleEffect(isPressed ? 0.90 : 1.0)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        HapticManager.shared.buttonPress()
                        onStateChange(true)
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    HapticManager.shared.buttonRelease()
                    onStateChange(false)
                }
        )
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.58), value: isPressed)
    }
}

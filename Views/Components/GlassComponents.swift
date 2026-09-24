import SwiftUI

// MARK: - 极具未来感的超薄流体磨砂玻璃 Modifier
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var strokeOpacity: Double = 0.28
    var glowColor: Color = Color.cyan.opacity(0.15)
    
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        // 镜面边缘光感 (Specular Rim Light)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(strokeOpacity * 1.5),
                                        Color.white.opacity(0.05),
                                        glowColor,
                                        Color.white.opacity(strokeOpacity)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                    }
                    .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 8)
            }
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24, strokeOpacity: Double = 0.28, glowColor: Color = Color.cyan.opacity(0.15)) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius, strokeOpacity: strokeOpacity, glowColor: glowColor))
    }
}

// MARK: - 空间流体背景 (Ambient Mesh Glow)
struct AmbientMeshBackground: View {
    @State private var animateGlow = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 荧光蓝色光源
            Circle()
                .fill(Color(red: 0.1, green: 0.35, blue: 0.85).opacity(0.35))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: animateGlow ? -100 : 120, y: animateGlow ? -150 : 80)
            
            // 荧光紫罗兰光源
            Circle()
                .fill(Color(red: 0.55, green: 0.15, blue: 0.75).opacity(0.3))
                .frame(width: 420, height: 420)
                .blur(radius: 100)
                .offset(x: animateGlow ? 120 : -90, y: animateGlow ? 140 : -100)
            
            // 微妙青绿流光
            Circle()
                .fill(Color(red: 0.05, green: 0.65, blue: 0.6).opacity(0.2))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: animateGlow ? 60 : -60, y: animateGlow ? -60 : 160)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 8.0).repeatForever(autoreverses: true)) {
                animateGlow.toggle()
            }
        }
        .ignoresSafeArea()
    }
}

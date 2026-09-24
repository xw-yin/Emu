import UIKit

/// 次世代震动反馈管理器：模拟真实微动开关的段落感与冲击感
final class HapticManager {
    static let shared = HapticManager()
    
    private let lightImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    
    private init() {
        prepare()
    }
    
    func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
        selectionFeedback.prepare()
    }
    
    /// 按键按下：清脆微动段落反馈
    func buttonPress() {
        lightImpact.impactOccurred(intensity: 0.85)
    }
    
    /// 按键抬起：轻微释放反馈
    func buttonRelease() {
        lightImpact.impactOccurred(intensity: 0.4)
    }
    
    /// 方向键滑动变向
    func directionChange() {
        selectionFeedback.selectionChanged()
    }
    
    /// 重按键（如冲刺/爆发）
    func actionBurst() {
        heavyImpact.impactOccurred(intensity: 1.0)
    }
}

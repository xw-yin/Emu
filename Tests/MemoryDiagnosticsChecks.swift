import Foundation

@main
struct MemoryDiagnosticsChecks {
    static func main() async {
        // 1. 测试有权限时的状态与日志格式
        let grantedReport = MemoryDiagnostics(
            entitlementChecker: { true },
            availableMemoryProvider: { 4 * 1024 * 1024 * 1024 }, // 4GB
            footprintProvider: { 150 * 1024 * 1024 },          // 150MB
            totalMemoryProvider: { 8 * 1024 * 1024 * 1024 }     // 8GB
        ).generateReport()
        
        precondition(grantedReport.hasIncreasedMemoryEntitlement == true, "Must recognize active entitlement")
        precondition(grantedReport.availableMB == 4096.0, "Available MB calculation must match")
        precondition(grantedReport.footprintMB == 150.0, "Footprint MB calculation must match")
        precondition(grantedReport.totalDeviceMB == 8192.0, "Total device MB calculation must match")
        precondition(grantedReport.statusDescription.contains("YES"), "Status description must state YES")
        precondition(grantedReport.formattedLogString.contains("🚀 已激活"), "Log string must include activated icon and text")
        
        // 2. 测试未激活时的状态与日志格式
        let deniedReport = MemoryDiagnostics(
            entitlementChecker: { false },
            availableMemoryProvider: { 1400 * 1024 * 1024 },
            footprintProvider: { 80 * 1024 * 1024 },
            totalMemoryProvider: { 6 * 1024 * 1024 * 1024 }
        ).generateReport()
        
        precondition(deniedReport.hasIncreasedMemoryEntitlement == false, "Must recognize inactive entitlement")
        precondition(deniedReport.statusDescription.contains("NO"), "Status description must state NO")
        precondition(deniedReport.formattedLogString.contains("ℹ️ 未激活"), "Log string must include inactive icon and text")
        
        // 3. 测试默认系统提供者（确保无崩溃，无空指针异常）
        let liveReport = MemoryDiagnostics.shared.generateReport()
        precondition(liveReport.totalDeviceMemoryBytes > 0, "Device total physical memory must be greater than 0")
        
        print("Memory diagnostics and entitlement detection checks passed")
    }
}

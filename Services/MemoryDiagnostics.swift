import Foundation
import Darwin
import Security

/// 负责检测系统内核大内存特权（Increased Memory Limit）是否生效，以及监控进程实际可用内存与物理足迹。
final class MemoryDiagnostics {
    static let shared = MemoryDiagnostics()
    
    struct Report: Equatable {
        /// 是否被系统授予了 com.apple.developer.kernel.increased-memory-limit 内核特权
        let hasIncreasedMemoryEntitlement: Bool
        /// 当前进程在触碰 Jetsam 强杀线前，系统允许该进程继续分配的字节数（os_proc_available_memory）
        let availableMemoryBytes: UInt64
        /// 当前进程实际常驻物理内存足迹（phys_footprint）
        let physicalFootprintBytes: UInt64
        /// 设备总物理内存
        let totalDeviceMemoryBytes: UInt64
        
        var availableMB: Double {
            Double(availableMemoryBytes) / (1024 * 1024)
        }
        
        var footprintMB: Double {
            Double(physicalFootprintBytes) / (1024 * 1024)
        }
        
        var totalDeviceMB: Double {
            Double(totalDeviceMemoryBytes) / (1024 * 1024)
        }
        
        var statusDescription: String {
            if hasIncreasedMemoryEntitlement {
                return "已激活大内存权限 (Increased Memory Limit: YES)"
            } else {
                return "未检测到大内存权限 (Increased Memory Limit: NO)"
            }
        }
        
        var formattedLogString: String {
            let limitTag = hasIncreasedMemoryEntitlement ? "🚀 已激活" : "ℹ️ 未激活"
            let availStr = availableMemoryBytes > 0 ? String(format: "%.1f MB", availableMB) : "未知"
            let footStr = String(format: "%.1f MB", footprintMB)
            let totalStr = String(format: "%.0f MB", totalDeviceMB)
            return "[内存诊断] \(limitTag)大内存特权 | 系统可用配额: \(availStr) | 物理内存占用: \(footStr) | 设备总物理内存: \(totalStr)"
        }
    }
    
    private let entitlementChecker: () -> Bool
    private let availableMemoryProvider: () -> UInt64
    private let footprintProvider: () -> UInt64
    private let totalMemoryProvider: () -> UInt64
    
    init(
        entitlementChecker: @escaping () -> Bool = MemoryDiagnostics.defaultEntitlementChecker,
        availableMemoryProvider: @escaping () -> UInt64 = MemoryDiagnostics.defaultAvailableMemoryProvider,
        footprintProvider: @escaping () -> UInt64 = MemoryDiagnostics.defaultFootprintProvider,
        totalMemoryProvider: @escaping () -> UInt64 = { ProcessInfo.processInfo.physicalMemory }
    ) {
        self.entitlementChecker = entitlementChecker
        self.availableMemoryProvider = availableMemoryProvider
        self.footprintProvider = footprintProvider
        self.totalMemoryProvider = totalMemoryProvider
    }
    
    func generateReport() -> Report {
        Report(
            hasIncreasedMemoryEntitlement: entitlementChecker(),
            availableMemoryBytes: availableMemoryProvider(),
            physicalFootprintBytes: footprintProvider(),
            totalDeviceMemoryBytes: totalMemoryProvider()
        )
    }
    
    @discardableResult
    func logDiagnostics() -> Report {
        let report = generateReport()
        let level: GameLogManager.LogItem.Level = report.hasIncreasedMemoryEntitlement ? .success : .info
        GameLogManager.shared.log(report.formattedLogString, level: level)
        return report
    }
    
    // MARK: - 底层检测实现
    
    /// 通过 SecTask 读取当前进程代码签名中被内核承认的 Entitlement
    static func defaultEntitlementChecker() -> Bool {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let createSym = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(handle, "SecTaskCopyValueForEntitlement") else {
            return false
        }
        typealias SecTaskCreateFromSelfFunc = @convention(c) (CFAllocator?) -> AnyObject?
        typealias SecTaskCopyValueForEntitlementFunc = @convention(c) (AnyObject, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?
        
        let create = unsafeBitCast(createSym, to: SecTaskCreateFromSelfFunc.self)
        let copy = unsafeBitCast(copySym, to: SecTaskCopyValueForEntitlementFunc.self)
        
        guard let task = create(nil) else { return false }
        var error: Unmanaged<CFError>?
        if let unmanaged = copy(task, "com.apple.developer.kernel.increased-memory-limit" as CFString, &error) {
            let value = unmanaged.takeRetainedValue()
            return (value as? NSNumber)?.boolValue ?? false
        }
        return false
    }
    
    /// 读取系统在被 Jetsam 强杀前允许分配的最大剩余内存
    static func defaultAvailableMemoryProvider() -> UInt64 {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return UInt64(os_proc_available_memory())
        #else
        return 0
        #endif
    }
    
    /// 读取进程占用的实际物理内存大小
    static func defaultFootprintProvider() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

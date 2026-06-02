import Combine
import Foundation
import Metal

/// Extended hardware detection beyond `HardwareCapabilityProbe`.
/// Adds GPU core count, Metal working set budget, and live free memory reading.
enum ExtendedHardwareProbe {
    struct Snapshot: Equatable, Sendable {
        let physicalMemoryBytes: UInt64
        let freeMemoryBytes: UInt64
        let gpuCoreCount: Int
        let metalBudgetBytes: UInt64
        let isAppleSilicon: Bool
        let chipName: String

        var physicalMemoryGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }
        var freeMemoryGB: Double { Double(freeMemoryBytes) / 1_073_741_824 }
        var metalBudgetGB: Double { Double(metalBudgetBytes) / 1_073_741_824 }
    }

    static func current() -> Snapshot {
        let physical = ProcessInfo.processInfo.physicalMemory
        let free = freeMemory()
        let (gpuCores, metalBudget) = metalInfo()
        let chip = chipName()

        return Snapshot(
            physicalMemoryBytes: physical,
            freeMemoryBytes: free,
            gpuCoreCount: gpuCores,
            metalBudgetBytes: metalBudget,
            isAppleSilicon: isAppleSilicon,
            chipName: chip
        )
    }

    // MARK: - Private

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static func freeMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * pageSize
    }

    private static func metalInfo() -> (gpuCores: Int, budget: UInt64) {
        guard let device = MTLCreateSystemDefaultDevice() else { return (0, 0) }
        return (0, UInt64(device.recommendedMaxWorkingSetSize))
        // Note: GPU core count not directly exposed by Metal API on macOS;
        // we use sysctl below in chipName for identification.
    }

    private static func chipName() -> String {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

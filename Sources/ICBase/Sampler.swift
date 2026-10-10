import Darwin
import Foundation
import ICCore
import IOKit
import IOKit.ps

public enum Sysctl {
    public static func int(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        // Some values are 32-bit.
        return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// Reads whole-system memory, power and thermal state.
public enum SystemSampler {
    public static func sample(now: Double = Date().timeIntervalSince1970, diskPath: String = NSHomeDirectory()) -> SystemSample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        let page = Double(vm_kernel_page_size) / 1_048_576
        let power = powerState()
        let disk =
            (try? URL(fileURLWithPath: diskPath).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { Double($0) / 1e9 } ?? 0
        let thermal: Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }
        var sample = SystemSample(
            time: now,
            pressure: PressureLevel(sysctlValue: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1),
            availablePercent: Sysctl.int("kern.memorystatus_level") ?? 100,
            physicalMB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
            freeMB: Double(stats.free_count) * page,
            compressedMB: Double(stats.compressor_page_count) * page,
            swapUsedMB: Double(swap.xsu_used) / 1_048_576,
            swapOuts: stats.swapouts, swapIns: stats.swapins,
            thermal: thermal, onBattery: power.onBattery, batteryPercent: power.percent,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, freeDiskGB: disk)
        sample.pageIns = stats.pageins
        return sample
    }

    /// Memory other work could use without paging: free + inactive + speculative + purgeable, MB.
    public static func availableMB() -> Double {
        var st = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        let pages = UInt64(st.free_count) + UInt64(st.inactive_count) + UInt64(st.speculative_count) + UInt64(st.purgeable_count)
        return Double(pages) * Double(vm_kernel_page_size) / 1_048_576
    }

    /// Cheap pressure-only read for the fast poll.
    public static func pressure() -> PressureLevel {
        PressureLevel(sysctlValue: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    public static func powerState() -> (onBattery: Bool, percent: Int?, hasBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (false, nil, false)
        }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            let cur = d[kIOPSCurrentCapacityKey] as? Int
            let max = d[kIOPSMaxCapacityKey] as? Int
            let pct = (cur != nil && (max ?? 0) > 0) ? cur! * 100 / max! : nil
            return (state == kIOPSBatteryPowerValue, pct, true)
        }
        return (false, nil, false)
    }

    public static func hardware() -> Hardware {
        var arch = "arm64"
        #if arch(x86_64)
            arch = Sysctl.int("sysctl.proc_translated") == 1 ? "arm64 (Rosetta)" : "x86_64"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Hardware(
            model: Sysctl.string("hw.model") ?? "unknown", arch: arch,
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            rotationalDisk: bootDiskIsRotational(), hasBattery: powerState().hasBattery)
    }

    /// True if any block storage device reports a rotational medium. Macs with an SSD
    /// report "Solid State"; Fusion Drives report both, and count as rotational.
    public static func bootDiskIsRotational() -> Bool {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iter) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iter) }
        var rotational = false
        while case let s = IOIteratorNext(iter), s != 0 {
            if let chars = IORegistryEntryCreateCFProperty(s, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                (chars["Medium Type"] as? String) == "Rotational"
            {
                rotational = true
            }
            IOObjectRelease(s)
        }
        return rotational
    }
}

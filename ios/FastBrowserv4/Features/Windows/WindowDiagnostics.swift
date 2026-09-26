import Darwin
import Foundation

/// Process-wide memory sample. iOS does not expose per-`WKWebView` RSS,
/// so the overlay shows this footprint plus a per-window estimate.
nonisolated struct ProcessMemorySample: Sendable, Equatable {
    let usedBytes: UInt64
    let availableBytes: UInt64
    let sampledAt: Date

    static let zero = ProcessMemorySample(usedBytes: 0, availableBytes: 0, sampledAt: .distantPast)
}

/// Page-weight signals collected from the live DOM.
nonisolated struct WindowPageMetrics: Sendable, Equatable {
    var htmlBytes: Int
    var nodeCount: Int
    var imageCount: Int
    var iframeCount: Int
    var scriptCount: Int

    static let empty = WindowPageMetrics(
        htmlBytes: 0,
        nodeCount: 0,
        imageCount: 0,
        iframeCount: 0,
        scriptCount: 0
    )

    /// Relative weight used to split the process footprint across windows.
    var weight: Int {
        max(
            0,
            htmlBytes
                + nodeCount * 256
                + imageCount * 50_000
                + iframeCount * 20_000
                + scriptCount * 8_000
        )
    }
}

/// Per-window memory estimate shown in the diagnostic overlay.
nonisolated struct WindowMemorySnapshot: Sendable, Equatable {
    var attributedBytes: UInt64
    var storeRecordCount: Int
    var cookieCount: Int
    var page: WindowPageMetrics
    var sampledAt: Date
    var processUsedBytes: UInt64
    var processAvailableBytes: UInt64

    static let empty = WindowMemorySnapshot(
        attributedBytes: 0,
        storeRecordCount: 0,
        cookieCount: 0,
        page: .empty,
        sampledAt: .distantPast,
        processUsedBytes: 0,
        processAvailableBytes: 0
    )

    var storeWeight: Int {
        cookieCount * 512 + storeRecordCount * 8_000
    }

    var attributionWeight: Int {
        max(1, page.weight + storeWeight)
    }
}

nonisolated enum LeakCheckVerdict: String, Sendable, Equatable {
    case idle
    case running
    case pass
    case warn
    case fail

    var rank: Int {
        switch self {
        case .idle: return 0
        case .running: return 1
        case .pass: return 2
        case .warn: return 3
        case .fail: return 4
        }
    }
}

nonisolated struct LeakCheckItem: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let verdict: LeakCheckVerdict
    let detail: String
}

nonisolated struct WindowLeakCheckReport: Sendable, Equatable {
    var verdict: LeakCheckVerdict
    var items: [LeakCheckItem]
    var checkedAt: Date?

    static let idle = WindowLeakCheckReport(verdict: .idle, items: [], checkedAt: nil)
}

nonisolated enum ProcessMemorySampler {
    static func sample() -> ProcessMemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        let used = kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        let availableRaw = os_proc_available_memory()
        let available = availableRaw > 0 ? UInt64(availableRaw) : 0
        return ProcessMemorySample(usedBytes: used, availableBytes: available, sampledAt: .now)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let gigabyte: Double = 1_073_741_824
        let megabyte: Double = 1_048_576
        let kilobyte: Double = 1_024
        let value = Double(bytes)
        if value >= gigabyte {
            return String(format: "%.1f GB", value / gigabyte)
        }
        if value >= megabyte {
            let formatted = value >= 10 * megabyte
                ? String(format: "%.0f MB", value / megabyte)
                : String(format: "%.1f MB", value / megabyte)
            return formatted
        }
        if value >= kilobyte {
            return String(format: "%.0f KB", value / kilobyte)
        }
        return "\(bytes) B"
    }

    static func compactBytes(_ bytes: UInt64) -> String {
        let megabyte: Double = 1_048_576
        let value = Double(bytes)
        if value >= megabyte {
            return value >= 10 * megabyte
                ? String(format: "%.0fM", value / megabyte)
                : String(format: "%.1fM", value / megabyte)
        }
        if value >= 1_024 {
            return String(format: "%.0fK", value / 1_024)
        }
        return "\(bytes)B"
    }
}

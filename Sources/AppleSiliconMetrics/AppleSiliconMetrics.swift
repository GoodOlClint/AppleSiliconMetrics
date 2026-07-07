import CIOReport
import CoreFoundation
import Foundation
import IOKit

/// A point-in-time (delta) sample of Apple Silicon SoC metrics, read
/// **sudoless** via the private `IOReport` framework.
///
/// Every field is optional: a metric is `nil` when it could not be read on
/// this OS/chip. The underlying interfaces are private and version-fragile by
/// nature, so consumers MUST degrade gracefully (e.g. omit the field from a
/// health endpoint rather than failing).
public struct SoCSample: Sendable, Equatable {
    /// Effective GPU frequency in MHz over the sample window — the
    /// residency-weighted average of the active DVFS performance states.
    /// This matches `powermetrics`'s "GPU HW active frequency" line.
    public var gpuFrequencyMHz: Double?

    /// Fraction of the window the GPU spent active (not in its idle/P0
    /// state), `0...1`.
    public var gpuActiveResidency: Double?

    // TODO (PROMPT.md): cpuClusterFrequenciesMHz, anePowerWatts,
    // packagePowerWatts, per-component temperatures, …

    public init(
        gpuFrequencyMHz: Double? = nil,
        gpuActiveResidency: Double? = nil
    ) {
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.gpuActiveResidency = gpuActiveResidency
    }
}

/// Samples Apple Silicon SoC metrics via `IOReport` (no root required).
///
/// `init` opens an IOReport subscription for the GPU performance-state channels
/// and loads the per-state DVFS frequency table from the IORegistry.
/// `sample(interval:)` takes two counter snapshots `interval` apart, deltas
/// them, and reports the residency-weighted effective GPU frequency and the
/// active-residency fraction over the window.
///
/// Construction throws ``InitError/ioReportUnavailable`` only when the IOReport
/// subscription itself cannot be opened (e.g. non–Apple-Silicon, or the private
/// framework is missing). A missing frequency table is *not* fatal:
/// ``gpuActiveResidency`` is still reported and ``gpuFrequencyMHz`` degrades to
/// `nil`. `sample(interval:)` never throws or traps.
public final class SoCSampler: @unchecked Sendable {
    public enum InitError: Error {
        /// IOReport (or the expected GPU channels) is unavailable on this host.
        case ioReportUnavailable
    }

    /// IOReport residency states that represent *inactive* GPU time. Everything
    /// at or after the first non-inactive state is "active" (a real P-state).
    private static let inactiveStateNames: Set<String> = ["IDLE", "DOWN", "OFF"]

    /// Set `ASMETRICS_DEBUG=1` to dump discovered channels and the loaded
    /// frequency table to stderr — useful when porting to a new SoC/OS.
    private static let debug = ProcessInfo.processInfo.environment["ASMETRICS_DEBUG"] != nil

    private let subscription: IOReportSubscriptionRef
    private let subscribedChannels: CFMutableDictionary

    /// GPU DVFS frequencies in MHz, one per *active* performance state, in
    /// P-state index order (NOT necessarily ascending — M4 Max interleaves,
    /// e.g. …1312, 1242, 1380…). Empty when the table could not be read.
    private let gpuFreqsMHz: [Double]

    public init() throws {
        // Subscribe to the whole "GPU Stats" group; we filter to the "GPUPH"
        // performance-state channel at sample time. Passing nil subgroup keeps
        // us robust to subgroup-name drift across OS versions.
        guard let channels = IOReportCopyChannelsInGroup(
            "GPU Stats" as CFString, nil, 0, 0, 0) else {
            throw InitError.ioReportUnavailable
        }

        var subbed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(
            nil, channels, &subbed, 0, nil),
            let subscribedChannels = subbed?.takeRetainedValue()
        else {
            throw InitError.ioReportUnavailable
        }
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels

        // The frequency table is best-effort: residency alone still gives us
        // active-residency, just not an effective-MHz figure.
        self.gpuFreqsMHz = Self.loadGPUFrequencyTableMHz() ?? []

        if Self.debug {
            FileHandle.standardError.write(Data(
                "asmetrics: gpu DVFS table (MHz, active states): \(gpuFreqsMHz)\n".utf8))
        }
    }

    // No deinit: the IOReport subscription is held for the sampler's lifetime
    // and released by the OS on teardown. Swift forbids calling CFRelease, and
    // the handle is an opaque (non-ARC) pointer, so there is nothing to free
    // here — a single subscription per long-lived sampler does not leak in any
    // meaningful sense.

    /// Take a delta sample over `interval` seconds (two IOReport snapshots with
    /// the interval between them). Returns an all-`nil` ``SoCSample`` rather
    /// than throwing if any step fails.
    public func sample(interval: TimeInterval = 0.1) -> SoCSample {
        guard let first = IOReportCreateSamples(
            subscription, subscribedChannels, nil) else {
            return SoCSample()
        }
        Thread.sleep(forTimeInterval: max(0, interval))
        guard let second = IOReportCreateSamples(
            subscription, subscribedChannels, nil) else {
            return SoCSample()
        }
        guard let delta = IOReportCreateSamplesDelta(first, second, nil) else {
            return SoCSample()
        }

        let top = delta as NSDictionary
        guard let entries = top["IOReportChannels"] as? NSArray else {
            return SoCSample()
        }

        for case let entry as NSDictionary in entries {
            let channel = unsafeBitCast(entry, to: CFDictionary.self)

            let group = IOReportChannelGetGroup(channel) as String?
            let name = IOReportChannelGetChannelName(channel) as String?

            if Self.debug {
                let sub = IOReportChannelGetSubGroup(channel) as String? ?? "-"
                let count = IOReportStateGetCount(channel)
                let line = "asmetrics: channel group=\(group ?? "-") "
                    + "subgroup=\(sub) name=\(name ?? "-") states=\(count)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }

            // The GPU performance-state residency channel.
            guard group == "GPU Stats", name == "GPUPH" else { continue }
            if let result = residencyWeightedGPU(channel) {
                return SoCSample(
                    gpuFrequencyMHz: result.frequencyMHz,
                    gpuActiveResidency: result.activeResidency)
            }
        }

        return SoCSample()
    }

    // MARK: - GPU residency math

    /// Compute the residency-weighted effective frequency (MHz) and the
    /// active-residency fraction from a GPU performance-state channel.
    ///
    /// The state table is `[<inactive states…>, P1, P2, …, Pn]`. The active
    /// states align 1:1 with ``gpuFreqsMHz`` once the leading inactive states
    /// are skipped. Effective MHz = Σ(residencyᵢ · freqᵢ) / Σ(active residency);
    /// active residency = Σ(active residency) / Σ(all residency).
    private func residencyWeightedGPU(
        _ channel: CFDictionary
    ) -> (frequencyMHz: Double?, activeResidency: Double?)? {
        let count = Int(IOReportStateGetCount(channel))
        guard count > 0 else { return nil }

        var names = [String]()
        var residencies = [Double]()
        names.reserveCapacity(count)
        residencies.reserveCapacity(count)
        for i in 0..<count {
            let name = (IOReportStateGetNameForIndex(channel, Int32(i)) as String?) ?? ""
            names.append(name)
            residencies.append(Double(IOReportStateGetResidency(channel, Int32(i))))
        }

        guard let offset = names.firstIndex(where: {
            !Self.inactiveStateNames.contains($0)
        }) else {
            // Entirely idle window with no recognised active states.
            return (gpuFreqsMHz.first, 0)
        }

        let total = residencies.reduce(0, +)
        let activeSum = residencies[offset...].reduce(0, +)
        let activeResidency = total > 0 ? activeSum / total : 0

        var frequencyMHz: Double?
        if !gpuFreqsMHz.isEmpty {
            if activeSum > 0 {
                var weighted = 0.0
                let n = min(gpuFreqsMHz.count, residencies.count - offset)
                for i in 0..<n {
                    weighted += (residencies[i + offset] / activeSum) * gpuFreqsMHz[i]
                }
                frequencyMHz = weighted
            } else {
                // Idle: report the lowest active P-state frequency.
                frequencyMHz = gpuFreqsMHz.first
            }
        }

        return (frequencyMHz, activeResidency)
    }

    // MARK: - DVFS frequency table (IORegistry "voltage-states")

    /// Read the GPU DVFS performance-state frequencies (MHz, ascending) from
    /// the `pmgr` IORegistry node's `voltage-states9` blob. The first entry is
    /// dropped: it is the lowest-floor state that the residency table never
    /// reports as an active P-state.
    private static func loadGPUFrequencyTableMHz() -> [Double]? {
        // The GPU DVFS table lives in the `pmgr` IORegistry node under key
        // "voltage-states9" (the non-sram variant). Rather than locate `pmgr`
        // by name — its node name is often empty and most matched entries are
        // unreadable — search the registry recursively for the key itself.
        for key in ["voltage-states9", "voltage-states9-sram"] {
            guard let data = searchRegistryData(key: key),
                let freqs = parseVoltageStates(data) else { continue }
            // Convert Hz → MHz and drop the index-0 floor state (a 0 MHz
            // placeholder that the residency table never reports as active).
            let mhz = freqs.map { $0 / 1_000_000.0 }
            let active = Array(mhz.dropFirst())
            if active.contains(where: { $0 > 0 }) {
                if debug {
                    FileHandle.standardError.write(Data(
                        "asmetrics: loaded GPU freqs from \(key): \(mhz)\n".utf8))
                }
                return active
            }
        }
        return nil
    }

    /// Recursively search the IORegistry (from the root, IOService plane) for
    /// the first node carrying `key`, returning its value as `Data`.
    private static func searchRegistryData(key: String) -> Data? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        let value = IORegistryEntrySearchCFProperty(
            root, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively))
        return value as? Data
    }

    /// Parse a `voltage-states` blob: an array of 8-byte `(freq, voltage)`
    /// records, each a little-endian `UInt32` pair. Returns the raw frequencies
    /// (in Hz for the GPU table).
    private static func parseVoltageStates(_ data: Data) -> [Double]? {
        let recordSize = 8
        let count = data.count / recordSize
        guard count > 0 else { return nil }

        return data.withUnsafeBytes { raw -> [Double] in
            var freqs = [Double]()
            freqs.reserveCapacity(count)
            for i in 0..<count {
                // arm64 is little-endian, matching the on-disk encoding.
                let freq = raw.loadUnaligned(
                    fromByteOffset: i * recordSize, as: UInt32.self)
                freqs.append(Double(freq))
            }
            return freqs
        }
    }
}

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

    /// Effective per-CPU-cluster frequency in MHz over the window, keyed by the
    /// cluster's IOReport channel name (e.g. `"ECPU"`, `"PCPU"`, or on
    /// multi-die parts `"ECPU0"`, `"PCPU1"`, …). Residency-weighted over each
    /// cluster's active DVFS states, matching `powermetrics`'s per-cluster
    /// "HW active frequency". A cluster with no active residency in the window
    /// reports its lowest DVFS frequency (its parked clock), where
    /// `powermetrics` prints 0. `nil` when the CPU perf-state channels or DVFS
    /// tables could not be read.
    public var cpuClusterFrequenciesMHz: [String: Double]?

    /// Apple Neural Engine power in watts, averaged over the window (from the
    /// "Energy Model" ANE energy counter). `nil` when unavailable.
    public var anePowerWatts: Double?

    /// Whole-package power in watts, averaged over the window — the sum of the
    /// CPU, GPU, and ANE "Energy Model" energy counters (comparable to
    /// `powermetrics`'s "Combined Power (CPU + GPU + ANE)"). `nil` when no
    /// energy channels could be read.
    public var packagePowerWatts: Double?

    /// GPU die temperature in °C — the mean of the SMC `Tg…` sensors (the same
    /// per-cluster GPU sensors `mactop` averages). `nil` when the SMC sensors
    /// are unreadable (or absent on this chip). Read from SMC rather than
    /// IOReport: M5 exposes no IOReport GPU-temperature channels, and M4's read
    /// back 0 through the documented accessor.
    public var gpuTemperatureC: Double?

    /// CPU die temperature in °C — the mean of the SMC `Tp…`/`Te…` (P-/E-core)
    /// sensors. `nil` when unreadable/absent.
    public var cpuTemperatureC: Double?

    public init(
        gpuFrequencyMHz: Double? = nil,
        gpuActiveResidency: Double? = nil,
        cpuClusterFrequenciesMHz: [String: Double]? = nil,
        anePowerWatts: Double? = nil,
        packagePowerWatts: Double? = nil,
        gpuTemperatureC: Double? = nil,
        cpuTemperatureC: Double? = nil
    ) {
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.gpuActiveResidency = gpuActiveResidency
        self.cpuClusterFrequenciesMHz = cpuClusterFrequenciesMHz
        self.anePowerWatts = anePowerWatts
        self.packagePowerWatts = packagePowerWatts
        self.gpuTemperatureC = gpuTemperatureC
        self.cpuTemperatureC = cpuTemperatureC
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

    /// Serializes `sample()`. IOReport's thread-safety is undocumented, and a
    /// single subscription must not be sampled concurrently, so we take two
    /// snapshots under a lock. ponytail: one global lock — a sampler is a
    /// cheap, per-consumer object; contention here is not a real workload.
    private let sampleLock = NSLock()

    /// GPU DVFS frequencies in MHz, one per *active* performance state, in
    /// P-state index order (NOT necessarily ascending — M4 Max interleaves,
    /// e.g. …1312, 1242, 1380…). Empty when the table could not be read.
    private let gpuFreqsMHz: [Double]

    /// Per-CPU-cluster DVFS frequency tables in MHz, keyed by the number of
    /// *active* performance states the cluster's IOReport residency channel
    /// reports. A cluster is matched to its table at sample time by that count
    /// (see ``activeStateCount``). ponytail: count-keyed, so two clusters with
    /// the same active-state count but different tables collide — harmless when
    /// their frequencies match (identical P-clusters), which is the only case
    /// this arises on the parts we support; upgrade to acc-cluster-index keying
    /// if a future SoC pairs same-count clusters with different tables.
    private let cpuFreqTablesByCount: [Int: [Double]]

    /// SMC die-temperature reader (GPU/CPU). Best-effort: `nil` when AppleSMC
    /// exposes no readable `flt` temperature sensors, leaving the temperature
    /// fields `nil` per the graceful-degradation contract.
    private let smc: SMCReader?

    public init() throws {
        // Subscribe to GPU + CPU perf-state residency and the Energy Model
        // power counters in one subscription. GPU Stats is required (it is the
        // v1 contract); CPU Stats / Energy Model are best-effort merges — a
        // missing group just leaves those fields nil. Passing nil subgroup
        // keeps us robust to subgroup-name drift across OS versions.
        guard let channels = IOReportCopyChannelsInGroup(
            "GPU Stats" as CFString, nil, 0, 0, 0) else {
            throw InitError.ioReportUnavailable
        }
        for group in ["CPU Stats", "Energy Model"] {
            guard let extra = IOReportCopyChannelsInGroup(
                group as CFString, nil, 0, 0, 0) else { continue }
            IOReportMergeChannels(channels, extra, nil)
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

        // Frequency tables are best-effort: residency alone still gives us
        // active-residency, just not an effective-MHz figure.
        self.gpuFreqsMHz = Self.loadGPUFrequencyTableMHz() ?? []
        self.cpuFreqTablesByCount = Self.loadCPUFrequencyTablesMHz()
        // Temperatures come from SMC (see SMCReader). Enumerates its sensors
        // once here; sample() only re-reads their values.
        self.smc = SMCReader()

        if Self.debug {
            FileHandle.standardError.write(Data(
                ("asmetrics: gpu DVFS table (MHz): \(gpuFreqsMHz)\n"
                    + "asmetrics: cpu DVFS tables by active-count (MHz): "
                    + "\(cpuFreqTablesByCount)\n").utf8))
            Self.dumpThermalChannels()
        }
    }

    /// Debug aid for porting temperature to a new SoC/OS: dump every IOReport
    /// channel (across *all* groups, not just the ones we subscribe to) whose
    /// group/subgroup/name looks thermal. This is how the M4-vs-M5 difference
    /// was found — the GPU-temperature channels live outside "GPU Stats" (or,
    /// on M5, do not exist at all, which is why temperatures come from SMC).
    private static func dumpThermalChannels() {
        guard let all = IOReportCopyAllChannels(0, 0),
            let entries = (all as NSDictionary)["IOReportChannels"] as? NSArray
        else { return }
        for case let entry as NSDictionary in entries {
            let channel = unsafeBitCast(entry, to: CFDictionary.self)
            let group = (IOReportChannelGetGroup(channel) as String?) ?? "-"
            let sub = (IOReportChannelGetSubGroup(channel) as String?) ?? "-"
            let name = (IOReportChannelGetChannelName(channel) as String?) ?? "-"
            let hay = "\(group) \(sub) \(name)".lowercased()
            guard hay.contains("temp") || name.hasPrefix("Tg") || name.hasPrefix("Tp")
            else { continue }
            FileHandle.standardError.write(Data(
                "asmetrics: thermal channel group=\(group) subgroup=\(sub) name=\(name)\n".utf8))
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
        sampleLock.lock()
        defer { sampleLock.unlock() }

        let window = max(0, interval)
        guard let first = IOReportCreateSamples(
            subscription, subscribedChannels, nil) else {
            return SoCSample()
        }
        Thread.sleep(forTimeInterval: window)
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

        var out = SoCSample()
        var clusters: [String: Double] = [:]
        // Energy in joules per component over the window, from the "Energy
        // Model" scalar counters. Package = CPU + GPU + ANE.
        var energyJ: [String: Double] = [:]

        for case let entry as NSDictionary in entries {
            let channel = unsafeBitCast(entry, to: CFDictionary.self)

            let group = IOReportChannelGetGroup(channel) as String?
            let name = IOReportChannelGetChannelName(channel) as String?

            if Self.debug {
                let sub = IOReportChannelGetSubGroup(channel) as String? ?? "-"
                let unit = IOReportChannelGetUnitLabel(channel) as String? ?? "-"
                let count = IOReportStateGetCount(channel)
                let scalar = IOReportSimpleGetIntegerValue(channel, 0)
                let line = "asmetrics: channel group=\(group ?? "-") "
                    + "subgroup=\(sub) name=\(name ?? "-") "
                    + "states=\(count) unit=\(unit) scalar=\(scalar)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }

            switch group {
            case "GPU Stats" where name == "GPUPH":
                if let r = residencyWeighted(channel, freqs: gpuFreqsMHz, label: name ?? "GPU") {
                    out.gpuFrequencyMHz = r.frequencyMHz
                    out.gpuActiveResidency = r.activeResidency
                }

            case "CPU Stats":
                // Per-cluster residency lives in the "CPU Complex Performance
                // States" subgroup; channel names contain "CPU" (ECPU/PCPU, or
                // MCPU0/PCPU on M5). Exclude the "_IDLE" companions and the
                // "…CPM" power-management channels (they have no DVFS table).
                let sub = IOReportChannelGetSubGroup(channel) as String?
                guard sub == "CPU Complex Performance States",
                    let name, name.contains("CPU"), !name.contains("_IDLE")
                else { continue }
                // Match the cluster to its DVFS table by active-state count.
                let active = activeStateCount(channel)
                guard let freqs = cpuFreqTablesByCount[active] else { continue }
                if let r = residencyWeighted(channel, freqs: freqs, label: name),
                    let mhz = r.frequencyMHz {
                    clusters[name] = mhz
                }

            case "Energy Model":
                guard let name else { continue }
                let unit = IOReportChannelGetUnitLabel(channel) as String? ?? ""
                let raw = Double(IOReportSimpleGetIntegerValue(channel, 0))
                let joules = raw * Self.energyUnitToJoules(unit)
                energyJ[name, default: 0] += joules

            default:
                continue
            }
        }

        if !clusters.isEmpty { out.cpuClusterFrequenciesMHz = clusters }

        if window > 0, !energyJ.isEmpty {
            // Pick the per-component *aggregate* Energy Model counters by exact
            // name (first candidate that exists), never summing sub-component
            // breakdowns like "MCPU0DTL…" or "PACC_…" — those would double
            // count. Names vary by chip, hence the candidate lists.
            let cpu = Self.aggregate(energyJ, ["CPU Energy", "CPU"])
            let gpu = Self.aggregate(energyJ, ["GPU Energy", "GPU"])
            let ane = Self.aggregate(energyJ, ["ANE Energy", "ANE", "ANE0"])

            if let ane { out.anePowerWatts = ane / window }
            // Package = CPU + GPU + ANE, matching powermetrics's "Combined
            // Power (CPU + GPU + ANE)". Sum whichever components were found.
            let parts = [cpu, gpu, ane].compactMap { $0 }
            if !parts.isEmpty { out.packagePowerWatts = parts.reduce(0, +) / window }
        }

        // Die temperatures are instantaneous SMC gauges (no window needed).
        if let smc {
            let t = smc.readTemperatures()
            out.gpuTemperatureC = t.gpu
            out.cpuTemperatureC = t.cpu
        }

        return out
    }

    // MARK: - Residency math (shared by GPU and CPU clusters)

    /// Compute the residency-weighted effective frequency (MHz) and the
    /// active-residency fraction from a performance-state channel.
    ///
    /// The state table is `[<inactive states…>, P1, P2, …, Pn]`. The active
    /// states align 1:1 with `freqs` once the leading inactive states are
    /// skipped. Effective MHz = Σ(residencyᵢ · freqᵢ) / Σ(active residency);
    /// active residency = Σ(active residency) / Σ(all residency).
    private func residencyWeighted(
        _ channel: CFDictionary, freqs: [Double], label: String
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
            return (freqs.first, 0)
        }

        let activeStates = residencies.count - offset
        if Self.debug, !freqs.isEmpty, activeStates != freqs.count {
            FileHandle.standardError.write(Data(
                ("asmetrics: WARNING \(label) active-state/frequency-table "
                    + "mismatch — \(activeStates) active states vs \(freqs.count) "
                    + "freqs; weighted sum truncated to \(min(activeStates, freqs.count))\n").utf8))
        }

        let total = residencies.reduce(0, +)
        let activeSum = residencies[offset...].reduce(0, +)
        let activeResidency = total > 0 ? activeSum / total : 0

        var frequencyMHz: Double?
        if !freqs.isEmpty {
            if activeSum > 0 {
                var weighted = 0.0
                let n = min(freqs.count, activeStates)
                for i in 0..<n {
                    weighted += (residencies[i + offset] / activeSum) * freqs[i]
                }
                frequencyMHz = weighted
            } else {
                // Idle: report the lowest active P-state frequency.
                frequencyMHz = freqs.first
            }
        }

        return (frequencyMHz, activeResidency)
    }

    // MARK: - Energy unit conversion

    /// Convert one "Energy Model" counter's raw integer, per its unit label, to
    /// joules. Labels vary by chip (mJ / µJ / nJ). Unknown labels assume mJ,
    /// the most common case, rather than dropping the reading.
    static func energyUnitToJoules(_ unit: String) -> Double {
        switch unit.lowercased() {
        case "mj": return 1e-3
        case "uj", "µj": return 1e-6
        case "nj": return 1e-9
        case "j": return 1
        default: return 1e-3
        }
    }

    /// The first `candidates` name present in `energy` (exact match), or nil.
    /// Used to pick an aggregate component counter without summing its
    /// per-core / per-rail sub-components.
    private static func aggregate(_ energy: [String: Double], _ candidates: [String]) -> Double? {
        for c in candidates { if let v = energy[c] { return v } }
        return nil
    }

    /// Number of *active* (non-idle) performance states a residency channel
    /// reports — its total state count minus the leading idle states. Used to
    /// match a CPU cluster channel to its DVFS table.
    private func activeStateCount(_ channel: CFDictionary) -> Int {
        let count = Int(IOReportStateGetCount(channel))
        for i in 0..<count {
            let name = (IOReportStateGetNameForIndex(channel, Int32(i)) as String?) ?? ""
            if !Self.inactiveStateNames.contains(name) { return count - i }
        }
        return 0
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

    /// Load the CPU clusters' DVFS frequency tables (MHz), keyed by table
    /// length (= a cluster's active-state count). The set of CPU cluster tables
    /// is discovered from the `acc-clusters` blob (portable across SoCs: M1–M4
    /// clusters are `voltage-states1/5`, but M5 renumbers them), and each
    /// cluster's frequencies live in the `-sram` variant of its `voltage-statesN`
    /// key. Returns an empty map when nothing usable is found.
    private static func loadCPUFrequencyTablesMHz() -> [Int: [Double]] {
        // M5+ enumerates its clusters in `acc-clusters` (8-byte records; byte 0
        // is the cluster's voltage-states index). M1–M4 have no such blob and
        // use the fixed layout ECPU=voltage-states1 / PCPU=voltage-states5.
        var indices: [Int] = []
        if let acc = searchRegistryData(key: "acc-clusters") {
            acc.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count - 7, by: 8) {
                    indices.append(Int(raw[i]))
                }
            }
        }
        if indices.isEmpty { indices = [1, 5] }

        var tables: [Int: [Double]] = [:]
        for idx in indices {
            let key = "voltage-states\(idx)-sram"
            guard let data = searchRegistryData(key: key),
                let raw = parseVoltageStates(data) else { continue }
            let mhz = raw.map(normalizeToMHz).drop(while: { $0 <= 0 })
            let active = Array(mhz)
            guard active.count > 0, active.contains(where: { $0 > 0 }) else { continue }
            tables[active.count] = active
            if debug {
                FileHandle.standardError.write(Data(
                    "asmetrics: cpu freqs from \(key): \(active)\n".utf8))
            }
        }
        return tables
    }

    /// Normalize a raw DVFS frequency field to MHz by magnitude, so we don't
    /// need a per-chip unit table: values in Hz (≥1e8) ÷1e6, in kHz (≥1e5)
    /// ÷1e3 (M4/M5 store kHz), otherwise already MHz.
    private static func normalizeToMHz(_ v: Double) -> Double {
        if v >= 1e8 { return v / 1e6 }
        if v >= 1e5 { return v / 1e3 }
        return v
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

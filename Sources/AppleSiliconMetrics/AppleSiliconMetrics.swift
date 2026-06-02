import Foundation

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
/// ## Status: SCAFFOLD
/// This is an API skeleton — the IOReport plumbing is **not yet implemented**,
/// so `sample(interval:)` returns an empty `SoCSample`. The full
/// implementation brief lives in **`PROMPT.md`** at the package root: the
/// IOReport call sequence, private-framework linking, the voltage-states
/// frequency table, validation against `powermetrics`, and the MIT-licensed
/// references to port from.
public final class SoCSampler: @unchecked Sendable {
    public enum InitError: Error {
        /// IOReport (or the expected GPU channels) is unavailable on this host.
        case ioReportUnavailable
    }

    public init() throws {
        // TODO (PROMPT.md §Sampling): build the IOReport channel subscription
        // for the GPU performance-state group here, and load the per-state
        // frequency table from IORegistry (voltage-states). Throw
        // `.ioReportUnavailable` if the framework/channels can't be opened so
        // callers can fall back cleanly.
    }

    /// Take a delta sample over `interval` seconds (two IOReport snapshots with
    /// the interval between them).
    public func sample(interval: TimeInterval = 0.1) -> SoCSample {
        // TODO (PROMPT.md §Sampling): IOReportCreateSamples → wait(interval) →
        // IOReportCreateSamples → IOReportCreateSamplesDelta → iterate the GPU
        // performance-state channel → residency-weight by the voltage-states
        // frequencies → effective MHz + active residency.
        _ = interval
        return SoCSample()
    }
}

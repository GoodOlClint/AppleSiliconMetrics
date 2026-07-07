import Testing

@testable import AppleSiliconMetrics

/// Whether we're running on Apple Silicon, where IOReport + the GPU
/// performance-state channels are expected to be present.
private let isAppleSilicon: Bool = {
    #if arch(arm64)
        return true
    #else
        return false
    #endif
}()

/// The sampler constructs and returns a sample without crashing. On
/// non–Apple-Silicon (or where IOReport is unavailable) construction may throw
/// `.ioReportUnavailable`, which is the documented graceful-degradation
/// contract — so that case is tolerated rather than failed.
@Test func samplerConstructsAndSamples() throws {
    let sampler: SoCSampler
    do {
        sampler = try SoCSampler()
    } catch SoCSampler.InitError.ioReportUnavailable {
        return  // IOReport unavailable on this host — acceptable.
    }
    _ = sampler.sample(interval: 0.05)  // must never trap
}

/// On Apple Silicon the GPU effective frequency must be reported and land in a
/// sane DVFS range. This is the core v1 assertion (PROMPT §Validation).
@Test func gpuFrequencyIsSaneOnAppleSilicon() throws {
    try #require(isAppleSilicon, "GPU frequency assertions require Apple Silicon")

    let sampler = try SoCSampler()
    let sample = sampler.sample(interval: 0.1)

    let mhz = try #require(
        sample.gpuFrequencyMHz, "gpuFrequencyMHz should be non-nil on Apple Silicon")
    #expect(mhz >= 100, "GPU frequency implausibly low: \(mhz)")
    #expect(mhz <= 2000, "GPU frequency implausibly high: \(mhz)")

    if let active = sample.gpuActiveResidency {
        #expect(active >= 0)
        #expect(active <= 1)
    }
}

/// CPU cluster frequencies, when reported, land in a sane DVFS range. Each
/// cluster is a residency-weighted effective MHz (or its parked floor clock),
/// so it must sit within Apple Silicon's CPU envelope.
@Test func cpuClusterFrequenciesAreSaneOnAppleSilicon() throws {
    try #require(isAppleSilicon, "requires Apple Silicon")

    let sampler = try SoCSampler()
    let sample = sampler.sample(interval: 0.1)

    // The field is optional (nil where CPU perf-state channels/DVFS tables are
    // unreadable); when present, every cluster must be in range.
    if let clusters = sample.cpuClusterFrequenciesMHz {
        #expect(!clusters.isEmpty, "reported an empty cluster map")
        for (name, mhz) in clusters {
            #expect(!mhz.isNaN, "\(name) is NaN")
            #expect(mhz >= 200, "\(name) implausibly low: \(mhz)")
            #expect(mhz <= 5000, "\(name) implausibly high: \(mhz)")
        }
    }
}

/// Power readings, when reported, are non-negative and within a whole-package
/// envelope. ANE never exceeds package.
@Test func powerReadingsAreSaneOnAppleSilicon() throws {
    try #require(isAppleSilicon, "requires Apple Silicon")

    let sampler = try SoCSampler()
    let sample = sampler.sample(interval: 0.1)

    if let pkg = sample.packagePowerWatts {
        #expect(!pkg.isNaN)
        #expect(pkg >= 0, "negative package power: \(pkg)")
        #expect(pkg <= 300, "package power implausibly high: \(pkg)")
    }
    if let ane = sample.anePowerWatts {
        #expect(ane >= 0, "negative ANE power: \(ane)")
        #expect(ane <= 100, "ANE power implausibly high: \(ane)")
        if let pkg = sample.packagePowerWatts {
            #expect(ane <= pkg + 0.001, "ANE (\(ane)) exceeds package (\(pkg))")
        }
    }
}

/// The energy-unit conversion maps each chip's label to joules correctly —
/// the mJ/µJ/nJ variance the "Energy Model" counters exhibit across SoCs.
@Test func energyUnitConversion() {
    #expect(SoCSampler.energyUnitToJoules("mJ") == 1e-3)
    #expect(SoCSampler.energyUnitToJoules("uJ") == 1e-6)
    #expect(SoCSampler.energyUnitToJoules("µJ") == 1e-6)
    #expect(SoCSampler.energyUnitToJoules("nJ") == 1e-9)
    #expect(SoCSampler.energyUnitToJoules("J") == 1)
    // Unknown labels fall back to mJ rather than dropping the reading.
    #expect(SoCSampler.energyUnitToJoules("???") == 1e-3)
}

/// Repeated sampling stays stable and within range — no NaN or out-of-band
/// values from the residency weighting.
@Test func repeatedSamplingStaysInRange() throws {
    try #require(isAppleSilicon, "requires Apple Silicon")

    let sampler = try SoCSampler()
    for _ in 0..<5 {
        let sample = sampler.sample(interval: 0.05)
        if let mhz = sample.gpuFrequencyMHz {
            #expect(!mhz.isNaN)
            #expect((100...2000).contains(mhz), "out of range: \(mhz)")
        }
    }
}

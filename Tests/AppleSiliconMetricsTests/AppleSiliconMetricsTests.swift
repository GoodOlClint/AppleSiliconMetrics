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

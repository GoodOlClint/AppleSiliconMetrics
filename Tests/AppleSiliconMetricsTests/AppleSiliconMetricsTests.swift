import XCTest

@testable import AppleSiliconMetrics

final class AppleSiliconMetricsTests: XCTestCase {
    /// Scaffold smoke test: the sampler constructs and returns a (currently
    /// empty) sample without crashing. Real assertions — GPU MHz within
    /// tolerance of `powermetrics`, non-nil on Apple Silicon — land with the
    /// IOReport implementation (see PROMPT.md §Validation).
    func testSamplerConstructsAndSamples() throws {
        let sampler = try SoCSampler()
        let sample = sampler.sample(interval: 0.05)
        // Scaffold contract: fields are optional and default to nil.
        XCTAssertNil(sample.gpuFrequencyMHz)
    }
}

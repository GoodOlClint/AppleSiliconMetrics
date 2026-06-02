// swift-tools-version: 6.0
import PackageDescription

// AppleSiliconMetrics — sudoless Apple Silicon SoC telemetry (GPU/CPU/ANE
// frequency, residency, power) via the private IOReport framework, plus
// (later) per-component temperature. MIT-licensed; intended to fill the gap
// where no maintained Swift package exists (the good implementations are all
// Rust/Go/Python). See PROMPT.md for the implementation brief.
let package = Package(
    name: "AppleSiliconMetrics",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppleSiliconMetrics", targets: ["AppleSiliconMetrics"]),
        .executable(name: "asmetrics", targets: ["asmetrics"]),
    ],
    targets: [
        // Pure-Swift public API. The implementing session adds a `CIOReport`
        // systemLibrary target (module map + header declaring the IOReport
        // symbols) and lists it as a dependency here — see PROMPT.md §Linking.
        .target(name: "AppleSiliconMetrics"),
        .executableTarget(
            name: "asmetrics", dependencies: ["AppleSiliconMetrics"]),
        .testTarget(
            name: "AppleSiliconMetricsTests",
            dependencies: ["AppleSiliconMetrics"]),
    ]
)

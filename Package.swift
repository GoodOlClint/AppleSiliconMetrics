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
        // System-library shim re-declaring the private IOReport C symbols.
        // The framework lives only in the dyld shared cache (no .framework on
        // disk, no SDK stub), so we link the `IOReport` dylib by name on the
        // consuming target below; the linker resolves it from the cache.
        .systemLibrary(name: "CIOReport"),
        .target(
            name: "AppleSiliconMetrics",
            dependencies: ["CIOReport"],
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]),
        .executableTarget(
            name: "asmetrics", dependencies: ["AppleSiliconMetrics"]),
        .testTarget(
            name: "AppleSiliconMetricsTests",
            dependencies: ["AppleSiliconMetrics"]),
    ]
)

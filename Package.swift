// swift-tools-version: 6.0
import PackageDescription

// SoCMetrics (swift-soc-metrics) — sudoless SoC telemetry for Apple Silicon
// (GPU/CPU/ANE frequency, residency, power, and die temperature) via the
// private IOReport framework + AppleSMC. MIT-licensed; intended to fill the gap
// where no maintained Swift package exists (the good implementations are all
// Rust/Go/Python). See PROMPT.md for the implementation brief.
let package = Package(
    name: "swift-soc-metrics",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SoCMetrics", targets: ["SoCMetrics"]),
        .executable(name: "asmetrics", targets: ["asmetrics"]),
    ],
    targets: [
        // System-library shim re-declaring the private IOReport C symbols.
        // The framework lives only in the dyld shared cache (no .framework on
        // disk, no SDK stub), so we link the `IOReport` dylib by name on the
        // consuming target below; the linker resolves it from the cache.
        .systemLibrary(name: "CIOReport"),
        .target(
            name: "SoCMetrics",
            dependencies: ["CIOReport"],
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]),
        .executableTarget(
            name: "asmetrics", dependencies: ["SoCMetrics"]),
        .testTarget(
            name: "SoCMetricsTests",
            dependencies: ["SoCMetrics"]),
    ]
)

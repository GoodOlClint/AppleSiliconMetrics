import AppleSiliconMetrics
import Foundation

// Tiny validation CLI. Once the IOReport implementation lands, run:
//   swift run asmetrics --watch
// and compare against:
//   sudo powermetrics --samplers gpu_power   # "GPU HW active frequency"
//
// Usage: asmetrics [--watch] [--interval <secs>]

let args = CommandLine.arguments
let watch = args.contains("--watch")
let interval: TimeInterval = {
    if let i = args.firstIndex(of: "--interval"), i + 1 < args.count,
        let v = Double(args[i + 1]) { return v }
    return 0.5
}()

func render(_ s: SoCSample) -> String {
    let mhz = s.gpuFrequencyMHz.map { String(format: "%.0f", $0) } ?? "n/a"
    let act = s.gpuActiveResidency.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
    return "gpu_mhz=\(mhz)  gpu_active=\(act)"
}

do {
    let sampler = try SoCSampler()
    repeat {
        print(render(sampler.sample(interval: interval)))
        fflush(stdout)
    } while watch
} catch {
    FileHandle.standardError.write(Data("asmetrics: \(error)\n".utf8))
    exit(1)
}

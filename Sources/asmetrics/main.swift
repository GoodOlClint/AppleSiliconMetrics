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
    let cpu = s.cpuClusterFrequenciesMHz.map { clusters in
        clusters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.0f", $0.value))" }
            .joined(separator: ",")
    } ?? "n/a"
    let ane = s.anePowerWatts.map { String(format: "%.2fW", $0) } ?? "n/a"
    let pkg = s.packagePowerWatts.map { String(format: "%.2fW", $0) } ?? "n/a"
    let gtemp = s.gpuTemperatureC.map { String(format: "%.1fC", $0) } ?? "n/a"
    let ctemp = s.cpuTemperatureC.map { String(format: "%.1fC", $0) } ?? "n/a"
    return "gpu_mhz=\(mhz)  gpu_active=\(act)  cpu_mhz=[\(cpu)]  ane=\(ane)  pkg=\(pkg)"
        + "  gpu_temp=\(gtemp)  cpu_temp=\(ctemp)"
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

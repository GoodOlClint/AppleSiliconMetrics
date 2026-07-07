import CIOReport
import Foundation
import IOKit

/// Reads Apple SMC sensor keys **sudoless** (the `AppleSMC` user-client; reads
/// are unprivileged — only SMC *writes*, e.g. fan control, need root).
///
/// Used for die temperatures, which IOReport does not usefully expose: M5 has
/// no GPU-temperature channels at all, and M4's `GPU Stats`/`Temperature`
/// channels read back 0 through the documented `IOReportSimpleGetIntegerValue`
/// accessor. This mirrors the MIT `mactop`, which likewise reads temperature
/// from SMC (not IOReport): filter the `flt`-typed sensor keys by prefix — `Tg`
/// for GPU, `Tp`/`Te` for the CPU P-/E-clusters — and average each group.
///
/// The key set is chip-specific (M5's `Tg0U`/`Tg0X`/`Tg0d…`, M4's `Tg0z`/`Tg2o…`)
/// so we discover it by *enumeration + prefix match* rather than a per-SoC key
/// table that would rot. `flt` is a little-endian IEEE-754 `Float` already in °C.
final class SMCReader {
    /// 4-char SMC data-type code `'flt '` (little-endian IEEE float), as a
    /// big-endian `UInt32` — the only sensor type we read.
    private static let fltType: UInt32 = 0x666c_7420

    private static let debug = ProcessInfo.processInfo.environment["ASMETRICS_DEBUG"] != nil

    private let conn: io_connect_t
    /// `(key, dataSize)` for each discovered `flt` temperature sensor, split by
    /// component. Discovered once at open; only the values are re-read per sample.
    private let gpuKeys: [(key: UInt32, size: UInt32)]
    private let cpuKeys: [(key: UInt32, size: UInt32)]

    /// Opens the SMC connection and enumerates its temperature sensors once.
    /// Returns `nil` when `AppleSMC` is unavailable or exposes no `flt`
    /// temperature sensors (leaving the temperature fields `nil`, per contract).
    init?() {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        var c: io_connect_t = 0
        let opened = IOServiceOpen(svc, mach_task_self_, 0, &c)
        IOObjectRelease(svc)
        guard opened == KERN_SUCCESS else { return nil }
        self.conn = c

        let (gpu, cpu) = Self.discoverTempKeys(conn: c)
        self.gpuKeys = gpu
        self.cpuKeys = cpu
        guard !gpu.isEmpty || !cpu.isEmpty else {
            IOServiceClose(c)
            return nil
        }
        if Self.debug {
            FileHandle.standardError.write(Data(
                ("asmetrics: SMC temp sensors — gpu(Tg)=\(gpu.count) "
                    + "cpu(Tp/Te)=\(cpu.count)\n").utf8))
        }
    }

    deinit { IOServiceClose(conn) }

    /// Mean GPU and CPU die temperature in °C over the currently-live sensor
    /// readings (each `nil` when that component has no readable sensors).
    func readTemperatures() -> (gpu: Double?, cpu: Double?) {
        (mean(gpuKeys), mean(cpuKeys))
    }

    /// Average the live readings of `keys`, ignoring anything outside a sane
    /// 0–150 °C band (a sensor that fails or reads garbage must not skew the
    /// mean). `nil` when nothing readable remains.
    private func mean(_ keys: [(key: UInt32, size: UInt32)]) -> Double? {
        var sum = 0.0
        var n = 0
        for k in keys {
            guard let v = Self.readFloat(conn, key: k.key, size: k.size),
                v > 0, v < 150 else { continue }
            sum += v
            n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }

    // MARK: - SMC user-client plumbing

    /// One `IOConnectCallStructMethod` round-trip through the single SMC
    /// selector; the request's `data8` picks read-key / key-info / key-by-index.
    private static func call(_ conn: io_connect_t, _ input: inout SMCKeyData_t) -> SMCKeyData_t? {
        var output = SMCKeyData_t()
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        let r = IOConnectCallStructMethod(
            conn, UInt32(kSMCHandleYPCEvent),
            &input, MemoryLayout<SMCKeyData_t>.stride, &output, &outSize)
        return r == KERN_SUCCESS ? output : nil
    }

    /// Read a `flt` sensor's current value (°C). The float lives little-endian
    /// in the first 4 payload bytes.
    private static func readFloat(_ conn: io_connect_t, key: UInt32, size: UInt32) -> Double? {
        guard size >= 4 else { return nil }
        var i = SMCKeyData_t()
        i.key = key
        i.keyInfo.dataSize = size
        i.data8 = UInt8(kSMCReadKey)
        guard let o = call(conn, &i) else { return nil }
        let bits = withUnsafeBytes(of: o.bytes) { raw in
            UInt32(raw[0]) | UInt32(raw[1]) << 8
                | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
        }
        return Double(Float(bitPattern: bits))
    }

    /// Enumerate every SMC key (via the `#KEY` count + index lookup) and keep
    /// the `flt`-typed temperature sensors, split into GPU (`Tg…`) and CPU
    /// (`Tp…`/`Te…`) by the same prefixes `mactop` uses.
    private static func discoverTempKeys(
        conn: io_connect_t
    ) -> (gpu: [(key: UInt32, size: UInt32)], cpu: [(key: UInt32, size: UInt32)]) {
        // "#KEY" holds the total key count as a big-endian UInt32.
        var kc = SMCKeyData_t()
        kc.key = fourCC("#KEY")
        kc.keyInfo.dataSize = 4
        kc.data8 = UInt8(kSMCReadKey)
        guard let ko = call(conn, &kc) else { return ([], []) }
        let count = withUnsafeBytes(of: ko.bytes) { raw in
            UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16
                | UInt32(raw[2]) << 8 | UInt32(raw[3])
        }

        var gpu = [(key: UInt32, size: UInt32)]()
        var cpu = [(key: UInt32, size: UInt32)]()
        for idx in 0..<count {
            var byIndex = SMCKeyData_t()
            byIndex.data8 = UInt8(kSMCGetKeyFromIndex)
            byIndex.data32 = idx
            guard let ki = call(conn, &byIndex), ki.key != 0 else { continue }

            var info = SMCKeyData_t()
            info.key = ki.key
            info.data8 = UInt8(kSMCGetKeyInfo)
            guard let info = call(conn, &info),
                info.keyInfo.dataType == fltType else { continue }

            let name = codeStr(ki.key)
            let entry = (key: ki.key, size: info.keyInfo.dataSize)
            if name.hasPrefix("Tg") {
                gpu.append(entry)
            } else if name.hasPrefix("Tp") || name.hasPrefix("Te") {
                cpu.append(entry)
            }
        }
        return (gpu, cpu)
    }

    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in s.utf8 { v = (v << 8) | UInt32(b) }
        return v
    }

    private static func codeStr(_ v: UInt32) -> String {
        let b = [
            UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v),
        ]
        return String(bytes: b, encoding: .ascii) ?? ""
    }
}

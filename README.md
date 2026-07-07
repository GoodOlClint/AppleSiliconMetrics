# SoCMetrics

[![CI](https://github.com/GoodOlClint/swift-soc-metrics/actions/workflows/ci.yml/badge.svg)](https://github.com/GoodOlClint/swift-soc-metrics/actions/workflows/ci.yml)

Sudoless SoC telemetry **for Apple Silicon**, in Swift — GPU/CPU/ANE
**frequency**, **active residency**, **power**, and per-component **die
temperature**, read directly from the private `IOReport` framework (the same
source `powermetrics` uses) and the `AppleSMC` sensors, with no root and no
subprocess.

> **Status: working (v0.4).** GPU effective frequency + active residency,
> per-CPU-cluster frequencies, ANE + whole-package power (all via IOReport), and
> GPU/CPU **die temperature** (via SMC) are implemented sudoless and validated on
> Apple Silicon idle and loaded — GPU frequency exact, package power within ~1%,
> and GPU die temperature tracking a Metal burn (M5 Max ≈44→72 °C, M4 Max
> ≈35→54 °C) on both M5 Max and M4 Max, macOS 26.

## Why this exists

There is no maintained Swift package for Apple Silicon telemetry. The clean implementations are
all in other languages — [macmon](https://github.com/vladkens/macmon) and
[macpow](https://github.com/k06a/macpow) (Rust), [mactop](https://github.com/metaspartan/mactop)
(Go), [agtop](https://github.com/binlecode/agtop) (Python). The Swift options
are full apps (e.g. `exelban/Stats`, which is also GPL-3.0). This package ports
the `IOReport` approach into a small, MIT-licensed, reusable SwiftPM library.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/GoodOlClint/swift-soc-metrics.git", from: "0.4.0")
]
```

Then add the `SoCMetrics` product to your target's dependencies.

Requires macOS 13+ and Apple Silicon (constructs but degrades to `nil` elsewhere).

## Usage (target API)

```swift
import SoCMetrics

let sampler = try SoCSampler()
let s = sampler.sample(interval: 0.2)
print(s.gpuFrequencyMHz ?? -1)   // effective GPU MHz over the window
print(s.gpuTemperatureC ?? -1)   // GPU die temperature in °C (nil if unavailable)
```

Or the bundled CLI, for validation against `powermetrics`:

```sh
swift run asmetrics --watch
# compare in another terminal:
sudo powermetrics --samplers gpu_power | grep "GPU HW active frequency"
```

Set `ASMETRICS_DEBUG=1` to dump the discovered IOReport channels, the loaded
DVFS frequency table, the discovered SMC temperature sensors, and every
thermal-looking IOReport channel across all groups — handy when porting to a
new SoC or OS.

### Running the tests

The test suite uses `swift-testing`, which ships with the full Xcode toolchain
(not Command Line Tools). If `swift test` reports `no such module 'Testing'`,
point it at Xcode for that command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The library and `asmetrics` CLI build fine under Command Line Tools alone.

## Scope

- **v0.1:** GPU effective frequency (MHz) + active residency, sudoless via
  IOReport. The stable, generation-portable core.
- **v0.2:** CPU cluster frequencies + ANE/whole-package power (IOReport).
- **v0.3:** GPU/CPU **die temperature** in °C, via SMC. IOReport turned out not
  to expose usable temperature (M5 has no GPU-temp channels; M4's read back 0),
  so temperature is read from the `AppleSMC` `flt` sensors — discovered by
  prefix (`Tg`/`Tp`/`Te`) rather than a per-SoC key table that rots. See
  [ADR 0001](docs/decisions/0001-die-temperature-from-smc-not-ioreport.md).
- **v0.4:** no new metrics — renamed the package to `SoCMetrics`
  (`swift-soc-metrics`); `import SoCMetrics` (was `AppleSiliconMetrics`).

## Caveats

`IOReport` and the `AppleSMC` sensor layout are **private, undocumented, and
version-fragile**. Every metric is optional and returns `nil` when unreadable,
so consumers degrade gracefully. No private symbols are copied from GPL sources;
the implementation is an independent port of the documented-by-reverse-engineering
call sequence.

**Tested only on macOS 26** (Tahoe), on M4 Max and M5 Max. It builds for macOS
13+ and is written to degrade to `nil` on other OS versions and chips, but the
channel names, DVFS-table encodings, and SMC sensor keys have not been verified
against any other macOS release — treat earlier/later versions as unvalidated.

## Trademarks

Not affiliated with, authorized by, or endorsed by Apple Inc. "Apple" and
"Apple Silicon" are trademarks of Apple Inc., used here only descriptively to
identify the hardware this library reads.

## License

MIT.

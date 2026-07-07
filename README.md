# AppleSiliconMetrics

[![CI](https://github.com/GoodOlClint/AppleSiliconMetrics/actions/workflows/ci.yml/badge.svg)](https://github.com/GoodOlClint/AppleSiliconMetrics/actions/workflows/ci.yml)

Sudoless Apple Silicon SoC telemetry for Swift — GPU/CPU/ANE **frequency**,
**active residency**, and **power**, read directly from the private `IOReport`
framework (the same source `powermetrics` uses), with no root and no
subprocess. Per-component **temperature** is a later, opt-in addition.

> **Status: working (v0.1.0).** GPU effective frequency + active residency are
> implemented sudoless via IOReport and validated against `powermetrics` on
> Apple Silicon (exact match idle and loaded on M5 Max and M4 Max, macOS 26).
> CPU/ANE/package power
> and temperature are still to come — see [`PROMPT.md`](PROMPT.md).

## Why this exists

There is no maintained Swift package for this. The clean implementations are
all in other languages — [macmon](https://github.com/vladkens/macmon) and
[macpow](https://github.com/k06a/macpow) (Rust), [mactop](https://github.com/metaspartan/mactop)
(Go), [agtop](https://github.com/binlecode/agtop) (Python). The Swift options
are full apps (e.g. `exelban/Stats`, which is also GPL-3.0). This package ports
the `IOReport` approach into a small, MIT-licensed, reusable SwiftPM library.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/GoodOlClint/AppleSiliconMetrics.git", from: "0.1.0")
]
```

Requires macOS 13+ and Apple Silicon (constructs but degrades to `nil` elsewhere).

## Usage (target API)

```swift
import AppleSiliconMetrics

let sampler = try SoCSampler()
let s = sampler.sample(interval: 0.2)
print(s.gpuFrequencyMHz ?? -1)   // effective GPU MHz over the window
```

Or the bundled CLI, for validation against `powermetrics`:

```sh
swift run asmetrics --watch
# compare in another terminal:
sudo powermetrics --samplers gpu_power | grep "GPU HW active frequency"
```

Set `ASMETRICS_DEBUG=1` to dump the discovered IOReport channels and the loaded
DVFS frequency table to stderr — handy when porting to a new SoC or OS.

### Running the tests

The test suite uses `swift-testing`, which ships with the full Xcode toolchain
(not Command Line Tools). If `swift test` reports `no such module 'Testing'`,
point it at Xcode for that command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The library and `asmetrics` CLI build fine under Command Line Tools alone.

## Scope

- **v1:** GPU effective frequency (MHz) + active residency, sudoless via
  IOReport. The stable, generation-portable core.
- **Later:** CPU cluster frequencies, ANE/package power, per-component temps.
  Temperature is the *fragile* part — Apple changes SMC sensor keys every SoC
  generation (M5, for example, exposes GPU temp via new `flt`-typed `Tg0*`
  keys) — so it ships behind its own type with per-SoC key tables.

## Caveats

`IOReport` is a **private framework**: undocumented and version-fragile. Every
metric is optional and returns `nil` when unreadable, so consumers degrade
gracefully. No private symbols are copied from GPL sources; the implementation
is an independent port of the documented-by-reverse-engineering call sequence.

## License

MIT.

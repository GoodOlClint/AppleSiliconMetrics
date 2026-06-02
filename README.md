# AppleSiliconMetrics

Sudoless Apple Silicon SoC telemetry for Swift — GPU/CPU/ANE **frequency**,
**active residency**, and **power**, read directly from the private `IOReport`
framework (the same source `powermetrics` uses), with no root and no
subprocess. Per-component **temperature** is a later, opt-in addition.

> **Status: scaffold.** The public API is in place; the IOReport implementation
> is the next step — see [`PROMPT.md`](PROMPT.md) for the full brief.

## Why this exists

There is no maintained Swift package for this. The clean implementations are
all in other languages — [macmon](https://github.com/vladkens/macmon) and
[macpow](https://github.com/k06a/macpow) (Rust), [mactop](https://github.com/metaspartan/mactop)
(Go), [agtop](https://github.com/binlecode/agtop) (Python). The Swift options
are full apps (e.g. `exelban/Stats`, which is also GPL-3.0). This package ports
the `IOReport` approach into a small, MIT-licensed, reusable SwiftPM library.

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
```

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

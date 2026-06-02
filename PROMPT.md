# Kickoff prompt — implement AppleSiliconMetrics

Paste this into a fresh coding session opened at `~/Source/AppleSiliconMetrics`.

---

You are implementing **AppleSiliconMetrics**, a small MIT-licensed SwiftPM
library that reads Apple Silicon SoC telemetry **sudoless** via the private
`IOReport` framework. The package is scaffolded and builds (pure-Swift stub);
your job is to make `SoCSampler.sample(interval:)` actually return real numbers,
starting with **GPU effective frequency (MHz) + active residency**.

## Goal (v1 — ship this first)

`try SoCSampler()` opens an IOReport subscription; `sample(interval:)` takes two
snapshots `interval` apart, deltas them, and returns:
- `gpuFrequencyMHz` — residency-weighted average of the active GPU DVFS
  performance states over the window (must match `powermetrics`'s
  "GPU HW active frequency" within a few %).
- `gpuActiveResidency` — fraction of the window the GPU was non-idle (0…1).

Keep every field optional and return `nil` (never crash/abort) when a channel
or symbol is missing — these are private interfaces and must degrade cleanly.

## Mechanism (the IOReport call sequence)

IOReport exposes hardware counters as "channels" grouped by name. The GPU
performance-state residency lives in a group commonly named **"GPU Stats"**
with subgroup/channel **"GPU Performance States"** (verify exact strings at
runtime by iterating — names vary by OS). The flow:

1. `IOReportCopyChannelsInGroup("GPU Stats", nil, 0, 0, 0)` → CFDictionary of
   channels. (You may also need "Energy Model" later for power.)
2. `IOReportMergeChannels(...)` if combining groups; then
   `IOReportCreateSubscription(nil, channels, &subbedChannels, 0, nil)`.
3. Snapshot A: `IOReportCreateSamples(subscription, subbedChannels, nil)`.
4. Wait `interval`.
5. Snapshot B: `IOReportCreateSamples(...)`.
6. Delta: `IOReportCreateSamplesDelta(sampleA, sampleB, nil)`.
7. `IOReportIterate(delta) { channel in ... }` — for the GPU perf-state
   channel (a *state*-type channel), read
   `IOReportStateGetCount(channel)`, and per index
   `IOReportStateGetNameForIndex(channel, i)` (e.g. "P1".."Pn", "IDLE"/"OFF")
   and `IOReportStateGetResidency(channel, i)` (a tick count over the window).
   Effective MHz = Σ(residency_i × freq_i) / Σ(residency_i over *active* states);
   active residency = Σ(active residency) / Σ(all residency).

### The per-state frequency table (voltage-states)
The residency indices map to clock frequencies you must read separately from
**IORegistry**: match the GPU accelerator service (try `IOServiceMatching(
"IOGPU")` / `"AGXAccelerator"` / the `pmgr` entry) and
`IORegistryEntryCreateCFProperties`, then pull the GPU DVFS table — the relevant
keys are typically `"voltage-states9"` / `"voltage-states9-sram"` (GPU) or a
`"GPUPerfStates"`-style array, encoded as packed `(freq, voltage)` `UInt32`
pairs in a `Data` blob, frequencies in Hz (÷ 1e6 for MHz). The number of states
should line up with the IOReport residency count. Confirm the mapping at runtime.

## Linking the private framework

Add a `CIOReport` **systemLibrary** target: a `module.modulemap` + a header
declaring the IOReport function prototypes (`IOReportCreateSubscription`,
`IOReportCopyChannelsInGroup`, `IOReportCreateSamples`,
`IOReportCreateSamplesDelta`, `IOReportMergeChannels`, `IOReportIterate`,
`IOReportStateGetCount`, `IOReportStateGetNameForIndex`,
`IOReportStateGetResidency`, `IOReportChannelGetGroup/SubGroup/ChannelName`,
`IOReportSimpleGetIntegerValue`, and the `IOReportSampleCB` block typedef).
Then link it from the main target. Two known-good options — pick whichever the
linker accepts on the target macOS:
- `linkerSettings: [.linkedLibrary("IOReport")]` (the `libIOReport` dylib), or
- `unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "IOReport"])`.

Get exact signatures from the MIT references below (do NOT copy GPL code).

## References to port from (all MIT — do not use the GPL `exelban/Stats`)

- **macmon** (Rust): https://github.com/vladkens/macmon — `src/sources.rs` has
  the cleanest IOReport channel + voltage-states logic. Primary reference.
- **mactop** (Go): https://github.com/metaspartan/mactop — IOReport cgo bindings.
- **agtop** (Python): https://github.com/binlecode/agtop — IOReport via ctypes.
- vladkens's writeup: https://medium.com/@vladkens/how-to-get-macos-power-metrics-with-rust-d42b0ad53967

## Validation

Build the CLI and compare on this host (Apple M5 Max):

```sh
swift run asmetrics --watch
# in another terminal:
sudo powermetrics --samplers gpu_power | grep "GPU HW active frequency"
```

`gpu_mhz` should track the powermetrics number within a few percent under both
idle and a sustained GPU load (run any Metal/inference workload). Add a test
that asserts `gpuFrequencyMHz != nil` on Apple Silicon and is in a sane range
(e.g. 100–2000 MHz).

## Later (separate, opt-in — don't block v1 on these)

- **CPU cluster freqs + ANE/package power** — same IOReport machinery, "Energy
  Model" / "CPU Stats" groups.
- **Temperature** — the fragile part. Apple changes SMC sensor keys every SoC.
  M5 specifically exposes GPU temp via new chip-specific keys (`Tg0U`, `Tg0X`,
  `Tg0d`, …) in **`flt`** (IEEE-float) format, and its IOHID sensors use generic
  `PMU tdie1..14` names — see https://github.com/aristocratos/btop/issues/1653
  for the M1/M2/M4/M5 key tables and the `flt` parser. Ship temp behind its own
  type with a per-SoC key map; return `nil` on unknown chips.

## Downstream consumer

Athena (`~/Source/Athena`) will add this as a SwiftPM dependency for **M60.3**
(see `~/Source/Athena/docs/m60-plan.md`) and surface `gpuClockMHz` on
`/healthz`. Keep the public API tiny and the failure mode graceful so a server
can depend on it safely.

## Definition of done (v1)

- [ ] `CIOReport` systemLibrary target links and imports.
- [ ] `SoCSampler.sample()` returns non-nil `gpuFrequencyMHz` on Apple Silicon.
- [ ] `asmetrics --watch` tracks `powermetrics` within a few % idle and loaded.
- [ ] Graceful `nil` (no crash) when IOReport is unavailable.
- [ ] Test asserting a sane GPU MHz range on this host.
- [ ] README "Status" flipped from scaffold → working; tag `v0.1.0`.

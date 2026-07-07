# SoCMetrics — implementation brief & roadmap

**SoCMetrics** (`swift-soc-metrics`) is a small MIT-licensed SwiftPM library that reads Apple Silicon SoC telemetry **sudoless** via the private `IOReport` framework (the same source `powermetrics` uses) — no root, no subprocess. Every metric is optional and returns `nil` (never crash/abort) when a channel or symbol is missing; these are private interfaces and must degrade cleanly. `sample(interval:)` never throws or traps.

The public surface stays tiny: one `SoCSampler` and one `SoCSample` value type. References ported from are MIT only — [macmon](https://github.com/vladkens/macmon) (Rust, primary), [mactop](https://github.com/metaspartan/mactop) (Go), [agtop](https://github.com/binlecode/agtop) (Python). No GPL sources (not `exelban/Stats`).

## Mechanism (the IOReport call sequence)

IOReport exposes hardware counters as "channels" grouped by name. The flow:

1. `IOReportCopyChannelsInGroup(group, nil, 0, 0, 0)` → CFDictionary of channels; `IOReportMergeChannels` to combine groups (we merge "GPU Stats" + "CPU Stats" + "Energy Model" into one subscription).
2. `IOReportCreateSubscription(nil, channels, &subbedChannels, 0, nil)`.
3. Snapshot A: `IOReportCreateSamples`; wait `interval`; snapshot B; `IOReportCreateSamplesDelta(A, B, nil)`.
4. `IOReportIterate`/walk the delta's `IOReportChannels` array — dispatch by `IOReportChannelGetGroup`/`SubGroup`/`ChannelName`.
   - **State (residency) channels** (GPU/CPU perf-states): `IOReportStateGetCount`, `…GetNameForIndex` ("IDLE"/"OFF"/"P1"…), `…GetResidency`. Effective MHz = Σ(residencyᵢ · freqᵢ) / Σ(active residency); active residency = Σ(active) / Σ(all).
   - **Simple (scalar) channels** (Energy Model): `IOReportSimpleGetIntegerValue` — an energy counter delta over the window; ÷ window and convert per the channel's `IOReportChannelGetUnitLabel` (mJ/µJ/nJ vary by chip) → watts.

The per-state frequency tables come from **IORegistry** `voltage-states*` blobs (packed little-endian `(freq, voltage)` `UInt32` pairs). See "DVFS tables" below — the encoding is chip-specific and was the main surprise of v0.2.

## Status

### v0.1.0 — GPU frequency + active residency ✅ shipped, tagged

- [x] `CIOReport` systemLibrary target links and imports (`libIOReport` from the dyld shared cache).
- [x] `SoCSampler.sample()` returns non-nil `gpuFrequencyMHz` on Apple Silicon.
- [x] `asmetrics --watch` tracks `powermetrics`'s "GPU HW active frequency" within a few % idle and loaded (exact match on M5 Max and M4 Max).
- [x] Graceful `nil` (no crash) when IOReport is unavailable.
- [x] Test asserting a sane GPU MHz range.
- [x] README "Status" flipped scaffold → working; tag `v0.1.0`.

### v0.2 — CPU cluster freqs + ANE/package power + review fixes ✅ implemented

- [x] **Review fix (a):** `SoCSampler.sample()` serialized with an `NSLock` (IOReport thread-safety is undocumented; a single subscription must not be sampled concurrently).
- [x] **Review fix (b):** the residency-weighting helper emits an `ASMETRICS_DEBUG` warning when the active-state count and the DVFS table length disagree (the previously-silent `min()` truncation).
- [x] **`cpuClusterFrequenciesMHz`** — `[String: Double]?` keyed by cluster channel name (`ECPU`/`PCPU`/`PCPU1` on M4, `MCPU0`/`MCPU1`/`PCPU` on M5). "CPU Stats" group, "CPU Complex Performance States" subgroup; reuses the GPU residency-weighting math.
- [x] **`anePowerWatts`** + **`packagePowerWatts`** — "Energy Model" scalar channels; package = CPU + GPU + ANE aggregate counters (matches `powermetrics`'s "Combined Power (CPU + GPU + ANE)"), picked by exact channel name so per-core/per-rail sub-counters are never double-summed.
- [x] Sane-range tests for the new fields; existing GPU tests still pass.
- [x] Validated vs `sudo powermetrics --samplers cpu_power,gpu_power` on **M4 Max Studio** (macOS 26.5.2): GPU freq exact (1578 = 1578 MHz loaded), package power within ~1% (57–58 W vs 56–58 W loaded), CPU E-cluster exact. **M5 Max** validated separately.

#### DVFS tables — the v0.2 gotcha (documented so v0.3 doesn't relearn it)

The GPU table is straightforward: `voltage-states9`, field-0 is frequency in **Hz** (÷1e6 → MHz), ascending. **CPU cluster tables are different and chip-specific:**

- The **frequency lives in the `-sram` variant** (`voltage-statesN-sram`), field-0. The non-sram `voltage-statesN` field-0 is a period-like value (descending, paired with ascending voltage) — do **not** use it as frequency.
- **Unit varies by generation:** M1–M3 store Hz, **M4/M5 store kHz**. We normalize by magnitude (≥1e8 → ÷1e6, ≥1e5 → ÷1e3) instead of a per-chip unit table, so a new SoC doesn't silently break.
- **Which `voltage-statesN` is which cluster is chip-specific:** M1–M4 use the fixed layout ECPU=`voltage-states1`, PCPU=`voltage-states5`. **M5+ renumbers** and enumerates clusters in the `acc-clusters` IORegistry blob (8-byte records; byte 0 = the cluster's voltage-states index). We read `acc-clusters` first and fall back to `[1, 5]` when it's absent.
- Clusters are matched to their table at sample time by **active-state count** (total residency states minus leading idle states == table length). A cluster with zero active residency reports its floor DVFS clock (where `powermetrics` prints 0).

## Validation recipe

```sh
swift run asmetrics --watch          # gpu_mhz, gpu_active, cpu_mhz[…], ane, pkg
# compare (needs root):
sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 4 \
  | grep -iE "HW active frequency|Combined Power|ANE Power"
```

Load with a Metal compute burn (see the v0.2 session's `gpuburn.swift`) plus a few busy CPU cores. `ASMETRICS_DEBUG=1` dumps every discovered channel (group/subgroup/name/states/unit/scalar), the loaded DVFS tables, and any active-state/table mismatch — the first thing to run when porting to a new SoC/OS.

### v0.3 — per-component die temperature ✅ implemented

Temperature is read from the **SMC**, not IOReport — a deliberate deviation from this brief's original "IOReport first" plan. Probing both hosts showed IOReport temperature does not work: M5 Max exposes **no** IOReport GPU-temperature channels at all (only ANE temp under `ANS2`), and M4 Max's `GPU Stats`/`Temperature`/`Tg*a` channels read back **0** through the documented `IOReportSimpleGetIntegerValue` accessor. The MIT reference `mactop` also reads temperature from SMC, not IOReport. Full rationale: [ADR 0001](docs/decisions/0001-die-temperature-from-smc-not-ioreport.md).

- [x] **`gpuTemperatureC`** / **`cpuTemperatureC`** (°C, optional, `nil` when sensors absent) — mean of the SMC `flt`-typed sensors by prefix (`Tg` = GPU, `Tp`/`Te` = CPU), matching `mactop`. Sudoless (SMC reads need no root).
- [x] **`SMCReader`** (`Sources/SoCMetrics/SMC.swift`) — opens the `AppleSMC` user-client, enumerates its `flt` temperature keys once at init (**pattern-match, no per-chip key table that rots**), re-reads their values each sample. `SMCKeyData_t` + selector added to the existing `CIOReport` header; **Package.swift unchanged** (no new target).
- [x] `ASMETRICS_DEBUG=1` now also enumerates every IOReport channel (`IOReportCopyAllChannels`) and prints the thermal-looking ones — the aid that surfaced the M4-vs-M5 difference.
- [x] Sane-range temperature test; v0.1/v0.2 fields not regressed (verified on both hosts).
- [x] Validated on **M5 Max** (≈44 °C idle → ≈72 °C under a Metal burn, GPU 100 % / 58 W) and **M4 Max Studio** (≈35 °C idle → ≈54 °C, 1578 MHz / 38 W). `powermetrics` reports no absolute die temp on Apple Silicon (only a "Nominal" thermal-*pressure* level), so validation is the `Tg`-spread + load-tracking, which this brief permits.

Deferred (ponytail): the IOHID `PMU tdie`/`pACC`/`eACC` fallback (`mactop`'s secondary path) — SMC `flt` sensors cover M1–M5; add it only if a future chip lacks them. See [btop #1653](https://github.com/aristocratos/btop/issues/1653) for the key lineage.

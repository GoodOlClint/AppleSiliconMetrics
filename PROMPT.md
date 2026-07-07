# AppleSiliconMetrics — implementation brief & roadmap

**AppleSiliconMetrics** is a small MIT-licensed SwiftPM library that reads Apple Silicon SoC telemetry **sudoless** via the private `IOReport` framework (the same source `powermetrics` uses) — no root, no subprocess. Every metric is optional and returns `nil` (never crash/abort) when a channel or symbol is missing; these are private interfaces and must degrade cleanly. `sample(interval:)` never throws or traps.

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

## Downstream consumer

Athena (`~/Source/Athena`) adds this as a SwiftPM dependency for **M60.3** (`~/Source/Athena/docs/m60-plan.md`) and surfaces `gpuClockMHz` on `/healthz`. Keep the public API tiny and the failure mode graceful so a server can depend on it safely.

## Validation recipe

```sh
swift run asmetrics --watch          # gpu_mhz, gpu_active, cpu_mhz[…], ane, pkg
# compare (needs root):
sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 4 \
  | grep -iE "HW active frequency|Combined Power|ANE Power"
```

Load with a Metal compute burn (see the v0.2 session's `gpuburn.swift`) plus a few busy CPU cores. `ASMETRICS_DEBUG=1` dumps every discovered channel (group/subgroup/name/states/unit/scalar), the loaded DVFS tables, and any active-state/table mismatch — the first thing to run when porting to a new SoC/OS.

## Next: v0.3 — temperature (its own kickoff)

Temperature is the fragile part historically (Apple churns SMC sensor keys every SoC). **New in macOS 26: GPU die temperature is exposed as IOReport channels**, which may make the per-SoC SMC key tables unnecessary for the GPU — so try IOReport first, SMC keys only as fallback.

- **Primary — IOReport "GPU Stats" → subgroup "Temperature":** channels `Tg1a … Tg61a` (observed on M4 Max), each a state/scalar with `Latest`/`Sum`/`Min`/`Max`. Read the same way as the other IOReport channels (no root). Reduce the per-sensor `Latest` values to a representative GPU die temp (max, or mean of the hottest cluster). Verify the exact strings at runtime with `ASMETRICS_DEBUG=1` — expect drift across M-series and macOS versions. Likely a matching "CPU Stats"/SoC subgroup exists too; discover it the same way.
- **Fallback — SMC keys** (only if IOReport temp is absent on a chip): per-SoC key map, `nil` on unknown chips. M5 exposes GPU temp via new chip-specific keys (`Tg0U`, `Tg0X`, `Tg0d`, …) in **`flt`** (IEEE-float) format; its IOHID sensors use generic `PMU tdie1..14` names. Key tables + the `flt` parser: https://github.com/aristocratos/btop/issues/1653 (M1/M2/M4/M5). This is the last resort — it needs a new SMC-reader shim and a per-chip table that rots; prefer IOReport.
- Ship temp behind its own optional field(s) with graceful `nil`; do not regress the v0.1/v0.2 fields. Validate the GPU die temp against `sudo powermetrics --samplers thermal` and/or the `Tg`-channel spread on M5 Max and M4 Max.

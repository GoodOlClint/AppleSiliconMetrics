# ADR 0001 — Read die temperature from SMC, not IOReport

- **Status:** Accepted
- **Date:** 2026-07-07
- **Deciders:** operator + agent
- **Context source:** v0.3 session (per-component temperature); PROMPT.md "Next: v0.3 — temperature"

## Context

The v0.3 brief (PROMPT.md) specified "IOReport first, SMC fallback" for GPU die temperature, on the hypothesis that macOS 26 exposes GPU temperature as IOReport channels (`GPU Stats`/`Temperature`/`Tg1a…`, observed on M4 Max) — which "may make the per-SoC SMC key tables unnecessary." Runtime probing of both target hosts contradicted the hypothesis:

- **M5 Max** (this host) exposes **no** IOReport GPU-temperature channels at all. Enumerating every channel via `IOReportCopyAllChannels` finds only ANE temperature (`ANS2`/`MSPx`/`Temperature`) — nothing for the GPU or CPU die. So IOReport cannot report GPU die temperature on M5, and SMC is mandatory there regardless.
- **M4 Max** (studio) does have the `GPU Stats`/`Temperature`/`Tg*a` channels, but every one reads back **0** through `IOReportSimpleGetIntegerValue` (the accessor used for all other scalar channels), in both a raw sample and a delta. No working accessor for these gauge channels was found.
- The MIT reference **mactop** — one of the projects PROMPT.md sanctions porting from — reads temperature from **SMC, not IOReport** ("IOReport is NOT used for temperature"): it filters `flt`-typed SMC keys by prefix (`Tg` = GPU, `Tp`/`Te` = CPU) and averages each group.
- SMC sensor reads are **unprivileged** (only writes need root) and work sudoless on both hosts. Discovering keys by prefix-match over an enumeration needs **no per-chip key table** — which removes the very "SMC tables rot" concern that motivated preferring IOReport.

## Decision

Read die temperatures from the **AppleSMC user-client** (`SMCReader`), not IOReport. Enumerate the SMC keys once at sampler init, keep the `flt`-typed (IEEE-float, °C) sensors whose 4-char code starts with `Tg` (GPU) or `Tp`/`Te` (CPU P-/E-cores), and each sample re-read those keys and reduce each group by **mean** (matching mactop). Surface `SoCSample.gpuTemperatureC` and `.cpuTemperatureC`, both optional and `nil` when no readable sensors exist. There is **no IOReport temperature path**.

## Rejected alternatives

- **IOReport-first, SMC fallback (the PROMPT's plan).** No working IOReport temperature accessor was found (M4 channels read 0), and M5 has no channels at all — so IOReport adds code and zero host coverage. The efficiency rationale (avoid rotting SMC tables) is moot: the SMC path uses pattern-enumeration, not a table.
- **Per-SoC SMC key table** (`Tg0U`/`Tg0X`/… hard-coded per chip). Rots every generation; the brief itself called it "a last resort." Prefix-match over enumeration is chip-agnostic (verified against M4's `Tg0z…` and M5's `Tg0U…` sets).
- **`max` reduction** (hottest sensor). mactop uses `mean`; on both hosts the per-sensor spread is tight (M5 idle: mean 47.6 vs max 49.2 °C) so it barely differs. Matching the reference is the lazy, defensible choice; revisit if a throttle-relevant hotspot metric is wanted.
- **HID `PMU tdie`/`pACC`/`eACC` fallback** (mactop's secondary path). Deferred: SMC `flt` sensors are present on M1–M5. Add only if a future chip exposes temperature via IOHID but not SMC.

## Consequences

- Temperature is a new sudoless kernel-interface dependency (`AppleSMC` via `IOKit`), added to the existing `CIOReport` header (`SMCKeyData_t` + selector) with **no new SwiftPM target** — Package.swift is unchanged.
- Init enumerates all SMC keys (~3600) once (~tens of ms); each sample re-reads only the cached temperature keys (~40–110 per host). Acceptable for the expected low sample cadence.
- `IOReportCopyAllChannels` is retained and wired into the `ASMETRICS_DEBUG` dump (`dumpThermalChannels`) — the porting aid that surfaced the M4-vs-M5 difference.
- `powermetrics` reports no absolute die temperature on Apple Silicon (only a "Nominal" thermal-*pressure* level), so validation is by the `Tg`-channel spread and load-tracking (M5: 44 → 72 °C idle → Metal burn; M4: 35 → 54 °C), which PROMPT.md explicitly permits.
- If a future SoC drops the `flt` `Tg`/`Tp`/`Te` sensors, temperature degrades to `nil` (contract-preserving); the HID fallback above is the documented next step.

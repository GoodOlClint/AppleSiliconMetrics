---
name: Bug report
about: Wrong/missing metrics or a crash on your machine
---

**Chip and OS** (e.g. M2 Pro, macOS 15.5 — `sysctl -n machdep.cpu.brand_string; sw_vers -productVersion`):

**What happened** (wrong frequency, `n/a`, crash, …):

**Debug output** — IOReport is a private, version-fragile framework, so this is usually the whole diagnosis:

```
ASMETRICS_DEBUG=1 swift run asmetrics
(paste output here)
```

**If the frequency looks wrong**, the matching `powermetrics` reading:

```
sudo powermetrics --samplers gpu_power -n 1 | grep "GPU HW active"
```

# Glasstop

A lightweight native macOS system monitor in a floating, always-on-top window — a btop
replacement that never freezes. Swift + AppKit/SwiftUI, no dependencies, every metric from a
direct syscall or IOKit call. See [PLAN.md](PLAN.md) for the spec and [PROGRESS.md](PROGRESS.md)
for status.

```bash
swift build                     # debug build
swift run                       # run from terminal
./scripts/bundle.sh             # release .app in build/
./scripts/bundle.sh --install   # …and copy it to /Applications
open build/Glasstop.app
```

Glasstop runs as an accessory app (no Dock icon) so it can float over other apps'
fullscreen Spaces. Its handle is the **menu bar item** showing CPU %: click to show/hide the
window, right-click for options. Closing the window hides it; quit from the menu (⌘Q).

| Shortcut | Action |
|---|---|
| ⌘T | Keep on top (all Spaces, incl. fullscreen apps) |
| ⌘1 / ⌘2 | Full / compact mode (each remembers its own size) |
| ⌘F | Focus the process filter |
| − / + (header) | Refresh interval in 100 ms steps (hold to repeat, ⌥-click for 1 s), 100 ms–5 s, default 1000 ms |
| ⌘, | Settings (refresh interval, history length, process refresh, launch at login, hotkey) |
| ⌃⌥⌘M | Show/hide from anywhere (optional global hotkey, off by default) |

Status menu: opacity slider and click-through (the window ignores the mouse; turn it off from
the menu bar item). Process table: right-click for Copy PID / Copy Path / Reveal in Finder /
Terminate / Force Kill; the filter button has only-my-processes, hide-idle and tree view.
Filter text, sort order and column layout persist. The net panel's title is a dropdown: all Wi-Fi/Ethernet adapters
(default) or one interface (adapters by name, plus VPN tunnels and VM bridges).

Other scripts: `swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`;
`scripts/soak.sh [hours] [interval_min]` runs the reliability soak (results in `soak/`).

## Accuracy check (M1)

Measured 2026-10-19 on an **Apple M5 Pro** (18 logical CPUs: 6 Super + 12 Performance,
48 GB), **macOS 27.0.1 (26A434)**, release build. Reference tools ran over the same window as
Glasstop's readers (harness: the app's own `CPUReader`, `MemoryReader`, `ProcessReader`).

| Metric | Glasstop | Reference | Result |
|---|---|---|---|
| Total CPU | 11.4% | `top` 9.9% (2.96 user + 6.91 sys) | within ~1.5 points (windows offset by a few ms) |
| Process CPU, busy `yes` | 99.9% | kernel CPU-time delta via `ps`: 99.9%; `top`: 99.8–99.9% | ✅ timebase conversion correct (not 41× off) |
| Process CPU, other apps | e.g. 6.5 / 2.0 / 1.7% | `top` | ✅ match `top`'s steady-state samples* |
| Memory Used | 30.23 GB = app 18.50 + wired 4.88 + compressed 6.85 | `top`: 4995M wired, 7013M compressor | ✅ wired/compressed match; Used = Activity Monitor's definition |
| Memory column | e.g. 1.08 GB, 707 MB, 652 MB | `footprint` tool 1109 / 707 / 652 MB; `top` MEM | ✅ (see note on VM hosts) |
| Tick cost (header) | ~7 ms on process ticks (every 2nd), < 0.1 ms otherwise; ~1,030 processes | budget < 5 ms | wall time on utility-QoS (low-clock) cores; process sampling is syscall-bound (`__proc_info` ≈ 93%) |

\* `top -l` under-reports its **first** interval (68–86% for a process that is really at
100%); every later `top` sample agrees with Glasstop.

Notes:
- The Memory column is the kernel's `phys_footprint` ledger — the same value `top` (MEM) and
  Activity Monitor show. The `footprint` CLI sums VM regions instead and misses
  hypervisor-owned memory, so for VM hosts (e.g. OrbStack Helper: Glasstop 2.9 GB, `top` 3031M,
  `footprint` 288 MB) it reads much lower.
- Other users' processes (root daemons, WindowServer) show "—" for CPU/memory/threads: their task
  info needs privileges.
- The first process sample isn't published (every CPU % would be 0), so the table never flashes
  a meaningless sort order.
- Per-core CPU uses the same `host_processor_info` tick counters as the total (the total is the
  tick-weighted aggregate of all cores).

## Where the numbers come from

| Metric | Source |
|---|---|
| CPU total / per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas |
| Core groups (Super / Performance) | `IODeviceTree:/cpus/cpuN` `cluster-type` + `hw.perflevelN.name` |
| Memory | `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage` |
| Processes | `proc_listallpids`, `proc_pidinfo(PROC_PIDTASKALLINFO)`, `proc_pid_rusage`, `proc_pidpath` |
| GPU utilization | IOAccelerator `PerformanceStatistics` → `Device Utilization %` |
| Temperatures | AppleSMC float keys (`Tp*` Super cluster, `Tm*` Performance cluster, `Tg*` GPU, `TB*T` battery); HID `PMU tdie*` fallback |
| Network | sysctl `IFMIB_IFDATA` (`ifmibdata`, 64-bit counters) for `en*` interfaces — `NET_RT_IFLIST2` byte counters come back truncated to 32 bits on macOS 27 |
| Disk throughput | IOKit `IOBlockStorageDriver` → `Statistics` → `Bytes (Read)` / `Bytes (Write)` |
| Volume usage | `getfsstat(MNT_NOWAIT)` to list mounts, `statfs` on local browsable volumes only (a hung network mount can't block sampling) |
| Load average / uptime | `getloadavg`, `kern.boottime` |

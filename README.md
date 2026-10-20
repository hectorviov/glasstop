# Glasstop

A lightweight native macOS system monitor in a floating, always-on-top window — a btop
replacement that never freezes. Swift + AppKit/SwiftUI, no dependencies, every metric from a
direct syscall or IOKit call. See [PLAN.md](PLAN.md) for the spec and [PROGRESS.md](PROGRESS.md)
for status.

## Install

Download the latest `Glasstop-x.y.z.dmg` from
[Releases](https://github.com/hectorviov/glasstop/releases/latest), open it and drag Glasstop
to the Applications shortcut. Needs an Apple silicon Mac with macOS 14 Sonoma or later.

Release builds are ad-hoc signed, not notarized, so macOS blocks the first launch: open the app
once, then click **Open Anyway** in System Settings → Privacy & Security (or run
`xattr -dr com.apple.quarantine /Applications/Glasstop.app`).

## Build from source

```bash
swift build                     # debug build
swift run                       # run from terminal
./scripts/bundle.sh             # release .app in build/
./scripts/bundle.sh --install   # …and copy it to /Applications
./scripts/make-dmg.sh           # drag-to-install disk image in build/ (needs: pip install dmgbuild)
open build/Glasstop.app
```

Glasstop is a regular Dock app. Closing the window keeps it running; click the Dock icon to bring
it back (that also turns click-through off). Quit with ⌘Q. Keep on Top floats the window above
other windows on every desktop (macOS doesn't let a Dock app's windows over other apps'
fullscreen Spaces).

| Shortcut | Action |
|---|---|
| ⌘T | Keep on top (all desktops) |
| ⌘1 / ⌘2 | Full / compact mode (each remembers its own size) |
| ⌘F | Focus the process filter |
| − / + (header) | Refresh interval in 100 ms steps (hold to repeat, ⌥-click for 1 s), 100 ms–5 s, default 1000 ms |
| ⌘, | Settings (refresh interval, history length, process refresh, launch at login, hotkey) |
| ⌃⌥⌘G | Show/hide from anywhere (optional global hotkey, off by default) |

Window menu: opacity (also a slider in Settings) and click-through (the window ignores the
mouse; click the Dock icon to turn it off). Process table: right-click for Copy PID / Copy Path / Reveal in Finder /
Terminate / Force Kill; click GPU% to sort by GPU use; the **lazy** checkbox
next to the filter makes the CPU% sort work like btop's "cpu lazy" (by each process's lifetime
average CPU, with processes busy right now pulled to the top), so rows don't reshuffle every
refresh; the filter button has only-my-processes, hide-idle and tree view.
Filter text, sort order and column layout persist. The net panel's title is a dropdown: all Wi-Fi/Ethernet adapters
(default) or one interface (adapters by name, plus VPN tunnels and VM bridges).

## Contributing and releases

`main` is protected: changes land through pull requests, and the **CI** workflow (release build
with warnings as errors, plus the app bundle) has to pass first.

To publish a release, tag a commit on `main` and push the tag:

```bash
git tag v0.9.1 && git push origin v0.9.1
```

The **Release** workflow builds `Glasstop.app` stamped with that version, packs it into a
drag-to-Applications disk image (`scripts/make-dmg.sh`, layout in `scripts/dmg-settings.py`)
with a SHA-256 checksum and publishes a GitHub release with notes generated from the merged pull requests.
A tag with a suffix (`v1.0.0-beta.1`) becomes a pre-release. Running the workflow by hand
(Actions → Release → Run workflow) makes a draft release instead, which only you can see.

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
| Process GPU % | IOAccelerator's Metal clients (`AGXDeviceUserClient`): `IOUserClientCreator` pid + `AppUsage` → `accumulatedGPUTime` (ns) deltas, like Activity Monitor's % GPU; readable for every user's processes |
| Temperatures | AppleSMC float keys (`Tp*` Super cluster, `Tm*` Performance cluster, `Tg*` GPU, `TB*T` battery); HID `PMU tdie*` fallback |
| Network | sysctl `IFMIB_IFDATA` (`ifmibdata`, 64-bit counters) for `en*` interfaces — `NET_RT_IFLIST2` byte counters come back truncated to 32 bits on macOS 27 |
| Disk throughput | IOKit `IOBlockStorageDriver` → `Statistics` → `Bytes (Read)` / `Bytes (Write)` |
| Volume usage | `getfsstat(MNT_NOWAIT)` to list mounts, `statfs` on local browsable volumes only (a hung network mount can't block sampling) |
| Load average / uptime | `getloadavg`, `kern.boottime` |

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attributions (the Lazy CPU sort is
adapted from [btop](https://github.com/aristocratos/btop)).

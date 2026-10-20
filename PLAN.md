# Glasstop — Plan

A lightweight native macOS system monitor in a floating, always-on-top window.
It replaces btop, which freezes after a while. It should look better and be easier to read than a terminal UI.

## Goals

- A native Swift app with no dependencies: a small binary (~2–5 MB) that uses little RAM (target < 80 MB footprint).
- It refreshes every **0.5 s** with live graphs for:
  - total CPU %
  - CPU % per core
  - memory (used, plus a breakdown)
  - temperatures (CPU summary plus a list of all sensors)
- A process table you can sort and filter: PID, name, user, threads, memory, CPU %.
- The window stays on top of everything, including fullscreen apps and every Space, and you can toggle that.
- **It never freezes.** All sampling runs off the main thread, history buffers have a fixed size, and the UI shows when sampling has stalled.

## Hard rules

- Use only system frameworks: no third-party Swift packages, no Electron, no webviews.
- Don't shell out to `top`, `ps`, `powermetrics`, or similar. Every metric comes from a direct syscall or IOKit.
- Never sample on the main thread. Readers run on the sampler's serial queue and only publish to `@Observable` state on main.
- Every buffer is bounded. Memory must stay flat over a 24 h run.
- The package uses Swift 5 language mode (tools 5.9). If you move to Swift 6 strict concurrency, do it on purpose and keep the same threading model.
- Target macOS 14+ on Apple Silicon. The dev machine is an M5 Pro with 18 logical CPUs and 48 GB RAM.

## Current state (scaffold)

**This scaffold was written without a compiler. It has never been built.** Expect a few compile errors. Fixing them is the first task (M0).

```
Package.swift                  SwiftPM: CSensors (C) + Glasstop (executable)
Resources/Info.plist           Used by scripts/bundle.sh
scripts/bundle.sh              Release build → build/Glasstop.app (ad-hoc signed)
Sources/CSensors/              C shim over the private IOHIDEventSystemClient API (temps)
Sources/Glasstop/
  App/GlasstopApp.swift        @main, NSApplication bootstrap
  App/AppDelegate.swift        NSPanel (floating, all Spaces), main menu, ⌘T toggle
  Model/Models.swift           CPUReading, MemoryReading, ProcessRow, SystemInfo, Snapshot…
  Model/RingBuffer.swift       Fixed-capacity history
  Model/AppState.swift         alwaysOnTop (persisted in UserDefaults)
  Sampling/Sampler.swift       DispatchSourceTimer on a background queue → publishes on main
  Sampling/CPUReader.swift     host_processor_info tick deltas (total + per core)
  Sampling/MemoryReader.swift  host_statistics64 + vm.swapusage
  Sampling/ProcessReader.swift libproc: proc_listallpids, PROC_PIDTASKALLINFO, proc_pid_rusage
  Sampling/TemperatureReader.swift  Wraps CSensors and classifies CPU sensors (heuristic)
  Sampling/Sysctl.swift        sysctl and C-string helpers
  Views/…                      ContentView (VSplitView), HeaderBar + StaleBadge, CPUCard,
                               CoreGridView (Canvas sparklines), MemoryCard, TemperatureCard,
                               ProcessTableView (SwiftUI Table + filter)
```

### Data flow

`Sampler.tick()` runs on the background queue every 0.5 s:

1. It builds a `Snapshot`. CPU and memory are sampled every tick. Processes and temperatures are sampled every 2nd tick (1 s), and sensors are re-discovered every 60 s.
2. It hands the snapshot to `DispatchQueue.main.async { apply(snapshot) }`.
3. `apply` updates the published state and appends to the ring buffers (240 points = 2 min).

SwiftUI views each read only the properties they use through `@Environment(Sampler.self)`.

### Data sources

| Metric | API | Notes |
|---|---|---|
| CPU total / per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | Delta of user+system+nice vs idle ticks. `mach_host_self()` is cached because it leaks a port right on every call. |
| Core topology | `sysctl hw.nperflevels`, `hw.perflevelN.{name,logicalcpu}` | Shown in the header. The mapping from CPU index to perf level is **not yet verified**. |
| Memory | `host_statistics64(HOST_VM_INFO64)` | used = app (internal − purgeable) + wired + compressed. This should match Activity Monitor's "Memory Used". |
| Swap | `sysctl vm.swapusage` | |
| Processes | `proc_listallpids`, `proc_pidinfo(PROC_PIDTASKALLINFO)`, `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`, `proc_pidpath` | CPU time is in **mach absolute units** and is converted with `mach_timebase_info`. Other users' processes only return BSD info, so they're shown with "—". |
| Temperatures | Private `IOHIDEventSystemClient` (usage page 0xff00, usage 5) in C | May be incomplete on M5. See M2. |
| Load average | `getloadavg` | |

## Milestones

### M0 — Build and run
- Run `swift build` and fix compile errors. Keep the design: don't swap the APIs for shell commands.
- Run `swift run`. A floating window titled Glasstop should appear and update every 0.5 s.
- Run `./scripts/bundle.sh`, then `open build/Glasstop.app`.
- **Done when:** both commands work, the window stays above other apps (including fullscreen), ⌘T toggles that, and the filter field accepts ⌘V.

### M1 — Check the numbers
- Compare with Activity Monitor and `top -o cpu -s 1`:
  - Total CPU and per-core CPU are within a few %.
  - Memory Used matches Activity Monitor.
  - Process CPU % matches `top`. If it's off by roughly 41×, the timebase conversion is wrong.
  - The Memory column ≈ Activity Monitor's Memory column (footprint).
- Make sure the first process sample (CPU 0 for every process) doesn't flash odd sort orders. If it does, skip publishing processes until the second sample.
- **Done when:** all of the above match, and these are noted in the README: the values, the macOS version, and the tick cost (shown in the header in ms).

### M2 — Temperatures on M5 Pro
- Add a temporary debug dump that prints every HID sensor name and value. Check which ones are CPU die sensors.
- If HID gives good CPU readings, refine `TemperatureReader.isCPUSensor` and `isExcluded`.
- If HID doesn't, add an **SMC reader**. Use `AppleSMC` through `IOServiceOpen` and `IOConnectCallStructMethod`, with keys like `Tp0*` / `Te0*`; enumerate keys on M5 to confirm. References:
  - exelban/stats — Modules/Sensors
  - btop's macOS sensors code (`src/osx/sensors.cpp`, `smc.cpp`)
- Run temperature reads on **their own queue with a timeout**, so a hung IOKit call can never stall CPU and memory sampling. This is a likely cause of btop's freezes.
- Show per-core temperatures only if there's a reliable sensor-to-core mapping. Otherwise show a CPU avg/max plus GPU and SoC readings if they're available.
- **Done when:** the CPU temperature card shows plausible values that react to load (try `yes > /dev/null` × N).

### M3 — Core topology and visuals
- Check how CPU indices map to perf levels on M5 Pro. One way: load one cluster and watch the indices. Another is `sysctl hw.perflevel*.cpusperl2` plus `hw.cacheconfig`.
- Group the core grid by perf level, give each level its own color, and show an average per group.
- Polish:
  - transparent titlebar with `.fullSizeContentView`
  - a vibrancy or material background
  - smoother color gradient for load
  - a tooltip on hover for exact values in `HistoryChart`

### M4 — Window UX
- **Compact mode:** just the charts, no table. Toggle with ⌘1/⌘2. Remember the size of each mode.
- Window opacity slider, plus an optional click-through mode (`ignoresMouseEvents`) with a menu item to exit it.
- ⌘F focuses the filter. Remember the sort order and filter.
- Optional menu bar item (`NSStatusItem`) that shows CPU %. Clicking it shows or hides the panel.
- Optional global hotkey to show or hide the panel.

### M5 — Process actions
- Context menu: Copy PID, Copy Path, Reveal in Finder, Terminate (SIGTERM), and Force Kill (SIGKILL, with confirmation).
- "Only my processes" toggle, and an option to hide processes with zero CPU and zero memory.
- Optional tree view (ppid from `pbi_ppid`).

### M6 — Settings
- Refresh interval (0.25 / 0.5 / 1 / 2 s), history length, and process refresh rate.
- Launch at login with `SMAppService.mainApp`.

### M7 — Reliability soak
- Run for 24 h, including several sleep/wake cycles.
- Watch `NSWorkspace.didWakeNotification` and reset the readers on wake: call `temperatureReader.reset()` and clear the CPU and process baselines.
- Measure:
  - `footprint Glasstop` at the start and after 24 h. It should be flat.
  - `leaks Glasstop` should report 0 leaks.
  - Average CPU should be < 1% of one core, measured with `top -pid <pid> -stats cpu`.
- **Done when:** the stall badge never turned red and memory didn't grow.

### M8 — Packaging
- App icon and version bump in Info.plist. Install to /Applications through `bundle.sh`.
- Optional: generate an Xcode project with XcodeGen if Xcode-specific tooling is needed.
- Optional later: Developer ID signing and notarization.

### Later / optional
- GPU utilization from the IOKit `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`.
- Network and disk throughput.

## Performance budget

| Item | Target |
|---|---|
| Tick cost (shown in header) | < 5 ms typical, with ~1,100 processes |
| App CPU | < 1% of one core on average at 0.5 s |
| Footprint | < 80 MB, flat over 24 h |
| Binary | < 5 MB |

If the process table gets expensive, try these in order:

1. Refresh it less often.
2. Diff the rows.
3. Sort only the visible rows.
4. Skip `proc_pid_rusage` for processes using under 0.1% CPU and reuse their last footprint.

## Commands

```bash
swift build                 # debug build
swift run                   # run from terminal
./scripts/bundle.sh         # release .app in build/
open build/Glasstop.app
```

## Known risks and open questions

- **The private HID API may break or return little data on new chips** → SMC fallback (M2).
- **CPU index → P/E core mapping is unverified** (M3).
- **Other users' processes** (root daemons) have no CPU or memory data without a privileged helper. That's acceptable; they're shown with "—".
- **PID reuse** is handled by keying baselines on (pid, start time).
- **`NSPanel` + SwiftUI `Table` focus:** if typing in the filter doesn't work while the panel floats, check `canBecomeKey` and avoid `.nonactivatingPanel`.

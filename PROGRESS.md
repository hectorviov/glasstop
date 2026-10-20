# Glasstop — Progress log

Companion to PLAN.md (the spec). Update this file at the end of every work session.
The project is a git repo now (local only, never pushed): `git log --oneline` shows each step.

## ☀️ Morning summary (2026-10-20)

**All milestones M0–M8 are implemented and committed.** The 24 h soak (M7) started
at 23:44 and is still running (7 h so far: 54–64 MB, no growth, no stalls, leaks flat) — see "Soak" below; don't quit Glasstop if you want a clean 24 h
run (if you do, the script keeps logging the new instance, but stall counts stop).

What changed overnight, in one line each:
- **Lighter:** footprint 156 MB → ~50–58 MB; CPU ~6.9% → ~4.9% visible at the default 0.5 s,
  ~1.3% when hidden/covered, ~2.8% at 1 s / 2 s refresh. Tick cost 85 ms → ~6 ms.
- **Correct:** numbers checked against `top`/`ps`/`footprint` (README "Accuracy check"); fixed a
  bug where ~335 system processes (root, daemons) were missing from the table.
- **New:** menu bar item (CPU %), compact mode ⌘1/⌘2, opacity, click-through, ⌘F, context menu
  (copy/reveal/terminate/force kill), tree view, only-mine / hide-idle filters, Settings (⌘,),
  optional global hotkey ⌃⌥⌘M, app icon, `bundle.sh --install`.
- **Look:** transparent titlebar, frosted background, per-cluster colors, hover values on graphs.

### Please try / verify (I couldn't headlessly)
1. **Menu bar item**: left-click hides/shows, right-click opens the menu (opacity slider,
   click-through, compact, settings). I verified it exists and shows "CPU 15%", not the clicks.
2. **Hover** a history graph (CPU, memory, temperature): marker + "42.1% · 35 s ago" label.
3. **Right-click** a process row: menu actions. (The kill path itself is tested: it re-checks
   pid + start time, so a reused pid is never signalled.)
4. **Global hotkey**: enable in Settings, press ⌃⌥⌘M. It registered without conflicts here.
5. **Sleep/wake**: after wake, CPU/process numbers should not spike and temps should resume.
6. **Your call**: `./scripts/bundle.sh --install`, Launch at login (Settings), Developer ID signing.
7. Note: **Keep on Top is currently OFF** in your saved settings (it was off when I started
   tonight's session; I left it). ⌘T or the pin button turns it on.

## Decisions to review
- **CPU budget "< 1% of one core at 0.5 s" isn't reachable with this design.** Sampling alone is
  ~1.1–1.3%; redrawing ~100 changing labels + graphs at 2 Hz costs ~3–3.5% more while visible.
  Measured (M6), all with the window visible:

  | UI refresh / process refresh | CPU | Footprint |
  |---|---|---|
  | 0.5 s / 1 s (default) | 4.9% | 59 MB |
  | 0.5 s / 2 s | 4.3% | 57 MB |
  | 1 s / 1 s | 3.4% | 52 MB |
  | 1 s / 2 s | 2.8% | 50 MB |

  Hidden/minimized/covered: ~1.3% at any setting (SwiftUI isn't updated at all). I kept
  0.5 s / 1 s as defaults (the plan and your btop setup); change them in Settings.
- **Accessory app (no Dock icon / ⌘Tab)** — required for floating over fullscreen apps. The menu
  bar item is therefore always present (it's the way back from click-through/hidden). Closing the
  window hides it; quit from the menu bar item or ⌘Q.
- **Temperatures from SMC key families**, mapped by load tests: `Tp*` Super cluster, `Tm*`
  Performance cluster, `Tg*` GPU, `TB*T` battery. 16 keys/s round-robin → each sensor refreshes
  every ~7 s (~0.25% CPU). Shown per cluster (avg; max in the sensors panel), not per core — there's
  no reliable sensor→core mapping. HID `PMU tdie*` is the fallback (0.75 ms/sensor, 5× slower).
- **App Nap opt-out** (`userInitiatedAllowingIdleSystemSleep`) so a covered window doesn't
  throttle sampling / the menu bar CPU %. The system can still idle-sleep.
- **Global hotkey** default off; combination ⌃⌥⌘M (Carbon `RegisterEventHotKey`, no permission).
- **Version 0.9.0** (not 1.0) until the soak and your review are done.
- **Leaks**: `leaks` reports ~414 "leaks" (~20 KB), all three copies of one Apple App Intents XPC
  cycle (`LNDaemonApplicationInterface`, created at launch; linkd is unreachable). None are
  Glasstop allocations; the soak tracks that the count stays flat.

## Soak (M7) — running
`scripts/soak.sh 24 30` → `soak/soak-20261019-2344.csv` (footprint, CPU, leaks every 3rd row,
stalls). Sleep/wake cycles are for you (the stall detector measures uptime, so sleep doesn't count).

| Time | Footprint | CPU | Leaks | Stalls |
|---|---|---|---|---|
| 2026-10-19 23:45 | 58.0 MB | 5.70% | 414 | 0 |
| 2026-10-20 00:15 | 63.0 MB | 5.65% | — | 0 |
| 2026-10-20 00:45 | 59.0 MB | 5.40% | — | 0 |
| 2026-10-20 01:16 | 61.0 MB | 5.69% | 414 | 0 |
| 2026-10-20 01:46 | 64.0 MB | 5.59% | — | 0 |
| 2026-10-20 02:17 | 59.0 MB | 5.73% | — | 0 |
| 2026-10-20 02:47 | 60.0 MB | 5.71% | 414 | 0 |
| 2026-10-20 03:17 | 60.0 MB | 5.81% | — | 0 |
| 2026-10-20 03:48 | 59.0 MB | 5.56% | — | 0 |
| 2026-10-20 04:18 | 59.0 MB | 5.63% | 414 | 0 |
| 2026-10-20 04:48 | 54.0 MB | 5.92% | — | 0 |
| 2026-10-20 05:19 | 57.0 MB | 5.83% | — | 0 |
| 2026-10-20 05:49 | 57.0 MB | 5.71% | 414 | 0 |
| 2026-10-20 06:20 | 57.0 MB | 5.79% | — | 0 |
| 2026-10-20 06:50 | 58.0 MB | 5.80% | — | 0 |

## Milestones
- **M0 — Build and run: DONE.** Floats over fullscreen apps (accessory policy), ⌘T toggles,
  ⌘V/⌘A work in the filter.
- **M1 — Check the numbers: DONE.** README "Accuracy check". Total CPU within ~1.5 points of `top`;
  process CPU = kernel CPU-time delta (99.9% for a busy `yes`) and `top`'s steady-state samples
  (`top -l`'s first interval reads low); memory used/wired/compressed match; Memory column =
  kernel `phys_footprint` like `top`/Activity Monitor (the `footprint` CLI reads lower for VM hosts).
- **M2 — Temperatures: DONE.** SMC reader (C, `smc.c`) on its own queue; stale badge in the sensors
  panel if reads stop. Under 18× `yes` load: Super 40 → 55 °C, Performance 39 → 54 °C, GPU 41 → 49 °C.
- **M3 — Topology & visuals: DONE.** Core map from `IODeviceTree:/cpus` (C0–C11 Performance "M",
  C12–C17 Super "P"); grouped with per-group colors and averages; transparent titlebar; frosted
  material; smooth load/heat gradients; hover values; nothing clips at the minimum size (860×708).
- **M4 — Window UX: DONE.** Menu bar item, compact mode with per-mode frames, opacity,
  click-through, ⌘F, persisted filter/sort/columns, optional global hotkey.
- **M5 — Process actions: DONE.** Context menu, only-mine, hide-idle, tree view. Fixed: other
  users' processes now come from one `KERN_PROC_ALL` sysctl (`PROC_PIDTBSDINFO` is refused for
  them, so they were silently dropped).
- **M6 — Settings: DONE.** Refresh 0.25/0.5/1/2 s, history 1–10 min, process refresh 0.5–5 s
  (applied live; history capped at 2,400 points), launch at login (SMAppService; not enabled).
- **M7 — Reliability: IN PROGRESS (soak running).** Wake reset of CPU/process baselines and
  sensors; stall logging; App Nap opt-out; `scripts/soak.sh`.
- **M8 — Packaging: DONE** (except your items). Icon (`scripts/make-icon.swift`), version 0.9.0,
  `bundle.sh --install` / `OUT_DIR`. Binary ~1 MB, bundle 1.5 MB. XcodeGen not needed.

## Verified M5 Pro facts
- `hw.perflevel0` = Super ×6 (cluster type "P", `apple,everest`), `hw.perflevel1` = Performance ×12
  (two "M" clusters, `apple,sawtooth`). CPU index order does **not** follow perflevel order.
- HID temperature services: 42 `PMU tdie*` (real), 24 `PMU tdev*` (read ~−9200 °C), `tcal`,
  battery gas gauge, NAND. ~0.75 ms per read.
- SMC: 3,626 keys, 268 float `T*` keys, ~0.15 ms per read regardless of family.
- Other users' processes: `PROC_PIDTASKALLINFO`, `PROC_PIDTBSDINFO` and `proc_pid_rusage` are
  refused; `kinfo_proc` (sysctl) and `proc_pidpath` work. `ps` sees their CPU because it's setuid.

## Measurements log
| Date | Build | Tick cost | App CPU (visible) | Footprint | Notes |
|---|---|---|---|---|---|
| 2026-10-19 | scaffold | 80–89 ms | 13–67% | 190–260 MB | HID temps, Swift Charts, SwiftUI Table |
| 2026-10-19 | btop layout | ~7 ms | ~9% | 165–236 MB | SMC temps, Canvas, NSTableView |
| 2026-10-19 | 740ed80 | ~7 ms | ~6.9% | 48–56 MB | vector-layer graphs |
| 2026-10-19 | 276f777 | ~7 ms | ~4.4% (1.3% minimized) | ~56 MB | row-drawn table, coalesced updates |
| 2026-10-19 | 06fe53c | ~7 ms | ~4.6% | 50 MB | M3 material + hover |
| 2026-10-19 | 1c2114b | ~6–10 ms | 4.9% (2.8% at 1 s/2 s) | 50–59 MB | all 1,033 processes listed |

# Glasstop — Progress log

Companion to PLAN.md (the spec). Update this file at the end of every work session.
The project is a git repo now (local only, never pushed): `git log --oneline` shows each step.

## Status (2026-10-19 → 20, overnight loop)

### Done
- **M0 — Build and run: DONE.** `swift build`, `swift run`, `./scripts/bundle.sh` all work, with no warnings.
  - Floating over other apps' fullscreen Spaces needs `.accessory` activation policy + `LSUIElement`
    (a `.regular` app's windows never join fullscreen Spaces). Verified: floats over fullscreen
    TextEdit, ⌘T toggles (window level 3 ↔ 0, persisted), ⌘V/⌘A work in the filter field.
  - Trade-off: no Dock icon / menu bar / ⌘Tab entry. M4's NSStatusItem will give it a handle.
- **btop-style layout** (user asked for it): CPU box on top (total graph left; right: CPU meter,
  cores grouped Super/Performance with sparklines + cluster temps, GPU row, load, uptime);
  bottom-left mem + sensors boxes; bottom-right process table.
- **Sampling perf:** tick cost 85 ms → ~7 ms.
  - Temperatures were 80 ms/s (HID, ~0.75 ms per sensor, 24 of 76 sensors are junk `tdev`).
    Now SMC first (~0.15 ms/key), round-robin 16 keys/s on their own queue
    (`TemperatureReader.swift`); HID is a filtered fallback.
  - Process footprints of idle processes are refreshed every 5th sample. The first process sample is
    not published (M1 item). Process sampling is syscall-bound (~93% in `__proc_info`).
- **UI perf (open problem #1 from last night): footprint fixed, CPU much better but not < 1%.**
  - Footprint 156 MB → **~56 MB**. Cause: SwiftUI `Canvas` (and even CG-drawn layer-backed NSViews)
    allocated ~90–160 MB of GPU surfaces. Graphs and meters are now `CAShapeLayer` masks over
    `CAGradientLayer`s (render-server drawn, no backing store): `GraphViews.swift`.
  - Process table: one view per row that draws all columns, CoreText lines cached by
    (text, width, column); visible rows patched in place, never `reloadData()`.
  - UI updates coalesced to one per tick (temperatures ride along); while the window is
    minimized/occluded nothing is published to SwiftUI (queued, bounded, flushed on show).
  - CPU: ~6.9% → **~4.4% visible**, **~1.3% minimized/covered** (that floor is sampling:
    processes ~0.4–0.6%, SMC temps ~0.25%, CPU/mem/GPU/load ~0.1%).
- **Verified M5 Pro facts** (M2/M3 groundwork):
  - Core map from `IODeviceTree:/cpus` `cluster-type`: C0–C11 = "M" = Performance (perflevel1),
    C12–C17 = "P" = Super (perflevel0). Implemented in `Topology.swift`.
  - SMC families (load-tested): `Tp*` = Super cluster, `Tm*` = Performance cluster (rule:
    `T` + lowercase cluster type), `Tg*` = GPU, `TB<n>T` = battery. `TPDX/TRDX/TUDX` are maxima of
    the TPD/TRD/TUD families.
  - GPU utilization: IOAccelerator `PerformanceStatistics["Device Utilization %"]` (`GPUReader.swift`).

- **M1 — Check the numbers: DONE.** Results + method in README.md "Accuracy check". Total CPU
  within ~1.5 points of `top`; process CPU matches the kernel's CPU-time delta (99.9% for a busy
  `yes`) and `top`'s steady-state samples (`top -l`'s first interval reads low); memory used/wired/
  compressed match; Memory column = kernel `phys_footprint` like `top`/Activity Monitor. Activity
  Monitor itself wasn't driven (needs an approval prompt while you were asleep) — the CLI
  references read the same kernel counters.

### Next up
1. M2–M8 per PLAN.md.

## Decisions to review
- **CPU budget "< 1% of one core at 0.5 s" isn't reachable with this design.** Sampling alone is
  ~1.1–1.3% (process table at 1 s + temps), and redrawing ~100 changing labels + graphs at 2 Hz
  costs ~3% more while visible. Options if you want lower: processes every 2 s (btop's default)
  saves ~0.3–0.5%; UI refresh 1 s halves the visible cost (M6 will make both configurable).
  I kept 0.5 s / 1 s as defaults since that's what the plan and your btop setup use.
- Temperature freshness: 16 SMC keys/s round-robin means each sensor refreshes every ~7 s
  (cluster averages still move every second). Cheap (~0.25% CPU) and temps change slowly.
- Activation policy `.accessory` (no Dock icon) — required for floating over fullscreen apps.

## Measurements log
| Date | Build | Tick cost | App CPU (visible) | Footprint | Notes |
|---|---|---|---|---|---|
| 2026-10-19 | scaffold | 80–89 ms | 13–67% | 190–260 MB | HID temps, Swift Charts, SwiftUI Table |
| 2026-10-19 | btop layout | ~7 ms | ~9% | 165–236 MB | SMC temps, Canvas, NSTableView |
| 2026-10-19 | 740ed80 | ~7 ms | ~6.9% | 48–56 MB | vector-layer graphs |
| 2026-10-19 | 276f777 | ~7 ms | ~4.4% (1.3% minimized) | ~56 MB | row-drawn table, coalesced updates |

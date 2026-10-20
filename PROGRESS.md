# Glasstop — Progress log

Companion to PLAN.md (the spec). Update this file at the end of every work session.

## Status (2026-10-19, night)

### Done
- **M0 — Build and run: DONE.** `swift build`, `swift run`, `./scripts/bundle.sh` all work, with no warnings.
  - Floating over other apps' fullscreen Spaces needs `.accessory` activation policy + `LSUIElement`
    (a `.regular` app's windows never join fullscreen Spaces). Verified: floats over fullscreen
    TextEdit, ⌘T toggles (window level 3 ↔ 0, persisted), ⌘V/⌘A work in the filter field.
  - Trade-off: no Dock icon / menu bar / ⌘Tab entry. M4's NSStatusItem will give it a handle.
- **btop-style layout** (user asked for it): CPU box on top (total graph left; right: CPU meter,
  cores grouped Super/Performance with sparklines + cluster temps, GPU row, load, uptime);
  bottom-left mem + sensors boxes; bottom-right process table. Swift Charts removed (Canvas graphs).
  SwiftUI Table replaced by NSTableView (`ProcessPanel.swift`), which fixed the
  "reentrant operation in its NSTableView delegate" warning.
- **Sampling perf:** tick cost 85 ms → ~7 ms.
  - Temperatures were 80 ms/s (HID, ~0.75 ms per sensor, 24 of 76 sensors are junk `tdev`).
    Now SMC first (~0.15 ms/key), round-robin 24 keys/s on their own queue
    (`TemperatureReader.swift`); HID is a filtered fallback.
  - Process footprints of idle processes are refreshed every 5th sample. The first process sample is
    not published (M1 item).
- **Verified M5 Pro facts** (M2/M3 groundwork):
  - Core map from `IODeviceTree:/cpus` `cluster-type`: C0–C11 = "M" = Performance (perflevel1),
    C12–C17 = "P" = Super (perflevel0). Implemented in `Topology.swift`.
  - SMC families (load-tested): `Tp*` = Super cluster, `Tm*` = Performance cluster (rule:
    `T` + lowercase cluster type), `Tg*` = GPU, `TB<n>T` = battery. `TPDX/TRDX/TUDX` are maxima of
    the TPD/TRD/TUD families.
  - GPU utilization: IOAccelerator `PerformanceStatistics["Device Utilization %"]` (`GPUReader.swift`).

### Open problems (next up)
1. **UI still too heavy: ~9% CPU, 165–236 MB footprint (budget < 1%, < 80 MB).** Sampling is only
   ~1% of that. An 8 s `sample` showed the main thread mostly idle, plus
   `CA::Render::Shmem::new_bitmap`, RenderBox and Metal surface work. Suspect: Canvas views re-rasterizing into new
   backing bitmaps on every update (24 Canvases at 2 Hz) → memory churn. Ideas: one NSView/CALayer
   graph view drawing into a reused layer, fewer canvases (draw all core sparklines in one Canvas),
   redraw sparklines at 1 Hz, check that `.drawingGroup()` isn't involved, measure with Instruments
   (Time Profiler + Allocations) via `xctrace` from the CLI.
2. M1 number checks (Activity Monitor / top), README notes.
3. The rest of M2–M8 per PLAN.md.

## Measurements log
| Date | Build | Tick cost | App CPU | Footprint | Notes |
|---|---|---|---|---|---|
| 2026-10-19 | scaffold | 80–89 ms | 13–67% | 190–260 MB | HID temps, Swift Charts, SwiftUI Table |
| 2026-10-19 | btop layout | ~7 ms | ~9% | 165–236 MB | SMC temps, Canvas, NSTableView |

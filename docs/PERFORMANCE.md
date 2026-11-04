# Acceleration and long-run combat performance — 2026-11-04

## Report and current conclusion

The user corrected the timing: the slowdown appears at roughly **five minutes
on the in-game timer**, with a selected 3x speed. Actual elapsed wall time is
unknown. Combat becomes slow while settings/menu interaction appears responsive.
Returning to 1x does not restore normal combat performance; restarting the game
does. Selecting 5x immediately triggers the existing frame guard. These symptoms
do not yet identify one sole cause or prove a memory leak.

Compare runs near the same five-minute game progress and similar combat load.
An earlier interpretation of four real minutes at 3x as twelve game minutes was
incorrect and must not be used as evidence. A selected multiplier is not itself
a measurement of the effective simulation rate.

## Client and evidence boundary

The installed EXE matches the structural report for **0.140.0**:

- Size: `151521280` bytes.
- SHA-256: `27c8df53c87e38a98d474bf7106d2444e11e7634ca70dbffc5c2b0aecb894fd9`.
- A new `patch-C.MPQ` is present, size `59489189` bytes.

The existing private test bundle contains 0.131.0 and its older MPQ set. It can
support historical comparisons, but cannot certify gameplay or performance of
the current client. Current-build acceptance needs the matching EXE and asset
delta; unchanged cached assets should be reused. The structural compatibility
scan alone is not a gameplay or performance result.

## Findings from the installed sources and settings

- SpellMeter 1.32 is in mini mode. Its periodic refresh still performs work on
  the hidden full statistics window, including expensive row preparation around
  combat/death events. The remote regression below reproduces that unnecessary
  work. It does not prove that it solely explains this report.
- SpeedGear's measurement history is bounded to seventeen wall-time buckets and
  its width cache to 256 entries. The native forwarding buffers are also bounded.
  These particular containers do not demonstrate duration-proportional growth;
  this is not a proof that the whole process has no leak.
- Keijin's floating damage list has a sixty-item live limit and reuses labels.
  Its animated font sizes are rounded integers. Repeated width measurements and
  anchor updates remain possible CPU costs despite those bounds.
- DragonUI's native SCT replacement and optional copy capture are disabled in
  the inspected settings. An uncapped pool in an inactive feature is insufficient
  evidence to blame the active configuration.

The inspected benilla engine source is commit `5899c984` from 2026-10-30, not a
verified source match for 0.140.0. It retains nameplate widgets up to peak
concurrency and reuses retired widgets; glyph and text caches have explicit
bounds/reset behavior. Peak widget retention, cache thrashing, and expensive
scans of hidden pooled widgets are hypotheses requiring current-client evidence.
SpeedGear's process-wide clock mutex also adds traffic-dependent overhead,
reproduced separately below. No duration-growing SpeedGear collection has been
established as the cause.

## Remote pre-fix evidence

The production SpellMeter Lua was exercised under a simulated host in remote
[run 41820036292](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41820036292).
The test failed because mini mode continued rendering its hidden full window:

| Input window | Hidden-window UI-write API calls | Full-window refreshes |
| --- | ---: | ---: |
| 20 real seconds at simulated 1x | 2,668 | 92 |
| 20 real seconds at simulated 3x | 8,700 | 300 |
| 20 real seconds after restoring simulated 1x | 2,668 | 92 |
| 1,000 death events | 29,000 | 1,000 |

These are source-path call counts, not measured game FPS. They demonstrate work
that should be deferred while the window is hidden, and show that restoring 1x
does not remove its ordinary hidden-rendering cost.

A separate pre-fix remote native host measured a fixed total of **1,048,576 QPC
calls** through the real SpeedGear DLL, against an unhooked baseline. Total
window durations in milliseconds were:

| Clock configuration | 1 thread | 2 threads | 8 threads |
| --- | ---: | ---: | ---: |
| Unhooked baseline | 28.17 | 15.74 | 8.12 |
| SpeedGear loaded at 1x | 54.98 | 63.41 | 84.71 |
| SpeedGear at 2x | 49.71 | 58.39 | 85.59 |
| Restored 1x | 50.42 | 61.21 | 82.39 |

This sample establishes shared-clock synchronization overhead under concurrent
timer traffic, including after restoring 1x. It is not a game benchmark, a proof
of growing retained state, or a prediction of a particular desktop's FPS. A
replacement clock read path must also preserve monotonicity and continuity
through concurrent speed changes before it can be accepted.

## Remote comparison

Keep the map, character/build, graphics settings, language and addon settings
matched where possible. Record the actual game progress, event rate and visible
enemy/effect load. Report any differences that prevent a matched comparison.

| Comparison | What it distinguishes |
| --- | --- |
| Fresh 1x client versus the client at the same later game time | Ordinary late-run scene load versus elapsed real time |
| No SpeedGear native backend versus its loaded 1x state | Clock-hook overhead even when acceleration is not requested |
| SpeedGear alone versus each other addon added separately | Which addon introduces additional work or retained state |
| SpellMeter mini/hidden views versus visible full views | Data collection cost versus rendering work that should be deferred |
| Cold run versus warmed run after restoring 1x, at matched game load | Transient accelerated load versus retained overhead |
| New run in the same process versus a fresh process | Run-scoped accumulation versus process-lifetime state |

Use an independent wall clock for frame-time windows and process CPU/memory
observations. In-game QPC-based profiler milliseconds can themselves be scaled
by SpeedGear. Handler percentages within a stable-speed window can help locate
cost, but absolute milliseconds across different speeds need correction.

For the hidden-window regression, count calls to the real row preparation and
native UI writes while keeping combat statistics collection active. Hiding the
window should defer its rendering without dropping events; opening it should
render the latest totals. Longer event streams should not increase the live
widget count without a documented bound.

A fix may remove a remotely reproduced source of waste without proving it was
the sole cause of the reported combat slowdown. A full resolution claim requires
the original warm-run symptom to improve in matched current-client comparisons.
Remote results and any remaining limitations belong in [VALIDATION.md](VALIDATION.md).

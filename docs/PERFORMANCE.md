# Acceleration and long-run combat performance — 2026-11-05

## Report and current conclusion

The user corrected the timing: the slowdown appears at roughly **five minutes
on the in-game timer**, with a selected 3x speed. Actual elapsed wall time is
unknown. Combat becomes slow while settings/menu interaction appears responsive.
Returning to 1x did not restore normal combat performance; restarting the game
did. In the initial report, selecting 5x immediately triggered the frame guard.
After the 0.7.5 repair, the user could initially use 5x and the slowdown started
later, but combat still became slow and 5x protection still triggered afterward.
These symptoms do not yet identify one sole cause or prove a memory leak.

Compare runs near the same five-minute game progress and similar combat load.
No elapsed wall time was reported, and a selected multiplier is not itself a
measurement of the effective simulation rate.

## Client and evidence boundary

The EXE inspected during the first investigation matched the structural report
for **0.140.0**:

- Size: `151521280` bytes.
- SHA-256: `27c8df53c87e38a98d474bf7106d2444e11e7634ca70dbffc5c2b0aecb894fd9`.
- A new `patch-C.MPQ` is present, size `59489189` bytes.

That EXE has since changed. The current supplied executable and the new private
runtime report identify size `151493632` and SHA-256
`6ca5f4ba4eb6b26716e4b7d9e03cbd25ddafe7582dcd8e55333e070a28058afa`.
The runtime report has no game-version string; it must not be relabeled as the
old 0.140.0 build merely because the file sizes are similar.

The reusable private base contains 0.131.0 assets. New runtime work reuses that
verified base plus the matching executable/asset delta, rather than uploading
the whole game again. Structural compatibility alone is not a gameplay or
performance result. Historical 0.131.0/0.140.0 observations remain scoped to
their recorded identities.

## Version 0.7.6: remaining presentation work

The user reported that 0.7.5 improved initial performance and delayed the
slowdown, but it still appeared later. The first repair skipped hidden native
widget painting only after `rebuild()` had already merged, sorted and ranked
the entire statistics view.

Remote [red run 41848662929](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41848662929)
exercised those actual source closures with synthetic native meter rows. Over
ten fixture wall seconds at simulated 3x, the hidden view still sorted 150 times:

| Synthetic rows | Comparator calls before v2 | Sorted-row visits before v2 | Both after v2 |
| ---: | ---: | ---: | ---: |
| 8 | 2,850 | 1,200 | 0 |
| 64 | 56,550 | 9,600 | 0 |
| 256 | 297,300 | 38,400 | 0 |

These row counts are controlled stress inputs, not observed user spell counts
or game FPS. The v2 data-only path returns after native totals and per-spell
rate history are sampled, before presentation merging/sorting/ranking. Visible
windows still prepare their normal rows. The
[fixed run 41852402123](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41852402123)
passed all fourteen data-growth checks, including bounded history, live totals,
fresh snapshots and visible ranks. Later
[run 41860132725](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41860132725)
passed 32 checks, including the optional passive collector's checks.

The current repair script accepts both the original `2265...` source and the
first repaired `a724...` source, backs up the exact input received, and produces
SHA-256 `9a2273e6d75998ae2a3fa75904212667d40952cf920728a56fd49b0483793aa6`.
Repeat application is a no-op. The full original and v1 identities below are
historical reference points; v2 is the current output.

## Bounded current-client runtime observations

Private run `41852851808`, source
`40f48e08147521dbd3cfea68a755cc64e01f0d97`, used the new EXE identity above and
three fresh-process cases: current addons, addons with the v2 meter repair, and
SpeedGear alone. Its small [numerical summary](evidence/remaininglag20261105.json)
identifies the private raw report, verified base and delta by SHA-256. No game
files, raw personal settings or full raw report are published.

The 2-CPU/8-GiB Windows runner used updated WARP at 640x480 and observed only
about 1.15-1.19 UI updates per real second. Every case triggered the production
frame guard and returned to 1x. Combat ended at 75.35, 85.61 and 76.34 game
seconds respectively; none reached the user's approximately five-minute point.
The report's `passed` status means bounded numerical observations were recorded,
not that lag was reproduced or resolved. The client-reported plugin version in
this runtime record is 0.7.5; the delivery being prepared is 0.7.6.

Pinned addon sources were used with synthetic fresh settings. `avrt.dll` was
omitted to prevent addon startup updates during the experiment, so this does
not isolate the user's complete installed native-mod combination. The final
normal-close wait exceeded thirty seconds in all three disposable cases and
remains an explicit cleanup warning.

No glyph-cache reset was observed in these short cases. Keijin's observed live
damage peak was only three labels, and the frame counts stayed within small
bands. These observations do not rule out a high-load glyph working set,
long-session object growth, native-mod interaction or the user's later combat
slowdown. Observer frame walks also add work. Comparisons on this software
renderer are not desktop GPU FPS comparisons or evidence of a sole cause.

## Optional passive desktop evidence

Remote-only testing remains the default. The optional manual passive collector
may run on the user's computer only after an explicit local exception for that
collection session. Installing the update does not start or authorize it.
It samples process CPU/RAM and available GPU counters once per second, without
launching the game, sending input, changing speed or editing settings. Missing
counters must be reported as unavailable. This can help distinguish CPU,
memory and rendering saturation near the real slowdown, but passive numbers
alone do not establish a leak or assign responsibility to one addon.

## Findings from the installed sources and settings

- Before v2, SpellMeter 1.32 in mini mode still performed work on
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

### Historical 0.7.5 repair and rejected clock experiment

Remote run [41823387079](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41823387079)
passed the repaired-meter regression, including live totals, detached healing
windows and immediate kill credit. Hidden main-window mutations were zero in
all three periodic phases; the 1,000-death burst performed zero hidden writes
and zero immediate full-window refreshes. Normal data rebuild and rate-history
sampling remain active. The existing periodic updater handles repaint.

The same run compared a candidate concurrent QPC reader with the stable backend
using the same host and 16,777,216 queries per sample. Benefits were inconsistent:
8-thread restored-1x wall time was 916.63ms for stable versus 932.93ms for the
candidate; single-thread loaded-1x was 767.35ms versus 803.92ms. Some other samples
improved slightly. The candidate was removed before release. The retained
[stable](evidence/clock-before20261104.json) and
[experimental](evidence/clock-experiment20261104.json) reports describe that
experiment, not shipped code or game FPS. Version 0.7.5 retains the 0.7.4 clock
and frame-guard algorithms.

In 0.7.5, `scripts/RepairSpellMeter.ps1` repaired only the installed 1.32 source SHA-256
`2265a223d9e2f01f82f45290d885b884e4dbe8026352f2815956608f837f0cb3`.
It backed up original bytes and verified output SHA-256
`a724462a9a14ce94017c0c2a4324416804e9be2369444aad422c386eba00d2a5`.
Version 0.7.6 additionally accepts this v1 output as an upgrade input; its current
output is the v2 identity recorded above. Other unrecognized versions or modified
sources are refused.

The reported five-minute combat slowdown has not been reproduced in a matched
current-client run. These results fix an active addon overhead, but do not prove
a sole cause or eliminate game/rendering workload as another contributor. A 5x
guard activation remains a frame-gap observation, not a component diagnosis.

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

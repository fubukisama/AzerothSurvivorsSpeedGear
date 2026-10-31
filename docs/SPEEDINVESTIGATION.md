# Speed investigation — 2026-10-31

## Reproduced display defect

The remote [pre-fix regression](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41096103400)
loads the real Lua controller with a physically independent constant 4x game
clock and a 2x request. Observations at physical times 1.75 and 2.25 seconds
advance the integer wall clock by one, although only 0.50 seconds elapsed.
The old controller divides 2.00 game seconds by that integer difference and
incorrectly confirms 2x. This proves a display/confirmation defect. It does
not prove the native backend made the real game run at 4x.

The public game getter `AZS_GetRunTime()` adds UI-clock interpolation to
`AZS_RUN.t`. Consequently, interpolation alone cannot establish simulation
progress. Confirmation must observe fresh raw run snapshots and account for
the uncertainty of integer wall-clock sampling.

## Native evidence

The same remote run loads the production DLL into an isolated synthetic host.
Its independent OS FILETIME reference is not scaled by the plugin. QPC/wall
ratios were 1.0000, 2.0000, 5.0000, 0.5000, 3.0001 and 1.0000, with no backward
QPC samples. Fixed-step throughput relative to baseline was 1.0000, 2.0223,
4.9845, 0.5059, 2.9457 and 1.0151. An independently sampled per-step elapsed
model also scaled approximately once.

These results do not support a universal claim that hooking both the sleep
and QPC necessarily squares the rate. A deliberately hypothetical model that
reuses a rendered-frame delta per simulation step can multiply twice; its
reported values are not evidence that the game uses that design.

An old in-flight sleep can span a speed change. This host observed a maximum
single-step virtual elapsed time of 134.49ms. Whether the real simulator
consumes that duration directly is unestablished; the finding alone does not
justify changing the game's scheduling behavior.

## Acceptance boundary

Earlier installed-game logs contain approximately 40 simulation steps per
second at 1x, 80 at 2x and 200 at 5x. Whole-second log stamps and loop counts
cannot establish movement distance, skill cooldown progress or visual animation
speed. A stale status file is not a live game observation.

Real-game acceptance belongs in the disposable remote Windows workflow.
It records raw run time, UI time, map movement and raw spell cooldowns against
the runner's independent OS timestamps. Missing graphics, input, fresh packets,
stable movement or cooldown samples must produce a blocked metric, never a
claim of successful gameplay verification. No game files or user saves are
included in this repository or the published artifacts.

When official downloads are unavailable, an explicitly authorized local game
bundle can supply the same disposable runner. Its ZIP contains only the EXE,
`Data/*.MPQ` and a file-hash manifest; configurations, saves and installed native
mods are excluded. A temporary private repository can hold the bundle while its
own short-lived workflow token downloads it. The public plugin source is checked
out at a pinned commit, and the game process receives no repository token. The
runner checks the archive digest, exact file list and each extracted file hash.
Default reports retain numerical observations. An owner-authorized private
diagnostic run may also opt into four redacted panic lines and one bounded game
window image to identify startup or input failures. These diagnostics exclude
personal settings and saves. The temporary runtime release is removed after the
investigation. No game bundle belongs in the public project or release.

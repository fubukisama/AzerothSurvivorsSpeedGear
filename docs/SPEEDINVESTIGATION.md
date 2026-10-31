# Speed investigation — 2026-10-31

## Real game 0.131.0 and low-frame-rate protection

The owner authorized a private transfer of the locally installed game. The bundle
contained only the official EXE (SHA-256
`5dd6819d836748ccf809ab76fe6509c9ee793e087939b5d036c430d835a14e63`),
eleven MPQs and a file manifest. No saves or personal settings were transferred.
The remote baseline initially lost its software graphics device; a verified
DXC/WARP profile fixed startup. Waiting for the native loading-cover clear signal
then enabled actual combat, rather than mistaking server `ready` for a loaded
client.

In [run 41173937030](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41173937030),
the real unhooked game clock ran at 0.998x. With the plugin set to 1x it ran at
1.007x; a 2x request produced 2.013x game time and 2.092x raw cooldown decay.
Movement relative to the 1x window was only 0.931x. The actual client measured
320x240 and updated only about 2.7–3.3 times per real second. Thus this run did
not pass the movement criterion; the timer and cooldown results do not certify
uniform 2x gameplay.

The base client advances movement through Bevy's virtual time, whose default
maximum frame delta is 250ms. UI/GetTime retains the uncapped frame step. The
observed per-update displacement plateau matches this mechanism: at very low
update rates, accelerating the clocks can make simulation and cooldowns outrun
frame-driven movement. This is strong evidence for a low-frame-rate limit, not
proof of the cause of a particular player's desktop symptoms.

Version 0.6.3 detects three consecutive client-clock gaps over 250ms while an
accelerated solo request is active. It sends a fresh 1x request, clears the
retained acceleration and reports the reason. Recovery never automatically
re-enables acceleration. Localized wording describes a request, not a native
receipt. The engine's physics clamp remains intact. At extremely low frame rates
even the original unmodified 1x game can be limited; returning to 1x prevents
additional acceleration from worsening that disparity.

Actual restoration was independently [verified remotely](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41177528605)
from the existing combat record: native speed changed from 200 to 100, post-guard
run time was 1.011x, cooldown decay was 1.035x, and later accelerated-target
samples stayed at 1x for 15.495 seconds. The original full experiment remained
blocked by sparse pre-guard baseline sampling; its status was not rewritten.
The [separate verdict](evidence/frameguard0131.json) makes only the narrower
automatic-restoration claim.

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

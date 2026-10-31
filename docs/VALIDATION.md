# Validation — updated 2026-10-31

## Version 0.6.3 frame-interval protection

The old controller failed the new remote
[Lua50FrameGuard regression](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41175105454):
an independent 5 Hz callback stream, 2x client clock and 2x raw simulation
continued requesting 2x despite 400ms client-frame intervals. The corresponding
250ms-capped movement oracle advances only 1.25x. The regression also covers
manual retry, no automatic re-acceleration, brief hitches, the exact boundary,
pause/choice transitions, unusable clocks and a failed restoration transport.

The full-game data and scope are recorded in the
[speed investigation](SPEEDINVESTIGATION.md). Normal 2x gameplay acceptance and
automatic-protection acceptance use separate verdicts. A successful restoration
test must observe the real controller's latch, effective 1x request, a later
native 1x receipt and normal post-guard simulation/cooldown rates. It cannot be
reported as successful 2x movement. Builds, automated regressions and real-game
tests remain remote-only.

## Version 0.6.2 speed measurement and licensing

The pre-fix remote run
[41096103400](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/actions/runs/41096103400)
passed 21 of 22 CTests and failed the new real-controller regression: an
independent constant 4x clock was falsely confirmed as the requested 2x under
irregular integer-second observations. The production-DLL timing models passed;
their numbers and limits are recorded in [the speed investigation](SPEEDINVESTIGATION.md).

The revised controller uses raw `AZS_RUN.t`/`AZS_RUN_UPDATED`, not interpolated
`AZS_GetRunTime()`, for rate estimation. New fixtures supply independent physical,
UI and raw publication clocks and cover sparse observations, frozen raw packets,
wrong rates and valid progress. Optional `GetTime` bounds sampling phase and
cached snapshot age using the supported minimum clock rate of 0.25 and a 20ms
virtual-time margin. It is never divided by the requested multiplier to invent
wall time. This assumes an unclamped client clock; unknown publication/queue
latency remains outside the estimate. Missing precision or fresh progress must
leave confirmation pending. This is an observed run-clock estimate, not proof
that movement or skills match the same rate.

The disposable game workflow downloads official assets only into the ephemeral
Windows runner and compares no-DLL, hooked 1x and hooked 2x observations using an
unhooked parent FILETIME clock. Only a bounded numerical report is retained.
Unavailable rendering, input or metrics produce blocked evidence rather than
successful real-game acceptance. GPL-3.0-or-later applies to new project releases;
the complete GPLv3 text and original dependency licenses accompany the package.

## Version 0.6.1 addon description language

Remote-only fixtures cover fourteen fixed description values, English fallback,
strict non-Notes template identity, atomic file replacement and rejection of
unknown edits. The actual DWM-load fixture uses an isolated APPDATA/language.txt
set to Japanese and checks the on-disk Notes by the tiny EXE's main entry. This
does not operate the real game's AddOns UI or prove its cache refresh behavior.
PowerShell fixtures cover normalized receipt validation across install, update
and reversible uninstall, including rejection of metadata/script/catalog edits
and unowned normalization libraries. Downloaded package checks remain exact.
No local script test, native build, probe, helper or game/UI launch is performed.

## Version 0.6.0 direct EXE updates

All new tests run only on remote Windows CI. The native launch-policy tests use
injected process APIs and never start real updater children. A separate tiny
compiled EXE statically imports the actual DWM proxy, then proves a hidden
helper performs its immediate and post-exit calls using a receipt-owned mock
updater. No actual game executable, network updater or game assets are used.
The fixture compares the EXE's original entrypoint bytes before/after loading.
An additional fixture verifies that an exclusive read lease blocks a new process
open until released. This is OS/fixture evidence, not a universal guarantee
against every possible external updater or filesystem race.

PowerShell mocks cover helper deduplication, initial failure with a later exit
attempt, receipt/hash refusal, refreshed helper paths and skip-environment
restoration. Existing installer fixtures cover the leased image snapshot and
rollback. No local build, probe, helper execution, game launch or UI test is
performed; local deployment only installs the remotely published package.

## Version 0.5.0 update-following validation

Updater, launcher and official-manifest monitor tests run only in remote CI.
The launcher suite mocks process discovery, game launch and update helpers; it
never starts the actual game. Updater fixtures exercise stable-release selection,
fixed source URLs, archive and file-manifest integrity, pending installs and the
owned installer boundary. Monitor fixtures exercise manifest bounds, gzip
reconstruction, loader/import requirements and scanner verdicts without running
official game code. The separate scheduled workflow checks the official EXE in
an ephemeral Windows runner and publishes only JSON evidence.

The launcher can retrieve released maintenance fixes. It cannot invent a correct
adapter for an arbitrary new engine. Scanner success remains structural evidence;
unknown or unsupported builds are never described as gameplay-tested. No local
test, build, Probe, launcher or game/UI run is performed for this release.

## Version 0.4.0 validation scope

This version is built and tested only on the remote GitHub Windows runner.
The developer's local computer is used for source editing and installation of
the remotely produced package; no local build, probe, test host or game/UI test
is authorized or performed for this version. Real-game acceptance is not covered
by the CI fixtures.

New regression sources exercise a deliberately blocked original stdout pipe,
complete normal stderr forwarding, bounded queue overload and delivery of the
latest command. Command-gate tests cover validated console health, its 2.5s
expiry, recovery through a matching query, stale/old-sequence refusal and
adaptive fallback polling (30 scans in a modeled 30 healthy seconds instead of
300). Native status tests cover atomic reports and refusal of unrelated or
hard-linked destinations. PowerShell status fixtures cover schema/type bounds,
freshness, missing or invalid reports and backend configuration labels. Lua
fixtures distinguish sending attempts from native receipts and verify the fixed
project title across fourteen language catalogs. Execution results are supplied
by the corresponding GitHub Actions run, not inferred from source inspection.

## Version 0.3.0 switching and clock stability

The old DLL reproduced a multimedia-timer resolution regression: an original
timeGetTime short-gap step of at most 3ms became 16ms at 1x and up to 80ms at 5x.
The native transition probe now reads the original multimedia clock, unwraps its
32-bit rollover under the shared clock lock, and continuously scales that domain.
The same probe reports at most 3ms at 1x and 15ms at 5x; QPC has no backwards
samples or out-of-envelope transitions in this fixture. These are observed
steps, not a latency or frame-time guarantee on every machine.

The old native DLL also failed the immediate-console-delivery regression (16
failures; commands were not delivered within 400ms without a config save). The
same actual-DLL host now passes: eight alternating requests across stdout and
stderr, including split lines, reached the hooked clocks with a maximum observed
delivery measurement of 26.1ms. Delayed config copies cannot revert newer console
requests; the file-only fallback still works. A shared command gate checks strict
payload grammar, freshness, sequence, retired sessions and the eight-real-second
watchdog. Stale exact console replays cannot keep the watchdog alive.

The deterministic save-debounce model reproduces the old 0.25x oscillation:
three-real-second CVar mutations repeatedly restart a one-scaled-second quiet
period, starving saves until the native watchdog restores 1x. Separating live
queries from five-second persisted refreshes removes that loop in the model.
Run it with `python tests/debounce_test.py` (seven checks). This model cannot
establish real-client IO timing or behavior under every unrelated CVar mutation.

All nine local CTest suites pass. NativeCore has 10,098 assertions; CommandGate
has 21 checks; Lua 5.0 addon wiring has 161 checks and localization has 1,211.
The Lua regression first failed the old three-second confirmation logic, then
passed with an integer-boundary anchor followed by one complete second of actual
game-time observation. Confirmation enters within 10% of the target and remains
within 20%; substantial mismatch, frozen time, pause and new requests clear it.
Successful measurement clears the stale switching notice. Neither the test nor
the UI treats the requested rate as proof that native acceleration worked.

Version 0.3.0 was installed using the owned-version installer while the actual
game was stopped. Game EXE, avrt.dll, shared config and shared saved variables
were hash-identical immediately after installation. The real client 0.130.0
loads the DLL, verifies the simulation site and opens the localized addon panel.
The new console path and combat switching in that client still require live
acceptance; the isolated-host timings above are not real gameplay measurements.

Transport design references: [game ConsoleExec implementation](https://github.com/samwhosung/benilla/blob/main/benilla-app/src/console.rs),
[Rust Windows stdio handle lookup](https://github.com/rust-lang/rust/blob/1.92.0/library/std/src/sys/stdio/windows.rs),
[Bevy default stderr writer](https://github.com/bevyengine/bevy/blob/v0.18.1/crates/bevy_log/src/lib.rs).
Runtime code does not hardcode addresses from those sources.

## Version 0.2.1 launcher rate

The launcher now shows the requested rate only after a fresh measured rate is
within 10 percent of that target. A pending request, pause or missing measurement
removes the success suffix. Relative tolerance avoids incorrectly confirming 0.5x
when the measured rate is 0.25x. Caption sizing measures the complete localized
text and defers resizing during a drag. Lua regressions exercise real controller
requests and clock progression, hidden-panel updates, language changes and reset
behavior. The native backend is unchanged from 0.2.0.

## Version 0.2.0 UI and locale changes

The new floating launcher appears on world entry, toggles the panel, and retains
an independent drag position. Lua fixtures cover drag-release click suppression,
visibility, saved positions and unchanged heartbeat behavior. Fourteen complete
UI catalogs preserve all format placeholders. Native locale hints take precedence
over the classic locale API; live caption rebinding preserves control state.

The language bridge only accepts fourteen known language codes, reads at most
64 bytes, checks paths, and atomically writes the addon's own locale hint. Native
fixtures cover missing/invalid input, all codes, repeated unchanged output,
stale temporary files and linked paths. Installer fixtures cover old receipts,
generated locale hints, exact-format validation and refusal of injected Lua.

These are automated checks. Actual rendering and dragging of version 0.2.0 and
native-speaker review of every translation have not yet been performed.

## Completed locally

- Visual Studio 2026, MSVC x64 Release build, static C/C++ runtime.
- Native clock/protocol unit suite: 10,087 assertions, zero failures.
- Lua 5.0.3 addon state, protocol, control wiring and UI-stub suite: 66 checks.
  The interpreter is test-only and is built without optimization because this
  historical Lua release's table resizing is miscompiled by the current MSVC /O2.
- Native integration host loads the actual `dwmapi.dll`, successfully forwards
  `DwmIsCompositionEnabled`, discovers an independently compiled 25ms simulation
  call, installs the actual MinHook hooks, and reads real config-file commands.
  Measured steps per wall-clock second: 38.97 at 1x, 78.83 at 2x, 194.20 at 5x,
  19.94 at 0.5x, 39.62 after an inactive command, 39.52 after heartbeat expiry.
- Read-only scan of the tested game EXE
  SHA-256 `8829953418a4d996cc5287f0e9fad25407ca30ceb64d105a4f57833caef78016`:
  unique sleep function RVA `0x0607d480`, caller return RVA `0x05c0c398`.
  These addresses are recorded evidence only; runtime code does not hardcode them.
- Scanner refusal tests alter the duration and duplicate the call in executable
  padding: zero candidates and two candidates both produce an unsupported result.
- Installer/uninstaller fixture checks: first install, owned-version update,
  file hash mismatch refusal, unknown extra file refusal, unknown DLL refusal,
  reversible uninstall, x86 refusal, and preserved sibling config/addon hashes.

## In-game acceptance

The plugin was installed without replacing the game EXE or avrt.dll.
The tested game displays **0.130.0 (e7d9dc47)**. The actual game process loaded
both the local SpeedGear dwmapi.dll and the existing DragonUI avrt.dll, together
with their real system counterparts. The backend logged the same unique scan
result as the offline probe. The AddOns menu listed the plugin enabled alongside
AZSSpellMeter and SurvivorsDragonUi; all three appeared in the live scene.

The Chinese panel, preset buttons, stop button, slash command, CVar persistence
and three-real-second heartbeat ran in the actual client. A real client timing
correction exposed a measurement-window reset issue; using a bounded high-water
mark fixed it and six jitter/reset regressions were added. The revised panel
displayed **x1.00** at normal speed and **x2.00** after the 2x preset. The 5x preset
was accepted and visibly accelerated the run; selecting a treasure card suspended
the request and the backend logged `speed100=100 reason=addon-inactive`.

The 5x panel reading, real-client slow speed, custom maximum, actual client
watchdog expiry, and a full gameplay clear were not completed. The public
repository and release packages contain no game files, account data, saved
variables, or private test artifacts.

## Not established

The native integration host is not the game. Its measured rates do not prove
equivalent gameplay or stability on every game version or PC. No future version,
multiplayer, browser, Wine/Linux, or high-load scene is certified by these tests.

# Validation — 2026-10-30

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

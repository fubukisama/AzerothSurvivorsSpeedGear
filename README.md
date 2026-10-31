# AzerothSurvivorsSpeedGear

Version 0.7.3 measures fresh raw publications against independent wall-clock
seconds in a continuously updated bounded window. Confirmation no longer clears
its own evidence or repeatedly restarts after twelve seconds. Confidence still
requires the whole possible rate interval to match; wrong, frozen or interrupted
progress revokes it. A short fresh-data hitch no longer discards a live window,
and sparse short-term samples no longer override a matching full interval.
Sparse observations can require longer to become conclusive.

Version 0.7.2 keeps the numeric target visible while measurement is pending:
**Target ×2 …**. A definite mismatch uses **Target ×2 !**; only confirmed
measurements use **Speed ×2**. Hovering shows the measurement and current status.

Version 0.7.1 preserves Ctrl/Alt/Shift event order while recording a shortcut,
including delayed key events whose native modifier query is already stale.
An observed modifier release takes priority over that query. Ending or cancelling
recording clears both temporary keyboard handlers and their modifier state.

Version 0.7.0 adds configurable in-game speed hotkeys. **Q** steps down and **E**
steps up through 0.25x, 0.5x, 1x, 2x, 3x, 5x and 10x. Endpoints hold their value;
custom rates step to the nearest lower or higher preset. Click either hotkey
button in the panel and press a new key or modifier chord. Esc cancels, Backspace
clears the assignment, and Reset Q/E restores defaults. Assignments are saved
with the addon. Closing the panel keeps the hotkeys active. Chat and this panel's
text field suppress speed changes while typing.

The addon uses the client's native bindings dispatcher and a separate
`Bindings.xml`. It temporarily restores the original key map around game binding
saves, and restores still-owned keys on reassignment or world exit. It never
keeps a keyboard-capturing frame enabled outside the explicit key-recording mode.

Version 0.6.3 adds low-frame-rate protection. While accelerating, three consecutive
client frame intervals above 250 ms request a return to 1x and show a localized
notice. The request stays at 1x until you choose a speed again; it does not
oscillate automatically as performance changes. An isolated hitch is ignored.
This preserves the engine's physics protection rather than removing its step cap.

Version 0.6.2 corrects a false speed-confirmation case caused by coarse wall
clock sampling. Confirmation observes raw run snapshots, rather than the
interpolated display getter, and waits for a sufficiently bounded observation.
New releases use **GPL-3.0-or-later**; dependency notices retain their licenses.

Since 0.6.1 the addon-list description follows the game's saved language across
all fourteen supported languages, while the title remains **AzerothSurvivorsSpeedGear**.
Restart after changing language to refresh cached addon metadata. The native
component selects the normal TOC `Notes` before the game reads the manifest;
legacy client locale suffixes alone cannot express all fourteen game settings.
Only fixed translated Notes values are mutable. Receipt checks normalize that
one value to the English baseline and still verify every other byte, so ordinary
language changes do not block updates or reversible removal.

[简体中文](README.zh-CN.md) · [Downloads](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases)

An in-game speed control addon for **Azeroth Survivors on Windows x64**. Click
the persistent floating **Speed** button or use `/azsg` to choose 0.5x, 1x, 2x, 3x or 5x, enter a custom rate from 0.25x to 10x,
or request a return to normal speed. The panel displays a measured game-time to
wall-time ratio separately from the requested speed.

Drag the floating button or the main panel freely; their positions are saved
independently. Closing the panel keeps the floating button available. A new
installation initially shows just the button; existing visibility preferences
are retained.

The floating button shows the requested number immediately as **Target ×2 …**.
It switches to **Speed ×2** only after a matching measurement, and uses
**Target ×2 !** for a definite mismatch. Hovering shows the target, any measured
rate and protection notice. Pauses or world exit remove the active numeric
status. The target label is not a native acknowledgement or measured result.

The UI follows the game's selected language on world entry, with complete
catalogs for English, Simplified Chinese, Japanese, Korean, Polish, Czech,
German, Portuguese, Spanish, French, Romanian, Turkish, Russian and Ukrainian.
The native backend reads the game's small language setting and generates an
addon-owned locale hint; the classic client locale is only a fallback.

This is an unofficial community project, not affiliated with the game developer
or Blizzard Entertainment. You must supply your own game installation. No game
files, assets or saves are distributed here.

## Install

1. Download the **Windows x64 ZIP** attached to a [release](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases).
   GitHub's source archives do not contain the compiled native backend.
2. Exit the game and extract the complete package into a separate folder.
3. From PowerShell in that folder, check and install:

   ```powershell
   .\scripts\Install.ps1 -GamePath 'D:\Games\AzerothSurvivors\AzerothSurvivors.exe' -CheckOnly
   .\scripts\Install.ps1 -GamePath 'D:\Games\AzerothSurvivors\AzerothSurvivors.exe'
   ```

4. Start the original game, enable **AzerothSurvivorsSpeedGear** in **Options → AddOns**,
   and enter a solo run. Use `/azsg` or `/speedgear` to show the panel.

The package installs `AddOns/AZSSpeedGear` under the game's `benilla-config`
folder and a native `dwmapi.dll` beside the game executable. **Both parts are
required.** No separate controller or launcher needs to stay open. The existing
DragonUI `avrt.dll` is retained. An unrelated existing `dwmapi.dll` is never
overwritten. Keep the complete addon folder, including its localization files.

Commands: `/azsg show`, `/azsg hide`, `/azsg 2`, `/azsg stop`. Hiding the panel
does not stop its heartbeat. Each new run starts at 1x. Selection screens and
pauses request normal speed, then resume the rate chosen for that run. Multiplayer
or an unknown party state prevents activation.

Version 0.3.0 queries the control CVar with `ConsoleExec` after setting it. The
native component receives this synchronous console message through local stdout
and stderr pipes, so switching and stopping no longer wait for a config save.
Unrelated console output is forwarded unchanged under normal load and is not recorded. The config
file remains a fallback if game logging or a future update disables this path.
Queries pulse once per real second; persisted payloads refresh every five seconds,
allowing the game's save debounce to complete even at 0.25x. Both transports share
session and sequence validation, so a delayed file cannot undo a newer request.
If fresh control heartbeats stop, the backend returns to 1x after eight real seconds.

Version 0.4.0 gives each output channel an independent forwarding worker and a
bounded 256 KiB queue. A blocked launcher/console can no longer block control
parsing. On output overload, the oldest queued log bytes may be dropped after
their commands have already been parsed; the dropped-byte counter is diagnostic
and does not count lost speed commands. Healthy console receipts reduce config
scans from ten per second to one; missing pulses restore fast fallback polling.

The panel and `/azsg status` identify the client's sending attempt, not a native
acknowledgement. Actual validated receipt mode, backend setting, heartbeat age,
file-read count and discarded forwarding bytes appear in `AZSSpeedGear-status.json`
beside the game. To read or watch the live report from an extracted package:

```powershell
.\scripts\Status.ps1 -GamePath 'E:\path\AzerothSurvivors.exe' -Watch
```

The viewer is read-only and never launches the game. Old reports show offline.
The sandbox has no supported live native-to-Lua readback, so the UI does not
infer a connected channel from the presence of `ConsoleExec`. The addon-list
and panel title are always **AzerothSurvivorsSpeedGear**; controls retain all
fourteen game languages.

The launcher compares fresh raw game-time publications against independent
integer wall-clock observations. A bounded sliding history intersects the possible
rates allowed by their integer-second timestamps; the requested rate and scaled
client clock never supply elapsed real time. Live matching data maintains
confirmation. Sparse samples can take longer to become conclusive, and missing or
frozen raw snapshots cannot confirm an interpolated clock.
This display delay is separate from command delivery. A new request, substantial
mismatch, freeze or pause clears confirmation. This estimates the observed run
clock, rather than certifying movement, skill behavior or native receipt.
See the [speed investigation](docs/SPEEDINVESTIGATION.md) for reproduced evidence
and the limits of the native timing models.

## Compatibility

At startup the backend scans the current executable for a unique 25 ms simulation
wait, follows its call target and validates unwind metadata and three timing
imports. It does **not** depend on one EXE hash or fixed addresses. Unknown or
ambiguous structures disable acceleration and record the reason in
`AZSSpeedGear.log` beside the game.

**Runtime detection cannot guarantee compatibility with every future version.**
Changes to compiler output, scheduling, DWM loading, CVar persistence or addon
APIs can require maintenance.

Version 0.1.0 was loaded in game **0.130.0** together with SurvivorsDragonUi and
AZSSpellMeter. The panel measured approximately **1.00x and 2.00x**. A 5x request
accelerated the run and a card selection returned the backend to 1x; its exact
panel reading was not recorded. The remaining rates, full gameplay clears,
multiplayer and Wine/Linux have not been validated in the real game. Read
[compatibility details](docs/COMPATIBILITY.md) and [validation evidence](docs/VALIDATION.md).

The native component hooks timing functions in the game process. It does not
patch the EXE on disk. No gameplay telemetry is implemented. The native update
helper and optional entry point contact the fixed GitHub project for stable packages and compatibility
records; it does not upload local game files or saved data.

## Update or uninstall

Exit the game and use the new release's installer to update. Installation receipts
and SHA-256 checks establish which files belong to this addon; changed or unknown
files cause a refusal. Previous owned versions are moved to backups.

**Since 0.6.0, running `AzerothSurvivors.exe` directly triggers automatic plugin
checks.** An ordinary native worker launches a hidden system PowerShell helper
outside DLL initialization and timing hooks. The helper's SHA-256 is embedded in
the native component; missing or modified helpers are not executed.

Checking and pre-downloading happen in the background. The current process keeps
its loaded version; after all game instances exit normally, the helper rechecks
and installs the update for a later launch. Rapid restarts can postpone installation.
Offline failures preserve the existing version. A separate per-game task mutex
deduplicates native and legacy-launcher helpers. No EXE entrypoint patch or change
to DragonUI's avrt.dll is used. A read-only exclusive EXE lease and process checks
protect the short installation swap window without changing executable bytes.
The helper log is `benilla-config/AZSSpeedGear-updates/native-update.log`.

Version 0.5.0's independent entry point remains available for pre-launch checks
or manual recovery when native loading is unavailable:

```powershell
.\scripts\Start.ps1 -GamePath 'E:\path\AzerothSurvivors.exe'
```

It checks the fixed project's latest stable GitHub Release before starting the
game and checks again after the game exits. Package size, GitHub SHA-256 digest,
ZIP paths and the complete file manifest are verified. Installation runs the
already-owned installer, preserves backups and waits for the game to stop.
Network failures retain the existing installation; `-SkipUpdate` skips checking.
This updates the plugin; the game's own updater remains responsible for the game.
Direct EXE launches now perform native-triggered background checks too. The
launcher's `-SkipUpdate` applies only to its game child and restores the parent's
environment after process creation.

A separate scheduled Windows workflow reads the [official native manifest](https://wow.aethus.pl/exe/latest.json)
every six hours. Changed game or scanner fingerprints trigger a temporary-runner
download, hash verification and read-only scanner checks, including required DWM
imports. No game executable is run or redistributed. The public
[compatibility report](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/blob/main/compatibility/windows.json)
records `structural_only` or `unsupported`; unrecognized hashes remain `unknown`.
These are not gameplay certifications. Major engine/API changes still require
maintainer fixes, which the launcher can retrieve once a new stable release exists.
Compatibility records cannot supply executable patches or bypass native checks.
The generated `NativeLocale.lua` is verified against its exact allowed format
and language whitelist; every other managed file retains static hash checks.

```powershell
.\scripts\Uninstall.ps1 -GamePath 'D:\Games\AzerothSurvivors\AzerothSurvivors.exe' -CheckOnly
.\scripts\Uninstall.ps1 -GamePath 'D:\Games\AzerothSurvivors\AzerothSurvivors.exe'
```

Uninstall moves owned files and their receipt to
`benilla-config/AZSSpeedGear-backups` rather than deleting them. Game saves,
shared saved variables, sibling addons and `avrt.dll` are retained.

## Build and test

Requirements: Windows, Visual Studio 2022/2026 with C++ x64 tools and MASM,
Windows SDK, and CMake 3.21 or later. MinHook 1.3.4 is vendored with its license.
The remote Windows build workflow runs the following commands. Several isolated
integration tests require the hosted CI environment and deliberately refuse a
workstation run.

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release --parallel 4
ctest --test-dir build -C Release --output-on-failure
.\scripts\Package.ps1
```

The optional Lua 5.0.3 compatibility test runs when `LUA50_ROOT` points to its
unpacked official source. CI downloads and checks that test-only dependency.
Python inspection utilities use `python -m pip install -r tools/requirements.txt`.
They are not required to run the plugin.

`AZSSpeedGearProbe.exe <game.exe> --selftest` performs a read-only scan, including
refusal tests for an altered duration and duplicate candidates. It does not start
or modify the game. The normal build CI uses synthetic hosts and needs no game
files. The separate, manually dispatched game-acceptance workflow downloads
official files into an ephemeral runner and retains only numerical evidence.

## License

New releases of AzerothSurvivorsSpeedGear use **GPL-3.0-or-later**: the GNU
General Public License, version 3 or, at your option, any later version. You may
redistribute and modify the project under those terms; the complete GPLv3 text
is in [LICENSE](LICENSE).

AZS Speed Controller and MinHook/HDE retain their original MIT and BSD-2-Clause
licenses and copyright notices. See [third-party notices](THIRD_PARTY_NOTICES.md).

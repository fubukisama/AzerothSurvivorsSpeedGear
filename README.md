# AzerothSurvivorsSpeedGear

[简体中文](README.zh-CN.md) · [Downloads](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases)

An in-game speed control addon for **Azeroth Survivors on Windows x64**. Open
`/azsg` to choose 0.5x, 1x, 2x, 3x or 5x, enter a custom rate from 0.25x to 10x,
or request a return to normal speed. The panel displays a measured game-time to
wall-time ratio separately from the requested speed.

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

4. Start the original game, enable **AZS Speed Gear** in **Options → AddOns**,
   and enter a solo run. Use `/azsg` or `/speedgear` to show the panel.

The package installs `AddOns/AZSSpeedGear` under the game's `benilla-config`
folder and a native `dwmapi.dll` beside the game executable. **Both parts are
required.** No separate controller or launcher needs to stay open. The existing
DragonUI `avrt.dll` is retained. An unrelated existing `dwmapi.dll` is never
overwritten.

Commands: `/azsg show`, `/azsg hide`, `/azsg 2`, `/azsg stop`. Hiding the panel
does not stop its heartbeat. Each new run starts at 1x. Selection screens and
pauses request normal speed, then resume the rate chosen for that run. Multiplayer
or an unknown party state prevents activation.

Control uses the game's CVar persistence, so a request, including the stop button,
normally takes about one second to reach the backend. If fresh control heartbeats
stop, the backend returns to 1x after eight real seconds.

## Compatibility

At startup the backend scans the current executable for a unique 25 ms simulation
wait, follows its call target and validates unwind metadata and three timing
imports. It does **not** depend on one EXE hash or fixed addresses. Unknown or
ambiguous structures disable acceleration and record the reason in
`AZSSpeedGear.log` beside the game.

**Runtime detection cannot guarantee compatibility with every future version.**
Changes to compiler output, scheduling, DWM loading, CVar persistence or addon
APIs can require maintenance. This is not an online updater.

Version 0.1.0 was loaded in game **0.130.0** together with SurvivorsDragonUi and
AZSSpellMeter. The panel measured approximately **1.00x and 2.00x**. A 5x request
accelerated the run and a card selection returned the backend to 1x; its exact
panel reading was not recorded. The remaining rates, full gameplay clears,
multiplayer and Wine/Linux have not been validated in the real game. Read
[compatibility details](docs/COMPATIBILITY.md) and [validation evidence](docs/VALIDATION.md).

The native component hooks timing functions in the game process. It does not
patch the EXE on disk. No network updater or telemetry is implemented.

## Update or uninstall

Exit the game and use the new release's installer to update. Installation receipts
and SHA-256 checks establish which files belong to this addon; changed or unknown
files cause a refusal. Previous owned versions are moved to backups.

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
or modify the game. CI uses a synthetic simulation host and needs no game files.

## License

[MIT](LICENSE), with retained MIT attribution for AZS Speed Controller and the
BSD-2-Clause notices for MinHook/HDE. See [third-party notices](THIRD_PARTY_NOTICES.md).

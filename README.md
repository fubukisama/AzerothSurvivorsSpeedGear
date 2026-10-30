# AzerothSurvivorsSpeedGear

[简体中文](README.zh-CN.md) · [Downloads](https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases)

An in-game speed control addon for **Azeroth Survivors on Windows x64**. Click
the persistent floating **Speed** button or use `/azsg` to choose 0.5x, 1x, 2x, 3x or 5x, enter a custom rate from 0.25x to 10x,
or request a return to normal speed. The panel displays a measured game-time to
wall-time ratio separately from the requested speed.

Drag the floating button or the main panel freely; their positions are saved
independently. Closing the panel keeps the floating button available. A new
installation initially shows just the button; existing visibility preferences
are retained.

Once measured speed is close to the requested rate, the floating button shows
that rate, for example **Speed ×2**. An ellipsis marks an unconfirmed change;
pauses or missing confirmation remove the success rate. This uses run-time
measurement rather than treating a request as a native acknowledgement.

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

4. Start the original game, enable **AZS Speed Gear** in **Options → AddOns**,
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

The launcher confirms actual speed using a complete one-second observation window
after the next integer-second boundary (usually 1–2 seconds). This display delay
is separate from command delivery. Small measurement fluctuations retain an
existing confirmation; a new request, substantial mismatch or freeze clears it.

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

# Optional bounded diagnostic records

Open **Details** in the SpeedGear panel and turn on **Diagnostics** to keep a
small timing history. Recording starts off on every game launch. **Keep
snapshot**, disabling recording, leaving the world, or completing the first
guard window retains a report in `AZSSpeedGearDB.diagnosticTrace`. A normal
game exit lets the client write its addon save. Enabling again starts a fresh
window; it does not resume a previously saved recording.

There are at most 128 controller observations and 64 reason events. The first
frame-guard event preserves 32 subsequent controller observations and then
freezes the observation ring; reason events remain bounded. Request and stop
callbacks may call the controller in the same rendered frame, so observation
count is not physical frame count or FPS.

The report contains only whitelisted primitive timing and control fields:

- `wallSecond`: independent integer epoch seconds, not a precise subsecond clock.
- `clientClock` and `clientFrameStep`: scaled client `GetTime` observations;
  they are never divided by the selected speed to invent real frame duration.
- `rawRunTime`/`rawUpdated`: the latest cached raw publication, potentially from
  before the current measurement update; missing or older data remain explicit.
- `target100`/`requested100`: controller requests, not proof of native delivery.
  `nativeReceiptAvailable` is false; an estimate from raw arrival history is
  separately labeled `observedRunEstimate`.
- Phase, active/guard flags, slow-observation count, and explicit reason events
  such as manual speed/stop, phase suspend/resume, guard, channel failure,
  clock failure or world exit. A 1x request alone is never classified as a guard.

The recorder reuses allocated slots while active and does not scan UI objects,
players, chat, combat text or process memory. Export returns copies; old reports
are read through a fixed-capacity whitelist without re-enabling collection.
No external sampler, PresentMon, WPR or game process is started by this feature.

These records help explain controller transitions. They do not establish native
render frame time, identify an expensive thread, prove a memory leak, or certify
that movement and skills advance uniformly. Independent frame presentation and
thread-level evidence remains a separate diagnostic step when needed. Project
validation remains remote-only unless the user explicitly authorizes a specific
local collection session.

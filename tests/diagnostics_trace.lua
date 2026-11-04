-- Stock Lua 5.0 regression; execute only in disposable remote CI.
local Diagnostics = dofile("AddOns/AZSSpeedGear/Diagnostics.lua");
local checks = 0;
local function check(condition, message)
    checks = checks + 1;
    assert(condition, message);
end
local function same(a, b, message) check(a == b, message); end
local function fixture()
    return { wallSecond = 1800000000, clientClock = 1000, rawRunTime = 10,
        rawUpdated = 999.9, phase = "playing", target100 = 500, requested100 = 500,
        active = true, guard = false, observedRunEstimate = 4.98, guardSlowFrames = 0 };
end
local function advance(recorder, context, count)
    local index = 1;
    while (index <= count) do
        context.clientClock = context.clientClock + 0.1;
        context.rawRunTime = context.rawRunTime + 0.1;
        context.rawUpdated = context.clientClock - 0.01;
        recorder:Frame(context);
        index = index + 1;
    end
end

same(AZSSpeedGearDiagnostics, Diagnostics, "one namespace exposes the returned module");
same(Diagnostics.FrameCapacity, 128, "fixed frame capacity");
same(Diagnostics.EventCapacity, 64, "fixed event capacity");
same(Diagnostics.PostGuardFrames, 32, "fixed post-guard window");
local recorder, context = Diagnostics.NewRecorder(), fixture();
same(recorder:IsEnabled(), false, "recording defaults off");
same(recorder:Frame(context), false, "disabled frame capture is a no-op");
same(recorder:Event("manual_speed", context), false, "disabled event capture is a no-op");
local empty = recorder:Export();
same(empty.frameCount, 0, "default has no frames");
same(empty.eventCount, 0, "default has no events");
same(empty.nativeReceiptAvailable, false, "requests are not invented backend receipts");
same(empty.frameClock, "scaled_client_GetTime", "frame-clock domain is explicit");
same(empty.wallClock, "integer_epoch_seconds", "wall time does not invent subsecond precision");
same(empty.speedDomain, "addon_requests_not_native_receipts", "request semantics are explicit");
same(empty.estimateDomain, "raw_run_arrival_estimate", "run estimate is not full gameplay acceptance");
same(empty.observationDomain, "controller_Update_callbacks", "controller callbacks are not physical frames");
same(empty.rawSampleTiming, "cached_before_current_measurement", "raw sample age is explicit");
check(Diagnostics.SanitizeExport(empty) ~= nil, "an empty canonical export sanitizes");

check(recorder:SetEnabled(true, context), "explicit enable starts a fresh trace");
same(recorder:SetEnabled(true, context), false, "repeated enable does not discard data");
same(recorder:SetEnabled("true", context), false, "truthy strings do not enable recording");
check(recorder:Frame(context), "enabled frame captured");
context.clientClock = context.clientClock + 0.4;
context.rawRunTime = context.rawRunTime + 0.4;
recorder:Frame(context);
local sample = recorder:Export();
same(sample.frameCount, 2, "two frames retained");
same(sample.frames[1].clientClockState, "first", "first clock has no invented interval");
same(sample.frames[1].clientFrameStep, nil, "first clock step is unknown");
check(math.abs(sample.frames[2].clientFrameStep - 0.4) < 1e-9, "GetTime step is not divided by target 5x");
same(sample.frames[2].clientClockState, "advance", "advancing client clock is described");
same(sample.frames[2].target100, 500, "target retained");
same(sample.frames[2].requested100, 500, "request retained without receipt claim");
check(math.abs(sample.frames[2].rawRunTime - 10.4) < 1e-9, "raw run time retained");
same(sample.frames[2].active, true, "primitive active flag retained");
same(sample.frames[2].guard, false, "false flag survives copying");
same(sample.frames[2].observedRunEstimate, 4.98, "raw-arrival estimate remains distinct");
same(sample.eventCount, 1, "enable event is recorded once");

-- Every capture copies primitives out of the caller's reusable context.
context.target100 = 300;
same(sample.frames[2].target100, 500, "later caller mutation cannot alter exported frames");
sample.frames[2].rawRunTime = 999999;
sample.events[1].reason = "private_player_name";
local unmodified = recorder:Export();
check(math.abs(unmodified.frames[2].rawRunTime - 10.4) < 1e-9, "exported frame mutation cannot alter recorder slots");
same(unmodified.events[1].reason, "enabled", "exported event mutation cannot alter recorder slots");
same(recorder:Event("private_player_name", context), false, "arbitrary reason strings are refused");
context.chat = "must not be copied"; context.player = "must not be copied";
context.skills = { "must not be copied" };
recorder:Frame(context);
local private = recorder:Export().frames[3];
same(private.chat, nil, "chat is never copied");
same(private.player, nil, "player identity is never copied");
same(private.skills, nil, "skill data is never copied");

-- Fixed rings survive wrap-around without dropping chronology.
recorder:Clear(context);
advance(recorder, context, 300);
local wrapped = recorder:Export();
same(wrapped.frameCount, 128, "frame storage never exceeds 128 rows");
same(wrapped.frameSequence, 300, "total frame sequence advances without storing every frame");
same(wrapped.frames[1].sequence, 173, "frame ring starts at oldest retained sample");
same(wrapped.frames[128].sequence, 300, "frame ring ends at newest sample");
local index = 1;
while (index <= 150) do recorder:Event("manual_speed", context); index = index + 1; end
wrapped = recorder:Export();
same(wrapped.eventCount, 64, "event storage never exceeds 64 rows");
same(wrapped.events[1].sequence, 88, "event ring starts in chronological order after wrapping");
same(wrapped.events[64].sequence, 151, "event ring ends at latest sequence including clear event");
check(Diagnostics.SanitizeExport(wrapped) ~= nil, "wrapped canonical data passes passive import validation");

-- Retain the first guard and exactly 32 following accepted frame samples.
recorder:Clear(context);
advance(recorder, context, 160);
context.beforeTarget100 = 500; context.beforeRequested100 = 500;
context.target100 = 100; context.requested100 = 100; context.guard = true;
check(recorder:Event("frame_guard", context), "guard records a cause only when explicitly supplied");
context.beforeTarget100 = nil; context.beforeRequested100 = nil;
advance(recorder, context, 31);
local beforeFreeze = recorder:Export();
same(beforeFreeze.framesFrozen, false, "31 following frames do not prematurely freeze");
same(beforeFreeze.postFramesCaptured, 31, "post-frame counter is exact");
recorder:Event("frame_guard", context);
advance(recorder, context, 1);
local frozen = recorder:Export();
same(frozen.framesFrozen, true, "the 32nd following frame freezes the window");
same(frozen.frameSequence, 192, "a repeated guard event does not restart the first window");
same(frozen.frames[1].sequence, 65, "128-row frozen ring retains 96 pre/trigger rows and 32 post rows");
same(frozen.frames[128].sequence, 192, "frozen end is exact");
same(frozen.triggerFrameSequence, 160, "first guard attaches to latest captured frame");
same(frozen.postFramesCaptured, 32, "frozen window has bounded post context");
same(frozen.events[2].beforeTarget100, 500, "guard cause retains its explicit former target");
same(frozen.events[2].beforeRequested100, 500, "guard cause retains its former addon request");
same(frozen.events[2].target100, 100, "guard event retains the requested restoration target");
same(recorder:Frame(context), false, "frozen frames do not keep overwriting context");
context.clientClock = context.clientClock + 1;
context.wallSecond = context.wallSecond + 1;
check(recorder:Event("phase_suspend", context), "later events remain bounded and available after frame freeze");
local afterFreeze = recorder:Export();
same(afterFreeze.frameSequence, 192, "events do not advance or unfreeze frame ring");
same(afterFreeze.events[table.getn(afterFreeze.events)].clientClockState, "not_sampled", "old frozen interval is not attached to a later event");
check(Diagnostics.SanitizeExport(afterFreeze) ~= nil, "a frozen canonical trace sanitizes");

-- Missing, repeated, backwards and corrected clocks never invent real FPS.
recorder:Clear(context); context.guard = false;
context.clientClock = 50; recorder:Frame(context); recorder:Frame(context);
context.clientClock = 49; recorder:Frame(context);
context.clientClock = nil; recorder:Frame(context);
context.clientClock = 60; recorder:Frame(context);
local clocks = recorder:Export();
same(clocks.frames[2].clientClockState, "repeated", "repeated client clock is visible");
same(clocks.frames[2].clientFrameStep, 0, "repeat is a zero virtual step, not a physical-duration estimate");
same(clocks.frames[3].clientClockState, "backwards", "backwards correction is visible");
same(clocks.frames[3].clientFrameStep, nil, "negative duration is not exported as a valid step");
same(clocks.frames[4].clientClockState, "unavailable", "missing client clock is visible");
same(clocks.frames[5].clientClockState, "first", "clock recovery starts a fresh anchor");

context.wallSecond = 1.5; context.clientClock = 0/0; context.rawRunTime = 1/0;
context.rawUpdated = -1; context.phase = "private player or chat text";
context.target100 = 1001; context.requested100 = "500"; context.active = "true";
context.guard = {}; context.observedRunEstimate = 1/0; context.guardSlowFrames = -1;
check(recorder:Frame(context), "a numeric fault produces a bounded unknown-field sample");
local faulty = recorder:Export().frames[6];
same(faulty.wallSecond, nil, "fractional wall precision is not invented");
same(faulty.clientClock, nil, "NaN client clock removed");
same(faulty.rawRunTime, nil, "infinite raw run time removed");
same(faulty.rawUpdated, nil, "negative publication stamp removed");
same(faulty.phase, "unknown", "unrecognized phase cannot leak arbitrary text");
same(faulty.target100, nil, "out-of-domain target removed");
same(faulty.requested100, nil, "string rate is not executed or coerced");
same(faulty.active, nil, "truthy nonboolean active field removed");
same(faulty.guard, nil, "table guard field removed");
same(faulty.observedRunEstimate, nil, "infinite estimate removed");
same(faulty.guardSlowFrames, nil, "negative guard count removed");
same(recorder:Frame(nil), false, "missing reusable context does not add a frame");

-- Toggle and clear retain no hidden old recording state.
context = fixture();
check(recorder:SetEnabled(false, context), "explicit disable stops recording");
local stopped = recorder:Export();
same(stopped.recordingAtExport, false, "disabled export reports stopped state");
local stoppedCount = stopped.frameCount;
same(recorder:Frame(context), false, "disabled recorder does not add another frame");
same(recorder:Event("frame_guard", context), false, "disabled recorder does not latch a new guard");
same(recorder:Export().frameCount, stoppedCount, "off preserves already captured data only");
check(recorder:SetEnabled(true, context), "re-enable begins a new bounded session");
local restarted = recorder:Export();
same(restarted.frameCount, 0, "re-enable clears old frames");
same(restarted.eventCount, 1, "re-enable keeps only its new enable event");
same(restarted.triggerFrameSequence, nil, "re-enable clears an older trigger");
same(restarted.framesFrozen, false, "re-enable clears frozen state");
recorder:SetEnabled(false, context); recorder:Clear(context);
same(recorder:IsEnabled(), false, "clear never re-enables disabled recording");
same(recorder:Export().eventCount, 0, "clearing while off creates no events");

-- Stored data is never used as active state, and bounded fixed reads ignore
-- attacker-supplied extra fields and do not call __index metamethods.
local saved = Diagnostics.NewRecorder();
saved:SetEnabled(true, fixture()); local savedContext = fixture(); advance(saved, savedContext, 3);
local report = saved:Export(); report.extra = function() error("untrusted callback"); end;
report.frames[1].player = "private name";
local copied = Diagnostics.SanitizeExport(report);
check(copied ~= nil, "known saved schema sanitizes to a detached copy");
same(copied.extra, nil, "saved callbacks and extra fields are dropped");
same(copied.frames[1].player, nil, "saved private fields are dropped");
copied.frames[1].target100 = 25;
same(report.frames[1].target100, 500, "sanitization creates detached frame copies");
same(Diagnostics.NewRecorder():IsEnabled(), false, "saved recording flag never restarts a new recorder");
local trapCalls = 0;
local trapped = setmetatable({}, { __index = function() trapCalls = trapCalls + 1; error("untrusted __index"); end });
same(Diagnostics.SanitizeExport(trapped), nil, "foreign metadata is refused with raw reads");
same(trapCalls, 0, "saved metatable lookup is not executed");
same(Diagnostics.SanitizeExport("return malicious()"), nil, "saved strings are not evaluated");
report.frameCount = 129;
same(Diagnostics.SanitizeExport(report), nil, "oversized saved frame counts refused before scanning");
report = saved:Export(); report.eventCount = 65;
same(Diagnostics.SanitizeExport(report), nil, "oversized saved event counts refused");
report = saved:Export(); report.nativeReceiptAvailable = true;
same(Diagnostics.SanitizeExport(report), nil, "saved data cannot invent native receipt capability");
report = saved:Export(); report.events[1].reason = "unknown/private text";
same(Diagnostics.SanitizeExport(report), nil, "unknown saved reasons are refused");
report = saved:Export(); report.frames[2].sequence = report.frames[1].sequence;
same(Diagnostics.SanitizeExport(report), nil, "nonchronological saved frames refused");
report = saved:Export(); report.frames[2].clientFrameStep = -1;
same(Diagnostics.SanitizeExport(report), nil, "invalid saved positive-step semantics refused");
report = saved:Export(); report.frameCount = 0/0;
same(Diagnostics.SanitizeExport(report), nil, "NaN saved counts refused");

print("Diagnostics trace: " .. checks .. " bounded storage, clock semantics, lifecycle and export checks passed.");

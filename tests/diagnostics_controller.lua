-- Remote CI only. Exercise the production controller with independent inputs.
AZSSpeedGear_TEST = true;
local Diagnostics = dofile("AddOns/AZSSpeedGear/Diagnostics.lua");
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");
local checks = 0;
local function check(condition, message) checks = checks + 1; assert(condition, message); end
local function countReason(controller, reason)
    local report = controller:ExportDiagnostics();
    local count, last = 0, nil;
    if (report) then
        for _, row in ipairs(report.events) do
            if (row.reason == reason) then count = count + 1; last = row; end
        end
    end
    return count, last;
end
local function lastFrame(controller)
    local report = controller:ExportDiagnostics();
    return report.frames[table.getn(report.frames)];
end
local function fixture(moduleAvailable, enabled, spy)
    local state = { physical = 0.125, client = 1000, run = 10, raw = 10,
        updated = 1000, phase = "playing", solo = true, rate = 5,
        calls = {}, commands = {}, contextChanges = 0, frameInputs = 0, offset = 0 };
    local function read(key, value)
        state.calls[key] = (state.calls[key] or 0) + 1;
        return value;
    end
    if (moduleAvailable) then AZSSpeedGearDiagnostics = Diagnostics;
    else AZSSpeedGearDiagnostics = nil; end
    if (spy) then
        AZSSpeedGearDiagnostics = { NewRecorder = function()
            local recorder = Diagnostics.NewRecorder();
            local originalFrame = recorder.Frame;
            function recorder:Frame(context)
                if (state.context and state.context ~= context) then state.contextChanges = state.contextChanges + 1; end
                state.context = context; state.frameInputs = state.frameInputs + 1;
                if (state.throwFrame) then error("fixture diagnostic failure"); end
                return originalFrame(self, context);
            end
            return recorder;
        end };
    end
    local controller = AZSSpeedGear.NewController({
        now = function()
            local now = 1800000000 + math.floor(state.physical) + state.offset;
            if (state.badWall) then now = nil; end
            return read("now", now);
        end,
        random = function() return read("random", 321); end,
        phase = function() return read("phase", state.phase); end,
        isSolo = function() return read("solo", state.solo); end,
        runTime = function() return read("run", state.run); end,
        clientClock = function()
            local value = state.client;
            if (state.badClock) then value = nil; end
            return read("clock", value);
        end,
        rawRunSample = function()
            read("raw", true);
            return { t = state.raw, updated = state.updated };
        end,
        register = function() return read("register", true); end,
        send = function(command)
            read("send", true);
            table.insert(state.commands, command);
            return not state.rejectSend;
        end,
        pulse = function() return read("pulse", true); end
    });
    function state:step(seconds)
        self.physical = self.physical + seconds;
        self.client = self.client + self.rate * seconds;
        if (self.phase == "playing") then
            self.run = self.run + self.rate * seconds;
            self.raw = self.raw + self.rate * seconds;
        end
        self.updated = self.client;
        controller:Update();
    end
    controller:Update();
    local before = state.calls.now + state.calls.clock + state.calls.raw;
    if (enabled) then check(controller:SetDiagnosticsEnabled(true), "explicit controller opt-in works"); end
    check(state.calls.now + state.calls.clock + state.calls.raw == before, "enabling uses cached values without another API observation");
    return state, controller;
end

-- Missing module remains compatible with old controller-only fixtures.
local missing, missingController = fixture(false, false);
check(not missingController:DiagnosticsEnabled() and missingController:ExportDiagnostics() == nil,
    "missing optional module leaves diagnostics unavailable and off");
check(not missingController:SetDiagnosticsEnabled(true), "missing module does not invent an enabled trace");
local frames, events, frozen, post = missingController:DiagnosticCounts();
check(frames == 0 and events == 0 and frozen == false and post == 0, "missing module has safe primitive counts");

local off, offController = fixture(true, false);
local on, onController = fixture(true, true, true);
check(offController:ExportDiagnostics() == nil, "module present but default-off creates no report");
local function exercise(state, controller)
    check(controller:RequestSpeed(500), "request accepted before the independent boundary observations");
    local index = 1;
    while (index <= 4) do state:step(0.05); index = index + 1; end
    check(controller.speed100 == 500 and controller.frameGuardSlowFrames == 0,
        "exact 0.25-second steps do not cross the existing strict guard boundary");
    state:step(0.0501); state:step(0.0501);
    check(controller.speed100 == 500 and controller.frameGuardSlowFrames == 2,
        "two over-budget observations retain the requested rate");
    state:step(0.0501);
    check(controller.speed100 == 100 and controller.desiredSpeed100 == 100 and controller.frameGuardTripped,
        "third over-budget observation restores the unchanged 1x contract");
    check(controller:RequestSpeed(300), "manual retry remains available");
    controller:EmergencyStop();
    state.phase = "paused"; state:step(0.02);
    state.phase = "playing"; state:step(0.02);
    state.phase = "ready"; state:step(0.02); state:step(0.02);
    controller:Shutdown();
end
exercise(missing, missingController); exercise(off, offController); exercise(on, onController);
for name, count in pairs(off.calls) do
    check(on.calls[name] == count and missing.calls[name] == count,
        "diagnostics on/off/missing preserve game and clock API call counts: " .. name);
end
check(table.getn(off.commands) == table.getn(on.commands) and table.getn(on.commands) == table.getn(missing.commands),
    "diagnostics preserve command count");
for index, command in ipairs(off.commands) do
    check(on.commands[index] == command and missing.commands[index] == command, "diagnostics preserve exact command payload/order " .. index);
end
check(on.frameInputs > 3 and on.contextChanges == 0, "controller observations reuse one context table");
local count, guard = countReason(onController, "frame_guard");
check(count == 1 and guard.beforeTarget100 == 500 and guard.beforeRequested100 == 500,
    "automatic restoration records exactly one actual trigger and its former rate");
check(guard.target100 == 100 and guard.requested100 == 100 and guard.guard == true and guard.guardSlowFrames == 3,
    "trigger event captures final fallback plus the pre-reset three-observation evidence");
check(guard.clientFrameStep > 0.25 and guard.clientFrameStep < 0.251,
    "guard stores the actual scaled client interval rather than a target-derived physical interval");
local report = onController:ExportDiagnostics();
check(not onController:DiagnosticsEnabled() and report.recordingAtExport == false, "world exit stops recording before export");
check(report.observationDomain == "controller_Update_callbacks" and report.nativeReceiptAvailable == false,
    "export never labels controller callbacks as physical frames or requests as backend receipts");
check(Diagnostics.SanitizeExport(report) ~= nil, "controller export satisfies the bounded saved schema");
count = countReason(onController, "world_exit"); check(count == 1, "actual world exit is recorded once");

-- Raw metadata comes from the existing measurement cache, never the smooth run getter.
local cached, cachedController = fixture(true, true, true);
local oldRaw = cachedController.rawRunValue;
cached.run = 2000; cached.raw = 20; cached:step(0.01);
local row = lastFrame(cachedController);
check(row.rawRunTime == oldRaw and row.rawRunTime ~= cached.run and cachedController.rawRunValue == cached.raw,
    "pre-measurement observation retains the previous true raw publication and marks its timing");
check(cachedController:ExportDiagnostics().rawSampleTiming == "cached_before_current_measurement", "cached raw timing is explicit");

-- Gate events describe actual transition paths, not every 1x state.
local gated, gatedController = fixture(true, true);
gatedController:RequestSpeed(300);
gated.phase = "paused"; gated:step(0.02); gated:step(0.02);
count, row = countReason(gatedController, "phase_suspend");
check(count == 1 and row.phase == "paused" and row.target100 == 300 and row.requested100 == 100 and not row.active,
    "pause suspends request but retains target, without repeating the same event");
gated.phase = "choosing"; gated:step(0.02);
count, row = countReason(gatedController, "phase_suspend");
check(count == 2 and row.phase == "choosing", "a distinct suspended phase transition is retained once");
gated.phase = "playing"; gated:step(0.02);
count, row = countReason(gatedController, "phase_resume");
check(count == 1 and row.phase == "playing" and row.target100 == 300 and row.requested100 == 300 and row.active,
    "resuming the playing phase records the retained request");
gated.solo = false; gated:step(0.02); gated:step(0.02);
count = countReason(gatedController, "coop"); check(count == 1, "cooperative gate transition is recorded once");
gated.solo = nil; gated:step(0.02); gated:step(0.02);
count = countReason(gatedController, "solo_unavailable"); check(count == 1, "unknown-solo gate transition is recorded once");
gated.solo = true; gated:step(0.02);
count = countReason(gatedController, "activity_resume"); check(count == 1, "same-phase gate recovery is not mislabeled phase resume");
gated.badWall = true; gated:step(0.02); gated:step(0.02);
count = countReason(gatedController, "wall_clock_unavailable"); check(count == 1, "missing wall clock transition does not flood events");
gated.badWall = false; gated:step(0.02);
gated.offset = -5; gated:step(0.02); gated:step(0.02);
count = countReason(gatedController, "wall_clock_backwards"); check(count == 1, "a wall-clock correction is recorded once without changing control");
gated.phase = "ready"; gated:step(0.02);
local resets = countReason(gatedController, "run_reset");
gated:step(0.02); gated:step(0.02); gated:step(0.02);
check(countReason(gatedController, "run_reset") == resets, "stable ready state does not flood run-reset events");
gated.phase = "playing"; gated:step(0.02); gated.phase = "dead"; gated:step(0.02);
resets = countReason(gatedController, "run_reset"); gated:step(0.02); gated:step(0.02);
check(countReason(gatedController, "run_reset") == resets, "stable dead state does not flood run-reset events");

local clocks, clockController = fixture(true, true);
clockController:RequestSpeed(300);
clocks.badClock = true; clocks:step(0.02); clocks:step(0.02); clocks:step(0.02);
count = countReason(clockController, "client_clock_unavailable");
check(count == 1 and clockController.speed100 == 300 and not clockController.frameGuardTripped,
    "clock absence is observational evidence, not an invented protection trigger");
clocks.badClock = false; clocks:step(0.02);
clocks.client = clocks.client - 2; clockController:Update();
count = countReason(clockController, "client_clock_backwards"); check(count == 1, "backwards client correction is retained");
clockController:Update(); clockController:Update(); clockController:Update();
count = countReason(clockController, "client_clock_repeated");
check(count >= 1 and count <= 2, "repeated controller observations are transition events, not one event per callback");
check(countReason(clockController, "frame_guard") == 0, "invalid and repeated clocks never become protection events");

local rejected, rejectedController = fixture(true, true);
check(not rejectedController:RequestSpeed(20), "out-of-range speed remains rejected");
count = countReason(rejectedController, "request_rejected"); check(count == 1, "an actual rejected request is recorded");
rejectedController:RequestSpeed(500); rejected.rejectSend = true;
check(not rejectedController:RequestSpeed(300), "send failure remains rejected by the same transport path");
count, row = countReason(rejectedController, "send_failed");
check(count == 1 and row.beforeTarget100 == 300 and row.beforeRequested100 == 300,
    "failed emission records the rate that actually failed");
check(row.target100 == 300 and row.requested100 == 100 and row.active == false and not rejectedController.bridgeReady,
    "failed emission records fallback state without changing the existing retained-target semantics");
rejectedController:Update(); rejectedController:Update();
count = countReason(rejectedController, "channel_unavailable"); check(count == 1, "failed channel is a transition, not a frame flood");
check(countReason(rejectedController, "frame_guard") == 0, "send failure is not classified as frame protection");

-- A recorder fault must not interrupt the existing safety controller.
local fault, faultController = fixture(true, true, true); fault.throwFrame = true;
check(faultController:RequestSpeed(500), "trace failure does not reject a valid game request");
check(not faultController:DiagnosticsEnabled(), "recorder failure disables only tracing");
fault:step(0.0501); fault:step(0.0501); fault:step(0.0501);
check(faultController.frameGuardTripped and faultController.speed100 == 100,
    "three-observation protection remains effective after a recorder failure");

AZSSpeedGearDiagnostics = Diagnostics;
print("Diagnostics controller: " .. checks .. " API parity, exact guard, lifecycle and cause checks passed.");

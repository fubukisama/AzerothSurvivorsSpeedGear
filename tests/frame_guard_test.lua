-- Remote-CI only: stock Lua 5.0, run from the repository root.
-- Physical time, raw server progress and the client clock are independent
-- fixture inputs. A selected multiplier never supplies any of those clocks.
AZSSpeedGear_TEST = true;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");

local epoch = 1800000000;
local checks = 0;
local failures = {};
local function check(condition, message)
    checks = checks + 1;
    if (not condition) then table.insert(failures, message); print("FAIL: " .. message); end
end

local function fixture(serverRate, clientRate)
    local state = { physical = 0.125, run = 100, client = 1000, phase = "playing",
        serverRate = serverRate, clientRate = clientRate, sent = {}, clockMode = "normal",
        movementVirtual = 0, rejectSend = false };
    local function readClock()
        if (state.clockMode == "missing") then return nil; end
        if (state.clockMode == "nan") then return 0 / 0; end
        if (state.clockMode == "infinite") then return 1 / 0; end
        if (state.clockMode == "negative") then return -1; end
        if (state.clockMode == "zero") then return 0; end
        if (state.clockMode == "throw") then error("fixture clock unavailable"); end
        if (state.clockMode == "frozen" or state.clockMode == "backwards") then return state.clockOverride; end
        return state.client;
    end
    local meter = AZSSpeedGear.NewController({
        now = function() return epoch + math.floor(state.physical); end,
        random = function() return 321; end,
        phase = function() return state.phase; end,
        isSolo = function() return true; end,
        runTime = function() return state.run; end,
        clientClock = readClock,
        rawRunSample = function() return { t = state.run, updated = state.client }; end,
        register = function() return true; end,
        send = function(command)
            if (state.rejectSend) then return false; end
            table.insert(state.sent, command); return true;
        end,
        pulse = function() return true; end
    });
    function state:step(seconds)
        self.physical = self.physical + seconds;
        self.client = self.client + self.clientRate * seconds;
        if (self.phase == "playing") then
            self.run = self.run + self.serverRate * seconds;
            -- This is a documented engine-model oracle, never a controller
            -- input or proof of the installed game's actual movement rate.
            self.movementVirtual = self.movementVirtual + math.min(self.clientRate * seconds, 0.25);
        end
        if (self.clockMode == "backwards") then self.clockOverride = self.clockOverride - 0.1; end
        meter:Update();
    end
    function state:frames(count, seconds)
        local index = 1;
        while (index <= count) do self:step(seconds); index = index + 1; end
    end
    function state:request(value)
        local accepted = meter:RequestSpeed(value);
        -- A real, short observation frame primes either a freshly reset or a
        -- request-time anchor. This is independent of the requested multiplier.
        self:step(1 / 60);
        return accepted;
    end
    meter:Update();
    return state, meter;
end

local function latest(state) return state.sent[table.getn(state.sent)]; end
local function commandIs(state, suffix)
    local command = latest(state);
    return type(command) == "string" and string.find(command, suffix .. "$") ~= nil;
end

-- The selected rate and server clock are both 2x, but five callbacks/real second
-- give an independent 0.4s client-frame gap. A 0.25s frame cap would move only
-- 1.25 virtual seconds per real second. The guard must stop that acceleration.
local slow, guarded = fixture(2, 2);
check(slow:request(200), "the independent x2 request is accepted before slow-frame evidence");
local sentBefore = table.getn(slow.sent);
slow:frames(2, 0.2);
check(guarded.speed100 == 200 and guarded.desiredSpeed100 == 200,
    "two slow observations alone must not stop acceleration");
slow:step(0.2);
check(guarded.active and guarded.speed100 == 100 and guarded.desiredSpeed100 == 100,
    "three consecutive 0.4s client-frame gaps restore the active request and retained target to x1");
check(table.getn(slow.sent) == sentBefore + 1 and commandIs(slow, "|100|1"),
    "protection immediately emits one fresh active SG1 x1 request");
check(guarded.frameGuardTripped == true, "the automatic restore leaves a reason for the user-visible prompt");
check(guarded.confirmedSpeed100 == nil, "automatic restore invalidates an older success caption");
print("ORACLE slow fixture: real callback_hz=5 client_rate=2 raw_server_rate=2 client_frame_gap=0.4 capped_movement_rate=1.25");

-- Explicit fixture backend response to the observed stop, independent of the
-- user's former selected value. Smooth frames must never silently reselect x2.
slow.serverRate = 1; slow.clientRate = 1;
local afterStop = table.getn(slow.sent);
slow:frames(600, 1 / 60);
local onlyNormal = true;
local sentIndex = afterStop + 1;
while (sentIndex <= table.getn(slow.sent)) do
    if (not string.find(slow.sent[sentIndex], "|100|1$")) then onlyNormal = false; end
    sentIndex = sentIndex + 1;
end
check(guarded.speed100 == 100 and guarded.desiredSpeed100 == 100 and onlyNormal,
    "stable recovery frames and heartbeats do not automatically reaccelerate");
check(guarded.frameGuardTripped == true, "the reason remains available until an explicit user action or a new run");

check(slow:request(200), "a deliberate manual retry can select x2 again");
check(guarded.speed100 == 200 and guarded.desiredSpeed100 == 200 and guarded.frameGuardTripped ~= true,
    "manual selection clears the latched prompt and starts fresh observations");
slow.serverRate = 2; slow.clientRate = 2;
slow:frames(2, 0.2);
check(guarded.speed100 == 200, "a manual retry does not inherit the previous slow-frame count");
slow:step(0.2);
check(guarded.speed100 == 100 and commandIs(slow, "|100|1"),
    "a new manual retry is protected again after new sustained slow evidence");

local quick, quickMeter = fixture(2, 2);
check(quick:request(200), "high-frequency fixture accepts x2");
quick:frames(600, 1 / 60);
check(quickMeter.speed100 == 200 and quickMeter.desiredSpeed100 == 200 and quickMeter.frameGuardTripped ~= true,
    "60 real updates per second with a 2x client clock retain the selected x2 rate");

local spikes, spikeMeter = fixture(2, 2);
spikes:request(200);
spikes:frames(60, 1 / 60);
spikes:frames(2, 0.2);
spikes:step(1 / 60);
spikes:frames(2, 0.2);
spikes:step(1 / 60);
check(spikeMeter.speed100 == 200 and spikeMeter.frameGuardTripped ~= true,
    "isolated one/two-frame hitches separated by a good frame do not trigger a restore");

local edge, edgeMeter = fixture(2, 2);
edge:request(200);
edge:frames(8, 0.125);
check(edgeMeter.speed100 == 200 and edgeMeter.frameGuardTripped ~= true,
    "a client-frame gap of exactly 250ms stays on the allowed boundary");

local fractional, fractionalMeter = fixture(0.5, 0.5);
fractional:request(50);
fractional:frames(12, 0.6);
check(fractionalMeter.speed100 == 50 and fractionalMeter.desiredSpeed100 == 50
    and fractionalMeter.frameGuardTripped ~= true,
    "protection never turns a manually selected slow-motion rate into faster x1");

-- A long inactive period is not a rendered active frame; each resume starts a
-- fresh observation baseline while retaining this run's selected multiplier.
local phases = { "paused", "choosing" };
local phaseIndex = 1;
while (phaseIndex <= table.getn(phases)) do
    local paused, pausedMeter = fixture(2, 2);
    paused:request(200); paused:frames(2, 0.2);
    paused.phase = phases[phaseIndex]; pausedMeter:Update();
    paused:step(20);
    check(not pausedMeter.active and pausedMeter.speed100 == 100 and pausedMeter.desiredSpeed100 == 200,
        phases[phaseIndex] .. " suspends acceleration and retains the manual request");
    paused.phase = "playing"; pausedMeter:Update(); pausedMeter:Update();
    check(pausedMeter.speed100 == 200 and pausedMeter.frameGuardTripped ~= true,
        "resuming after " .. phases[phaseIndex] .. " does not count the entire pause as a slow frame");
    paused:frames(2, 0.2);
    check(pausedMeter.speed100 == 200, "resume clears pre-pause slow observations for " .. phases[phaseIndex]);
    paused:step(0.2);
    check(pausedMeter.speed100 == 100 and pausedMeter.frameGuardTripped == true,
        "fresh sustained slow frames after " .. phases[phaseIndex] .. " still trigger protection");
    paused.phase = phases[phaseIndex]; pausedMeter:Update();
    paused.phase = "playing"; pausedMeter:Update();
    check(pausedMeter.speed100 == 100 and pausedMeter.desiredSpeed100 == 100 and pausedMeter.frameGuardTripped == true,
        phases[phaseIndex] .. " cannot automatically resume a rate already stopped by protection");
    phaseIndex = phaseIndex + 1;
end

local invalidModes = { "missing", "nan", "infinite", "negative", "zero", "frozen", "backwards", "throw" };
local invalidIndex = 1;
while (invalidIndex <= table.getn(invalidModes)) do
    local invalid, invalidMeter = fixture(2, 2);
    invalid:request(200);
    invalid.clockMode = invalidModes[invalidIndex]; invalid.clockOverride = invalid.client;
    invalid:frames(30, 0.2);
    check(invalidMeter.speed100 == 200 and invalidMeter.desiredSpeed100 == 200
        and invalidMeter.frameGuardTripped ~= true,
        "unusable client clock does not invent slow-frame evidence: " .. invalidModes[invalidIndex]);
    check(invalidMeter.confirmedSpeed100 == nil,
        "unusable client clock cannot provide speed confirmation: " .. invalidModes[invalidIndex]);
    invalidIndex = invalidIndex + 1;
end

-- Lifecycle cleanup and transport failure retain the existing safety contracts.
guarded:EmergencyStop();
check(guarded.speed100 == 100 and guarded.desiredSpeed100 == 100 and guarded.frameGuardTripped ~= true,
    "manual emergency stop clears the automatic-restore prompt");
slow.serverRate = 2; slow.clientRate = 2; slow:request(200); slow:frames(3, 0.2);
slow.phase = "ready"; guarded:Update();
check(guarded.desiredSpeed100 == 100 and guarded.frameGuardTripped ~= true,
    "a new run clears the old automatic-restore prompt and retained multiplier");
slow.phase = "playing"; guarded:Update(); slow:request(200); slow:frames(3, 0.2);
guarded:Shutdown();
check(not guarded.active and guarded.desiredSpeed100 == 100 and guarded.frameGuardTripped ~= true
    and commandIs(slow, "|100|0"), "world exit clears protection history and emits inactive normal speed");

local rejected, rejectedMeter = fixture(2, 2);
rejected:request(200); rejected:frames(2, 0.2); rejected.rejectSend = true; rejected:step(0.2);
check(not rejectedMeter.active and not rejectedMeter.bridgeReady and rejectedMeter.speed100 == 100
    and rejectedMeter.desiredSpeed100 == 100 and rejectedMeter.sendStatus == "unavailable",
    "a failed automatic-restore transport becomes unavailable instead of claiming a backend receipt");

assert(table.getn(failures) == 0, table.concat(failures, "; "));
print("Frame guard: " .. checks .. " independent clock, latch, lifecycle and transport checks passed.");

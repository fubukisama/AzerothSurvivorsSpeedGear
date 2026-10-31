-- WoW 1.12 / Lua 5.0: no modern Lua operators or modern frame callbacks.
AZSSpeedGear = {};
local Gear = AZSSpeedGear;
local I18n = AZSSpeedGearI18n;
local function tr(key) return I18n.Text(key); end
local COMMAND_CVAR = "AZSSpeedGearCommand";
local MIN_SPEED = 25;
local MAX_SPEED = 1000;
-- Current engine movement time is capped at 250ms per client update. Three
-- consecutive over-budget updates are evidence, unlike a single loading hitch.
local FRAME_STEP_LIMIT = 0.25;
local FRAME_GUARD_COUNT = 3;

local function finiteNumber(value)
    return type(value) == "number" and value == value and value > -1e100 and value < 1e100;
end

local function safeCall(fn)
    if (type(fn) ~= "function") then return nil; end
    local ok, value = pcall(fn);
    if (ok) then return value; end
    return nil;
end

local function integerText(value)
    return string.format("%.0f", value);
end

local function speedText(value)
    local text = string.format("%.2f", value / 100);
    text = string.gsub(text, "0+$", "");
    text = string.gsub(text, "%.$", "");
    return text;
end

-- Dependencies keep the protocol and state transitions testable without a client.
function Gear.NewController(api)
    local self = {};
    self.api = api;
    self.sequence = 0;
    self.speed100 = 100;
    self.desiredSpeed100 = 100;
    self.active = false;
    self.phase = nil;
    self.solo = nil;
    self.lastSent = nil;
    self.lastPulse = nil;
    self.measured = nil;
    self.measurementLower = nil;
    self.measurementUpper = nil;
    self.measureBuckets = {};
    self.rawProgressAt = nil;
    self.confirmedSpeed100 = nil;
    self.measurePendingAt = nil;
    self.measureUncertainty = nil;
    self.measureRawAge = nil;
    self.measureFrameWall = nil;
    self.measureFrameClock = nil;
    self.confirmedAt = nil;
    self.measureStart = nil;
    self.measureRun = nil;
    self.previousRun = nil;
    self.lastObservedRun = nil;
    self.bridgeReady = false;
    self.sendStatus = "unavailable";
    self.writeFailed = false;
    self.initialized = false;
    self.frameGuardTripped = false;
    self.frameGuardClock = nil;
    self.frameGuardSlowFrames = 0;

    local now = safeCall(api.now);
    local random = safeCall(api.random);
    if (not finiteNumber(now) or now < 1) then now = 1; end
    if (not finiteNumber(random)) then random = 1; end
    random = math.floor(random);
    if (random < 1 or random > 999) then random = 1; end
    self.session = math.floor(now) * 1000 + random;
    if (type(api.register) == "function" and type(api.send) == "function") then
        local ok, result = pcall(api.register);
        self.bridgeReady = ok and result ~= false;
        if (self.bridgeReady) then self.sendStatus = "file_only"; end
    end

    function self:RealTime()
        local value = safeCall(self.api.now);
        if (not finiteNumber(value) or value < 1) then return nil; end
        return math.floor(value);
    end

    function self:ResetMeasurement()
        self.measured = nil;
        self.measurementLower = nil;
        self.measurementUpper = nil;
        self.measureBuckets = {};
        self.rawRunValue = nil;
        self.rawRunUpdated = nil;
        self.rawSeenAt = nil;
        self.rawProgressAt = nil;
        self.measurementMismatch = false;
        self.confirmedSpeed100 = nil;
        self.measurePendingAt = nil;
        self.measureUncertainty = nil;
        self.measureRawAge = nil;
        self.measureFrameWall = nil;
        self.measureFrameClock = nil;
        self.confirmedAt = nil;
        self.measureStart = nil;
        self.measureRun = nil;
        self.previousRun = nil;
    end

    function self:ResetFrameGuardObservation(clock)
        self.frameGuardClock = nil;
        if (finiteNumber(clock) and clock > 0) then self.frameGuardClock = clock; end
        self.frameGuardSlowFrames = 0;
    end

    function self:ObserveFrameGuard(clock)
        if (not self.active or self.speed100 <= 100) then
            self:ResetFrameGuardObservation(clock);
            return false;
        end
        if (not finiteNumber(clock) or clock <= 0) then
            self:ResetFrameGuardObservation();
            return false;
        end
        local previous = self.frameGuardClock;
        self.frameGuardClock = clock;
        if (not finiteNumber(previous) or clock <= previous) then
            -- A repeated, missing or corrected clock is not a slow-frame sample.
            self.frameGuardSlowFrames = 0;
            return false;
        end
        if (clock - previous > FRAME_STEP_LIMIT) then
            self.frameGuardSlowFrames = self.frameGuardSlowFrames + 1;
        else self.frameGuardSlowFrames = 0; end
        if (self.frameGuardSlowFrames < FRAME_GUARD_COUNT) then return false; end
        self.speed100 = 100;
        self.desiredSpeed100 = 100;
        self.frameGuardTripped = true;
        self:ResetFrameGuardObservation(clock);
        self:ResetMeasurement();
        return true;
    end

    function self:Emit(now)
        if (not self.bridgeReady or not now) then return false; end
        self.sequence = self.sequence + 1;
        local command = "SG1|" .. integerText(self.session) .. "|" .. integerText(self.sequence)
            .. "|" .. integerText(now) .. "|" .. integerText(self.speed100)
            .. "|" .. (self.active and "1" or "0");
        local ok, result = pcall(self.api.send, command);
        if (not ok or result == false) then
            self.bridgeReady = false;
            self.sendStatus = "unavailable";
            self.writeFailed = true;
            self.active = false;
            self.speed100 = 100;
            self:ResetMeasurement();
            return false;
        end
        self.lastSent = now;
        self:Pulse(now);
        return true;
    end

    function self:Pulse(now)
        self.lastPulse = now;
        if (not self.bridgeReady) then self.sendStatus = "unavailable"; return false; end
        local ok, result = false, false;
        if (type(self.api.pulse) == "function") then
            -- Querying the already-set CVar logs it synchronously without making
            -- the shared config dirty. Native receives this on its console pipe.
            ok, result = pcall(self.api.pulse);
        end
        -- A successful client call is an attempt, never a backend receipt.
        if (ok and result ~= false) then self.sendStatus = "instant_attempt";
        else self.sendStatus = "file_only"; end
        return ok and result ~= false;
    end

    local function seedMeasurementSample(now, run, updated)
        -- The snapshot present at reset may predate the request. Observe its
        -- identity, but wait for a new publication before timing any progress.
        self.rawRunValue = run; self.rawRunUpdated = updated;
        self.rawSeenAt = now; self.rawProgressAt = now;
        self.measureFrameWall = now;
    end

    function self:Measure(now, clock, sampledClock)
        local sample = safeCall(self.api.rawRunSample);
        if (not now or type(sample) ~= "table" or not finiteNumber(sample.t) or sample.t < 0
            or not finiteNumber(sample.updated) or sample.updated < 0) then self:ResetMeasurement(); return; end
        local run, updated = sample.t, sample.updated;
        if (not sampledClock) then clock = safeCall(self.api.clientClock); end
        -- Require a healthy API clock and publication stamp, but use neither
        -- GetTime nor the requested multiplier as an elapsed-time scale.
        if (not finiteNumber(clock) or clock < updated) then self:ResetMeasurement(); return; end
        if (self.rawRunValue == nil) then seedMeasurementSample(now, run, updated); return; end
        local wallGap = self.measureFrameWall and now - self.measureFrameWall or 0;
        local positiveFresh = run > self.rawRunValue;
        -- Integer stamps can jump by two across a shorter UI hitch. A fresh
        -- positive sample still fits the pairwise coarse-time bounds; it is not
        -- an observed stall. Nonpositive stale observations still clear history.
        if (wallGap < 0 or wallGap >= 3
            or run < self.rawRunValue or updated < self.rawRunUpdated
            or not self.rawProgressAt
            or (now - self.rawProgressAt >= 2 and not (positiveFresh and wallGap <= 2))) then
            self:ResetMeasurement(); seedMeasurementSample(now, run, updated); return;
        end
        self.measureFrameWall = now;
        if (run == self.rawRunValue and updated == self.rawRunUpdated) then return; end
        if (run > self.rawRunValue) then self.rawProgressAt = now; end
        self.rawRunValue = run; self.rawRunUpdated = updated; self.rawSeenAt = now;

        -- Only fresh raw arrivals enter the meter. Their unhooked integer wall
        -- stamp W bounds arrival time to [W,W+1). Per-second extrema preserve
        -- all pairwise rate constraints while keeping at most 17 small buckets.
        -- Unknown packet-delivery latency remains outside this observed-arrival
        -- rate estimate; it does not certify movement or skill timing.
        local buckets = self.measureBuckets;
        local count = table.getn(buckets);
        local bucket = buckets[count];
        if (bucket and bucket.wall == now) then
            bucket.minimum = math.min(bucket.minimum, run);
            bucket.maximum = math.max(bucket.maximum, run);
            if (positiveFresh) then bucket.positiveSamples = (bucket.positiveSamples or 0) + 1; end
        else
            table.insert(buckets, { wall = now, minimum = run, maximum = run,
                positiveSamples = positiveFresh and 1 or 0 });
        end
        while (table.getn(buckets) > 0 and buckets[1].wall < now - 16) do table.remove(buckets, 1); end
        count = table.getn(buckets);

        -- Intersect the exact coarse-time constraints of a constant arrival
        -- rate: deltaRaw/(deltaWall+1) <= rate <= deltaRaw/(deltaWall-1).
        -- The upper bound exists only across more than one integer second.
        -- Retain the longest consistent suffix, dropping incompatible older
        -- history after a rate change rather than poisoning a recovery window.
        local lower, upper, first = 0, nil, count;
        local inconsistent = false;
        local index = count;
        while (index >= 1) do
            local current = buckets[index];
            local nextLower = math.max(lower, current.maximum - current.minimum);
            local nextUpper = upper;
            local later = index + 1;
            while (later <= count) do
                local other = buckets[later];
                local elapsed = other.wall - current.wall;
                nextLower = math.max(nextLower, (other.maximum - current.minimum) / (elapsed + 1));
                if (elapsed > 1) then
                    local limit = (other.minimum - current.maximum) / (elapsed - 1);
                    if (not nextUpper or limit < nextUpper) then nextUpper = limit; end
                end
                later = later + 1;
            end
            local epsilon = 1e-8 * math.max(1, math.abs(nextLower), math.abs(nextUpper or 0));
            if (nextUpper and nextLower > nextUpper + epsilon) then inconsistent = true; break; end
            lower, upper, first = nextLower, nextUpper, index;
            index = index - 1;
        end
        while (first > 1) do table.remove(buckets, 1); first = first - 1; end
        count = table.getn(buckets);
        self.measurementLower = lower;
        self.measurementUpper = upper;

        -- The display estimate uses completed middle-bucket centers, never the
        -- target. Their slope avoids bias from the partial first/current bucket.
        -- Confirmation below still requires the entire conservative interval.
        local estimate = nil;
        if (count >= 4) then
            local base = buckets[2];
            local baseRaw = (base.minimum + base.maximum) / 2;
            local samples, sumX, sumY, sumXX, sumXY = 0, 0, 0, 0, 0;
            index = 2;
            while (index < count) do
                local point = buckets[index];
                local x = point.wall - base.wall;
                local y = (point.minimum + point.maximum) / 2 - baseRaw;
                samples = samples + 1; sumX = sumX + x; sumY = sumY + y;
                sumXX = sumXX + x * x; sumXY = sumXY + x * y;
                index = index + 1;
            end
            local denominator = samples * sumXX - sumX * sumX;
            if (denominator > 0) then estimate = (samples * sumXY - sumX * sumY) / denominator; end
        end
        if (not finiteNumber(estimate) and upper) then estimate = (lower + upper) / 2; end
        self.measured = nil;
        if (finiteNumber(estimate) and estimate > 0 and buckets[count].wall - buckets[1].wall >= 2) then
            estimate = math.max(lower, estimate);
            if (upper) then estimate = math.min(upper, estimate); end
            if (estimate > 0) then self.measured = estimate; end
        end
        local target = self.speed100 / 100;
        local epsilon = 1e-8 * math.max(1, target);
        -- Sparse arrivals can bias bucket centers even when every feasible
        -- rate still matches the target. The complete conservative interval
        -- remains the only entry proof; a recent point may only deny it when
        -- all four completed buckets have independently bounded coverage.
        local intervalContained = self.measured and upper and lower >= target * 0.90 - epsilon
            and upper <= target * 1.10 + epsilon;
        -- Older matching observations can still fit a gradual rate change.
        -- At least four distinct positive arrivals and span >= 0.75*upper in
        -- EACH of the last four completed buckets bound the constant-rate
        -- center phase error to 0.125s. Four integer-spaced centers have OLS
        -- weight L1 <= 0.8, bounding slope bias to 10% of that rate. This
        -- protects exact-target stability, not every rate near the tolerance
        -- boundary. Never fill a sparse recent window with older buckets.
        -- The qualified trend is deny-only and never grants confirmation.
        local recentEstimate = nil;
        local recentFirst = math.max(2, count - 4);
        local recentQualified = count - recentFirst == 4 and finiteNumber(upper) and upper > 0;
        index = recentFirst;
        while (recentQualified and index < count) do
            local point = buckets[index];
            if ((point.positiveSamples or 0) < 4 or point.maximum - point.minimum + epsilon < upper * 0.75) then
                recentQualified = false;
            end
            index = index + 1;
        end
        if (recentQualified) then
            local base = buckets[recentFirst];
            local baseRaw = (base.minimum + base.maximum) / 2;
            local samples, sumX, sumY, sumXX, sumXY = 0, 0, 0, 0, 0;
            index = recentFirst;
            while (index < count) do
                local point = buckets[index];
                local x = point.wall - base.wall;
                local y = (point.minimum + point.maximum) / 2 - baseRaw;
                samples = samples + 1; sumX = sumX + x; sumY = sumY + y;
                sumXX = sumXX + x * x; sumXY = sumXY + x * y;
                index = index + 1;
            end
            local denominator = samples * sumXX - sumX * sumX;
            if (denominator > 0) then recentEstimate = (samples * sumXY - sumX * sumY) / denominator; end
        end
        local recentOutside = finiteNumber(recentEstimate)
            and (recentEstimate < target * 0.90 - epsilon or recentEstimate > target * 1.10 + epsilon);
        local outside = lower > target * 1.10 + epsilon or (upper and upper < target * 0.90 - epsilon);
        self.measurementMismatch = outside and true or false;
        local contained = intervalContained and not recentOutside;
        if (contained) then
            -- A live sliding window refreshes confidence without discarding the
            -- very observations that established it. There is no 12s restart.
            self.confirmedSpeed100 = self.speed100; self.confirmedAt = now;
        elseif (self.confirmedSpeed100 == self.speed100) then
            if (outside or recentOutside or inconsistent or not self.measured or not self.confirmedAt or now - self.confirmedAt >= 4) then
                self.confirmedSpeed100 = nil; self.confirmedAt = nil;
            end
        end
    end

    function self:Update()
        local now = self:RealTime();
        self.phase = safeCall(self.api.phase);
        self.solo = safeCall(self.api.isSolo);
        local newRun = self.phase == "ready" or self.phase == "dead" or self.phase == "victory";
        local run = safeCall(self.api.runTime);
        local clock = safeCall(self.api.clientClock);
        if (newRun) then
            self.lastObservedRun = nil;
        elseif (finiteNumber(run) and run >= 0 and (self.phase == "playing" or self.phase == "paused" or self.phase == "choosing")) then
            if (self.lastObservedRun and run + 1 < self.lastObservedRun) then newRun = true; end
            self.lastObservedRun = run;
        end
        if (newRun) then
            self.desiredSpeed100 = 100;
            self.frameGuardTripped = false;
            self:ResetFrameGuardObservation();
        end
        local allowed = self.bridgeReady and now ~= nil and self.phase == "playing" and self.solo == true;
        local changed = not self.initialized or allowed ~= self.active or (allowed and self.speed100 ~= self.desiredSpeed100);
        if (changed) then
            self.initialized = true;
            self.active = allowed;
            -- Choices and pause suspend the request while retaining this run's setting.
            -- A new run, explicit stop or world exit resets that setting to one.
            self.speed100 = allowed and self.desiredSpeed100 or 100;
            self:ResetMeasurement();
            self:ResetFrameGuardObservation(clock);
        end
        -- GetTime already includes the applied client-clock scale. Never divide
        -- by the selected rate to invent FPS; movement consumes this frame step.
        local frameRestored = self:ObserveFrameGuard(clock);
        if (changed or frameRestored) then
            self:Emit(now);
        elseif (self.bridgeReady and now and (not self.lastSent or now < self.lastSent or now - self.lastSent >= 5)) then
            self:Emit(now);
        elseif (self.bridgeReady and now and (not self.lastPulse or now < self.lastPulse or now - self.lastPulse >= 1)) then
            self:Pulse(now);
        end
        -- The smooth getter above detects run boundaries only. Measure reads a
        -- separate raw publication and never measures client interpolation.
        if (self.active and not frameRestored) then self:Measure(now, clock, true);
        elseif (not self.active) then self:ResetMeasurement(); end
    end

    function self:RequestSpeed(value)
        self:Update();
        if (not finiteNumber(value) or value < MIN_SPEED or value > MAX_SPEED or not self.active) then return false; end
        self.speed100 = math.floor(value + 0.5);
        self.desiredSpeed100 = self.speed100;
        self.frameGuardTripped = false;
        local clock = safeCall(self.api.clientClock);
        self:ResetFrameGuardObservation(clock);
        self:ResetMeasurement();
        local now = self:RealTime();
        local emitted = self:Emit(now);
        if (self.active) then self:Measure(now, clock, true); end
        return emitted;
    end

    function self:EmergencyStop()
        self:Update();
        self.speed100 = 100;
        self.desiredSpeed100 = 100;
        self.frameGuardTripped = false;
        local clock = safeCall(self.api.clientClock);
        self:ResetFrameGuardObservation(clock);
        self:ResetMeasurement();
        local now = self:RealTime();
        local emitted = self:Emit(now);
        if (self.active) then self:Measure(now, clock, true); end
        return emitted;
    end

    function self:Shutdown()
        self.active = false;
        self.speed100 = 100;
        self.desiredSpeed100 = 100;
        self.lastObservedRun = nil;
        self.frameGuardTripped = false;
        self:ResetFrameGuardObservation();
        self:ResetMeasurement();
        return self:Emit(self:RealTime());
    end

    return self;
end

-- A test runner can load the state machine without creating native frames.
if (AZSSpeedGear_TEST) then return; end

local function partyNumber(fn)
    local count = safeCall(fn);
    if (finiteNumber(count) and count >= 0) then return count; end
    return nil;
end

local function isSolo()
    -- Use the native party API; an unavailable API cannot establish solo play.
    local count = partyNumber(GetNumPartyMembers);
    local raid = partyNumber(GetNumRaidMembers);
    if ((count and count > 0) or (raid and raid > 0)) then return false; end
    if (type(AZS_PARTY) == "table" and table.getn(AZS_PARTY) > 0) then return false; end
    if (count ~= nil) then return true; end
    if (type(AZS_PARTY) == "table") then return true; end
    return nil;
end

local function registerBridge()
    if (type(RegisterCVar) ~= "function" or type(SetCVar) ~= "function") then return false; end
    RegisterCVar(COMMAND_CVAR, "");
    return true;
end

local worldActive = false;
local controller = Gear.NewController({
    now = function() if (type(time) == "function") then return time(); end end,
    random = function() return math.random(1, 999); end,
    phase = function() if (worldActive and type(AZS_GetPhase) == "function") then return AZS_GetPhase(); end end,
    isSolo = isSolo,
    runTime = function() if (type(AZS_GetRunTime) == "function") then return AZS_GetRunTime(); end end,
    clientClock = function() if (type(GetTime) == "function") then return GetTime(); end end,
    rawRunSample = function()
        if (type(AZS_RUN) == "table") then return { t = AZS_RUN.t, updated = AZS_RUN_UPDATED }; end
    end,
    register = registerBridge,
    send = function(command) SetCVar(COMMAND_CVAR, command); return true; end,
    pulse = function()
        if (type(ConsoleExec) == "function") then return ConsoleExec(COMMAND_CVAR); end
        return false;
    end
});
Gear.controller = controller;

local panel = nil;
local launcher = nil;
local statusLabel = nil;
local measurementLabel = nil;
local sendStatusLabel = nil;
local customBox = nil;
local noticeLabel = nil;
local lastRendered = nil;
local dbReady = false;
local captions = {};
local noticeKey = "hint";
local lastLocaleSecond = nil;
local lastLauncherText = nil;
local lastLauncherTooltip = nil;
local lastFrameGuardNotice = false;
local lastNoticeText = nil;
local keyManager = nil;
local hotkeyDownButton, hotkeyUpButton, hotkeyHint;
local captureAction = nil;
local captureModifiers = nil;
local hotkeyError = nil;
local lastHotkeyText = nil;
local customTyping = false;
local saveBindingsWrapped = false;

local function bindText(widget, key)
    table.insert(captions, { widget = widget, key = key });
    widget:SetText(tr(key));
    return widget;
end

local function sizeLauncher(text)
    if (not launcher) then return; end
    text = text or tr("launcher");
    local width = 0;
    if (type(launcher.GetFontString) == "function") then
        local ok, font = pcall(launcher.GetFontString, launcher);
        if (ok and font and type(font.GetStringWidth) == "function") then
            local measured, value = pcall(font.GetStringWidth, font);
            if (measured and finiteNumber(value)) then width = value; end
        end
    end
    if (width <= 0) then
        local index = 1;
        while (index <= string.len(text)) do
            local byte = string.byte(text, index);
            if (byte < 128) then width = width + 7;
            elseif (byte >= 192) then width = width + 12; end
            index = index + 1;
        end
    end
    launcher:SetWidth(math.max(64, math.min(160, math.ceil(width + 20))));
end

local function measurementMatchesTarget()
    if (not controller.active or not finiteNumber(controller.measured) or controller.measured <= 0) then return false; end
    return controller.confirmedSpeed100 == controller.speed100;
end

local function updateLauncherTooltip()
    if (not launcher or not launcher.speedGearHovered or not GameTooltip
        or type(GameTooltip.SetText) ~= "function" or type(GameTooltip.Show) ~= "function") then return; end
    local text = tr("launcher_hint");
    if (worldActive and controller.active) then
        local key = measurementMatchesTarget() and "target_measured" or "target_wait";
        text = string.format(tr(key), speedText(controller.speed100));
        if (finiteNumber(controller.measured) and controller.measured > 0) then
            text = text .. "\n" .. string.format(tr("measured"), controller.measured);
        end
        if (controller.measurementMismatch) then text = text .. "\n" .. tr("below_target"); end
        if (controller.frameGuardTripped) then text = text .. "\n" .. tr("frame_guard"); end
        text = text .. "\n" .. tr("launcher_hint");
    elseif (worldActive) then
        text = tr(controller.bridgeReady and "inactive" or "channel_unavailable") .. "\n" .. text;
    end
    if (text ~= lastLauncherTooltip) then
        GameTooltip:SetText(text); GameTooltip:Show(); lastLauncherTooltip = text;
    end
end

local function updateLauncher()
    if (not launcher) then return; end
    local text = tr("launcher");
    if (worldActive and controller.active) then
        if (measurementMatchesTarget()) then text = text .. " ×" .. speedText(controller.speed100);
        else
            -- Keep the requested number visible without calling it measured.
            text = string.format(tr("launcher_target"), speedText(controller.speed100))
                .. (controller.measurementMismatch and " !" or " …");
        end
    end
    updateLauncherTooltip();
    if (text ~= lastLauncherText) then
        launcher:SetText(text);
        lastLauncherText = text;
        -- Resizing during native dragging would move the pointer's grab point.
        if (not launcher.speedGearDragging) then sizeLauncher(text); end
    end
end

local function chat(message)
    if (DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function") then
        DEFAULT_CHAT_FRAME:AddMessage("|cff8ab4ff" .. tr("chat_prefix") .. "|r" .. message);
    end
end

local function savedDatabase()
    if (type(AZSSpeedGearDB) ~= "table") then AZSSpeedGearDB = {}; end
    if (AZSSpeedGearDB.show == nil) then AZSSpeedGearDB.show = false; end
    return AZSSpeedGearDB;
end

local function refreshHotkeys()
    if (not keyManager or not hotkeyDownButton) then return; end
    local down, up = keyManager:GetKey("down"), keyManager:GetKey("up");
    local downText = string.format(tr("hotkey_down"), down == "" and tr("hotkey_unbound") or down);
    local upText = string.format(tr("hotkey_up"), up == "" and tr("hotkey_unbound") or up);
    if (captureAction == "down") then downText = "…"; end
    if (captureAction == "up") then upText = "…"; end
    local hint = tr(hotkeyError or (captureAction and "hotkey_listening") or
        (not keyManager:Available() and "hotkey_unsupported") or "hotkey_hint");
    local signature = downText .. upText .. hint;
    if (signature ~= lastHotkeyText) then
        hotkeyDownButton:SetText(downText); hotkeyUpButton:SetText(upText);
        hotkeyHint:SetText(hint); lastHotkeyText = signature;
    end
end

local function stopHotkeyCapture()
    captureAction = nil; captureModifiers = nil; hotkeyError = nil;
    if (panel) then
        panel:SetScript("OnKeyDown", nil);
        panel:SetScript("OnKeyUp", nil);
        if (type(panel.EnableKeyboard) == "function") then panel:EnableKeyboard(false); end
    end
    refreshHotkeys();
end

local function prepareHotkeys(db)
    if (not keyManager and type(AZSSpeedGearHotkeys) == "table") then
        local api = {};
        if (type(GetBindingAction) == "function") then api.getBinding = GetBindingAction; end
        if (type(SetBinding) == "function") then api.setBinding = SetBinding; end
        keyManager = AZSSpeedGearHotkeys.NewManager(api, db);
        Gear.hotkeys = keyManager;
    end
    if (keyManager and not saveBindingsWrapped and type(SaveBindings) == "function") then
        local originalSave = SaveBindings;
        SaveBindings = function(...) return keyManager:WithBaseBindings(originalSave, unpack(arg)); end;
        saveBindingsWrapped = true;
    end
end

local function validPosition(point, relativePoint, x, y)
    local points = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true };
    return type(point) == "string" and type(relativePoint) == "string" and points[point] and points[relativePoint]
        and finiteNumber(x) and finiteNumber(y) and math.abs(x) < 10000 and math.abs(y) < 10000;
end

local function showLauncher()
    if (launcher) then
        if (worldActive) then launcher:Show(); else launcher:Hide(); end
    end
end

local function setShown(shown)
    local db = savedDatabase();
    db.show = shown and true or false;
    if (panel) then
        if (db.show) then panel:Show();
        else
            customTyping = false;
            if (customBox and type(customBox.ClearFocus) == "function") then customBox:ClearFocus(); end
            stopHotkeyCapture(); panel:Hide();
        end
    end
end

local function sendingText()
    if (controller.sendStatus == "instant_attempt") then return tr("send_instant_attempt"); end
    if (controller.sendStatus == "file_only") then return tr("send_file_only"); end
    return tr("send_unavailable");
end

local function render()
    updateLauncher();
    refreshHotkeys();
    local guardNotice = controller.frameGuardTripped and controller.bridgeReady;
    if (guardNotice and controller.active and not lastFrameGuardNotice) then chat(tr("frame_guard")); end
    lastFrameGuardNotice = controller.frameGuardTripped and true or false;
    if (measurementMatchesTarget() and (noticeKey == "switching" or noticeKey == "stop_sent")) then
        noticeKey = "hint";
    end
    local notice = tr(guardNotice and "frame_guard" or noticeKey);
    if (noticeLabel and notice ~= lastNoticeText) then
        noticeLabel:SetText(notice);
        lastNoticeText = notice;
    end
    if (not statusLabel) then return; end
    local status = "";
    if (not controller.bridgeReady) then
        status = tr("channel_unavailable");
    elseif (not controller:RealTime()) then
        status = tr("real_clock_unavailable");
    elseif (controller.phase == nil) then
        status = tr("phase_unavailable");
    elseif (controller.solo == false) then
        status = tr("coop_protection");
    elseif (controller.solo == nil) then
        status = tr("solo_unknown");
    elseif (not controller.active) then
        if (controller.desiredSpeed100 ~= 100) then
            status = string.format(tr("suspended"), speedText(controller.desiredSpeed100));
        else status = tr("inactive"); end
    elseif (controller.frameGuardTripped) then
        status = tr("frame_guard");
    else
        status = string.format(tr("target_wait"), speedText(controller.speed100));
        if (controller.measured) then
            if (controller.measurementMismatch) then
                status = tr("below_target");
            elseif (measurementMatchesTarget()) then status = string.format(tr("target_measured"), speedText(controller.speed100)); end
        end
    end
    local measurement = tr("measurement_wait");
    if (controller.measured) then
        measurement = string.format(tr("measured"), controller.measured);
    end
    local sending = sendingText();
    local signature = status .. measurement .. sending;
    if (signature ~= lastRendered) then
        statusLabel:SetText(status);
        measurementLabel:SetText(measurement);
        if (sendStatusLabel) then sendStatusLabel:SetText(sending); end
        lastRendered = signature;
    end
end

local function requestSpeed(value)
    local sent = controller:RequestSpeed(value);
    if (sent) then
        noticeKey = "switching";
    else
        noticeKey = "invalid_speed";
    end
    render();
    return sent;
end

local function shown(widget)
    if (not widget or type(widget.IsShown) ~= "function") then return false; end
    local ok, visible = pcall(widget.IsShown, widget);
    return ok and (visible == true or visible == 1);
end

function Gear.StepHotkey(direction)
    if (not dbReady or not worldActive or captureAction or customTyping or
        shown(ChatFrameEditBox) or shown(ChatFrame1EditBox) or shown(GameMenuFrame)) then return false; end
    if (not keyManager or not keyManager.active or type(AZSSpeedGearHotkeys) ~= "table") then return false; end
    controller:Update();
    if (not controller.active) then return false; end
    local nextSpeed = AZSSpeedGearHotkeys.NextSpeed(controller.desiredSpeed100, direction);
    if (nextSpeed == controller.desiredSpeed100) then return false; end
    return requestSpeed(nextSpeed);
end

local function modifier(fn)
    local value = safeCall(fn);
    return value == true or value == 1;
end

local CAPTURE_MODIFIERS = {
    SHIFT = "shift", LSHIFT = "shift", RSHIFT = "shift",
    CTRL = "ctrl", CONTROL = "ctrl", LCTRL = "ctrl", RCTRL = "ctrl",
    ALT = "alt", LALT = "alt", RALT = "alt"
};

local function capturedModifier(name, query)
    -- A delayed client can expose the final OS state while replaying earlier
    -- key events. Prefer observed event order, including an observed release.
    if (captureModifiers and captureModifiers[name] ~= nil) then return captureModifiers[name]; end
    -- A modifier held before recording has no captured key-down event.
    return modifier(query);
end

local function releaseCapturedModifier()
    local name = CAPTURE_MODIFIERS[string.upper(arg1 or "")];
    if (name and captureModifiers) then captureModifiers[name] = false; end
end

local function captureHotkey()
    local key = string.upper(arg1 or "");
    if (key == "ESCAPE") then stopHotkeyCapture(); return; end
    local name = CAPTURE_MODIFIERS[key];
    if (name) then
        if (captureModifiers) then captureModifiers[name] = true; end
        return;
    end
    if (key == "UNKNOWN") then return; end
    if (key == "BACKSPACE") then key = "";
    else
        if (capturedModifier("shift", IsShiftKeyDown)) then key = "SHIFT-" .. key; end
        if (capturedModifier("ctrl", IsControlKeyDown)) then key = "CTRL-" .. key; end
        if (capturedModifier("alt", IsAltKeyDown)) then key = "ALT-" .. key; end
    end
    local ok, reason = keyManager:SetKey(captureAction, key);
    if (ok) then stopHotkeyCapture();
    else hotkeyError = reason == "duplicate" and "hotkey_duplicate" or "hotkey_unsupported"; refreshHotkeys(); end
end

local function beginHotkeyCapture(action)
    stopHotkeyCapture();
    if (not keyManager or not keyManager:Available() or not panel or type(panel.EnableKeyboard) ~= "function") then
        hotkeyError = "hotkey_unsupported"; refreshHotkeys(); return;
    end
    customTyping = false;
    if (customBox and type(customBox.ClearFocus) == "function") then customBox:ClearFocus(); end
    if (ChatFrameEditBox and type(ChatFrameEditBox.ClearFocus) == "function") then ChatFrameEditBox:ClearFocus(); end
    if (ChatFrame1EditBox and type(ChatFrame1EditBox.ClearFocus) == "function") then ChatFrame1EditBox:ClearFocus(); end
    captureAction = action;
    captureModifiers = {};
    panel:SetScript("OnKeyDown", captureHotkey);
    panel:SetScript("OnKeyUp", releaseCapturedModifier);
    panel:EnableKeyboard(true);
    refreshHotkeys();
end

local function emergencyStop()
    local sent = controller:EmergencyStop();
    if (sent) then noticeKey = "stop_sent";
    else noticeKey = "stop_failed"; end
    render();
end

local function addText(parent, size, x, y, text)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    -- Inherit the client's localized font, including Chinese glyph coverage.
    -- Resolve a real native font path rather than hard-coding a Latin-only face.
    if (GameFontNormal and type(GameFontNormal.GetFont) == "function" and type(label.SetFont) == "function") then
        local ok, face, oldSize, flags = pcall(GameFontNormal.GetFont, GameFontNormal);
        if (ok and type(face) == "string" and face ~= "") then pcall(label.SetFont, label, face, size, flags or ""); end
    end
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    label:SetWidth(528);
    label:SetHeight(34);
    label:SetJustifyH("LEFT");
    bindText(label, text);
    return label;
end

local function addButton(parent, name, text, x, y, width, callback)
    local button = CreateFrame("Button", name, parent, "UIPanelButtonTemplate");
    button:SetWidth(width);
    button:SetHeight(26);
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    if (I18n.catalogs.en[text]) then bindText(button, text);
    else button:SetText(text); end
    button:SetScript("OnClick", callback);
    return button;
end

local function buildLauncher()
    if (launcher or type(CreateFrame) ~= "function" or not UIParent) then return; end
    launcher = CreateFrame("Button", "AZSSpeedGearLauncher", UIParent, "UIPanelButtonTemplate");
    launcher:SetWidth(64);
    launcher:SetHeight(30);
    launcher:SetPoint("RIGHT", UIParent, "RIGHT", -24, 80);
    launcher:SetFrameStrata("DIALOG");
    updateLauncher();
    launcher:SetMovable(true);
    launcher:EnableMouse(true);
    launcher:RegisterForDrag("LeftButton");
    if (type(launcher.SetClampedToScreen) == "function") then pcall(launcher.SetClampedToScreen, launcher, true); end
    launcher:SetScript("OnMouseDown", function()
        -- A fresh press clears a drag whose release emitted no OnClick.
        this.speedGearDragging = false;
        this.speedGearSuppressClick = false;
    end);
    launcher:SetScript("OnDragStart", function()
        this.speedGearDragging = true;
        this.speedGearSuppressClick = true;
        this:StartMoving();
    end);
    launcher:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        this.speedGearDragging = false;
        this.speedGearSuppressClick = true;
        local point, relative, relativePoint, x, y = this:GetPoint(1);
        if (validPosition(point, relativePoint, x, y)) then
            local db = savedDatabase();
            db.launcherPoint = point;
            db.launcherRelativePoint = relativePoint;
            db.launcherX = x;
            db.launcherY = y;
        end
        sizeLauncher(lastLauncherText);
    end);
    launcher:SetScript("OnClick", function()
        if (this.speedGearDragging or this.speedGearSuppressClick) then
            this.speedGearSuppressClick = false;
            return;
        end
        setShown(not savedDatabase().show);
    end);
    launcher:SetScript("OnEnter", function()
        if (GameTooltip and type(GameTooltip.SetOwner) == "function" and type(GameTooltip.SetText) == "function" and type(GameTooltip.Show) == "function") then
            GameTooltip:SetOwner(this, "ANCHOR_LEFT");
            this.speedGearHovered = true;
            lastLauncherTooltip = nil;
            updateLauncherTooltip();
        end
    end);
    launcher:SetScript("OnLeave", function()
        this.speedGearHovered = false; lastLauncherTooltip = nil;
        if (GameTooltip and type(GameTooltip.Hide) == "function") then GameTooltip:Hide(); end
    end);
    launcher:SetScript("OnHide", function()
        local hovered = this.speedGearHovered;
        this.speedGearHovered = false; lastLauncherTooltip = nil;
        if (hovered and GameTooltip and type(GameTooltip.Hide) == "function") then GameTooltip:Hide(); end
    end);
    launcher:Hide();
    Gear.launcher = launcher;
end

local function buildPanel()
    if (panel or type(CreateFrame) ~= "function" or not UIParent) then return; end
    panel = CreateFrame("Frame", "AZSSpeedGearPanel", UIParent);
    panel:SetWidth(560);
    panel:SetHeight(432);
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
    panel:SetFrameStrata("DIALOG");
    panel:SetMovable(true);
    panel:EnableMouse(true);
    panel:RegisterForDrag("LeftButton");
    panel:SetScript("OnHide", function() customTyping = false; stopHotkeyCapture(); end);
    if (type(panel.SetClampedToScreen) == "function") then pcall(panel.SetClampedToScreen, panel, true); end
    panel:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } });
    panel:SetBackdropColor(0.04, 0.06, 0.10, 0.96);
    panel:SetScript("OnDragStart", function() this:StartMoving(); end);
    panel:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        local point, relative, relativePoint, x, y = this:GetPoint(1);
        local db = savedDatabase();
        db.point = point;
        db.relativePoint = relativePoint;
        db.x = x;
        db.y = y;
    end);
    local title = addText(panel, 14, 16, -16, "title");
    title:SetWidth(410);
    addButton(panel, "AZSSpeedGearClose", "close", 440, -10, 104, function() setShown(false); end);
    statusLabel = addText(panel, 12, 16, -50, "inactive");
    measurementLabel = addText(panel, 11, 16, -86, "measurement_wait");
    sendStatusLabel = addText(panel, 11, 16, -122, "send_file_only");
    local presets = { 50, 100, 200, 300, 500 };
    local i = 1;
    while (i <= table.getn(presets)) do
        local selected = presets[i];
        addButton(panel, "AZSSpeedGearPreset" .. i, "x" .. speedText(selected), 16 + (i - 1) * 104, -164, 96,
            function() requestSpeed(selected); end);
        i = i + 1;
    end
    local customLabel = addText(panel, 11, 16, -216, "custom");
    customLabel:SetWidth(270);
    customBox = CreateFrame("EditBox", "AZSSpeedGearCustom", panel, "InputBoxTemplate");
    customBox:SetWidth(70);
    customBox:SetHeight(26);
    customBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 300, -208);
    customBox:SetAutoFocus(false);
    customBox:SetMaxLetters(6);
    customBox:SetText("1");
    local function submitCustom()
        local number = tonumber(customBox:GetText());
        if (finiteNumber(number)) then requestSpeed(number * 100);
        else noticeKey = "invalid_speed"; render(); end
        customTyping = false; customBox:ClearFocus();
    end
    customBox:SetScript("OnEnterPressed", submitCustom);
    customBox:SetScript("OnEditFocusGained", function() customTyping = true; end);
    customBox:SetScript("OnEditFocusLost", function() customTyping = false; end);
    customBox:SetScript("OnHide", function() customTyping = false; end);
    customBox:SetScript("OnEscapePressed", function() customTyping = false; this:ClearFocus(); end);
    addButton(panel, "AZSSpeedGearApply", "apply", 390, -208, 140, submitCustom);
    addButton(panel, "AZSSpeedGearStop", "stop", 16, -260, 528, emergencyStop);
    local keyTitle = addText(panel, 10, 16, -298, "hotkeys_title");
    keyTitle:SetWidth(64); keyTitle:SetHeight(30);
    hotkeyDownButton = addButton(panel, "AZSSpeedGearHotkeyDown", "", 88, -298, 162,
        function() beginHotkeyCapture("down"); end);
    hotkeyUpButton = addButton(panel, "AZSSpeedGearHotkeyUp", "", 258, -298, 162,
        function() beginHotkeyCapture("up"); end);
    local reset = addButton(panel, "AZSSpeedGearHotkeyReset", "hotkey_reset", 428, -298, 116, function()
        stopHotkeyCapture();
        if (keyManager) then
            local ok = keyManager:Reset();
            if (not ok) then hotkeyError = "hotkey_unsupported"; end
        end
        refreshHotkeys();
    end);
    local _, button;
    for _, button in ipairs({ hotkeyDownButton, hotkeyUpButton, reset }) do
        if (type(button.GetFontString) == "function") then
            local font = button:GetFontString();
            if (font and type(font.GetFont) == "function" and type(font.SetFont) == "function") then
                local face, size, flags = font:GetFont();
                if (type(face) == "string") then font:SetFont(face, 10, flags or ""); end
            end
            if (font and type(font.SetWidth) == "function") then
                font:SetWidth((button == reset and 116 or 162) - 12);
                font:SetHeight(24);
            end
        end
    end
    reset:SetScript("OnEnter", function()
        if (GameTooltip and type(GameTooltip.SetOwner) == "function") then
            GameTooltip:SetOwner(this, "ANCHOR_LEFT"); GameTooltip:SetText(tr("hotkey_reset")); GameTooltip:Show();
        end
    end);
    reset:SetScript("OnLeave", function() if (GameTooltip and type(GameTooltip.Hide) == "function") then GameTooltip:Hide(); end end);
    hotkeyHint = addText(panel, 10, 16, -328, "hotkey_hint"); hotkeyHint:SetHeight(32);
    noticeLabel = addText(panel, 11, 16, -366, "hint");
    local commands = addText(panel, 10, 16, -402, "commands"); commands:SetHeight(20);
    Gear.panel = panel;
end

local function loadSettings()
    I18n.Refresh();
    local db = savedDatabase();
    dbReady = true;
    prepareHotkeys(db);
    buildPanel();
    buildLauncher();
    if (panel and validPosition(db.point, db.relativePoint, db.x, db.y)) then
        panel:ClearAllPoints();
        panel:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y);
    end
    if (launcher and validPosition(db.launcherPoint, db.launcherRelativePoint, db.launcherX, db.launcherY)) then
        launcher:ClearAllPoints();
        launcher:SetPoint(db.launcherPoint, UIParent, db.launcherRelativePoint, db.launcherX, db.launcherY);
    end
    setShown(db.show);
    showLauncher();
    if (worldActive and keyManager) then keyManager:Apply(); end
    controller:Update();
    render();
end

local function slash(message)
    message = string.lower(message or "");
    message = string.gsub(message, "^%s+", "");
    message = string.gsub(message, "%s+$", "");
    if (not dbReady) then loadSettings(); end
    if (message == "show") then setShown(true);
    elseif (message == "hide") then setShown(false);
    elseif (message == "status") then chat(sendingText()); chat(tr("status_help"));
    elseif (message == "stop" or message == "reset" or message == "1") then emergencyStop();
    elseif (message == "" or message == "toggle") then setShown(not savedDatabase().show);
    elseif (tonumber(message)) then requestSpeed(tonumber(message) * 100);
    else chat(tr("help")); end
end

I18n.Listen(function()
    local index = 1;
    while (index <= table.getn(captions)) do
        local entry = captions[index];
        entry.widget:SetText(tr(entry.key));
        index = index + 1;
    end
    updateLauncher();
    lastHotkeyText = nil;
    lastNoticeText = nil;
    lastRendered = nil;
    render();
end);

SLASH_AZSSPEEDGEAR1 = "/azsg";
SLASH_AZSSPEEDGEAR2 = "/speedgear";
if (type(SlashCmdList) == "table") then SlashCmdList["AZSSPEEDGEAR"] = slash; end

if (type(CreateFrame) == "function") then
    -- Separate always-visible driver: hiding the panel must not stop heartbeats.
    local driver = CreateFrame("Frame", "AZSSpeedGearDriver", UIParent);
    driver:RegisterEvent("ADDON_LOADED");
    driver:RegisterEvent("PLAYER_ENTERING_WORLD");
    driver:RegisterEvent("PLAYER_LEAVING_WORLD");
    driver:RegisterEvent("PLAYER_LOGOUT");
    driver:SetScript("OnEvent", function()
        if (event == "PLAYER_LOGOUT" or event == "PLAYER_LEAVING_WORLD") then
            worldActive = false;
            stopHotkeyCapture();
            if (keyManager) then keyManager:Release(); end
            showLauncher();
            controller:Shutdown();
            updateLauncher();
        elseif (event == "ADDON_LOADED") then
            if (arg1 == "AZSSpeedGear") then loadSettings(); end
        elseif (event == "PLAYER_ENTERING_WORLD") then
            worldActive = true;
            I18n.Refresh();
            if (not dbReady) then loadSettings(); end
            showLauncher();
            controller:Update();
            if (keyManager) then keyManager:Apply(); end
            render();
        end
    end);
    driver:SetScript("OnUpdate", function()
        if (dbReady) then
            local now = controller:RealTime();
            if (now ~= lastLocaleSecond) then I18n.Refresh(); lastLocaleSecond = now; end
            controller:Update(); render();
        end
    end);
    Gear.driver = driver;
end

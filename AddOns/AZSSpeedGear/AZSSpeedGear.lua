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
local layoutPanel = nil;
local panelWidgets = nil;
-- Lua 5.0 limits each closure to 32 upvalues. Keep layout bookkeeping in one
-- owner rather than making buildPanel capture every individual state field.
local layoutState = { dirty = true, detailsOpen = false, widthCache = {}, widthCacheCount = 0 };

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
        layoutState.dirty = true;
        if (layoutPanel and panelWidgets) then layoutPanel(); end
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
        if (db.show) then
            panel:Show();
            layoutState.dirty = true;
            if (layoutPanel) then layoutPanel(); end
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
    if (panelWidgets and controller.desiredSpeed100 ~= layoutState.lastPresetSelection) then
        local _, button;
        for _, button in ipairs(panelWidgets.presets) do
            local method = button.speedGearValue == controller.desiredSpeed100 and "LockHighlight" or "UnlockHighlight";
            if (type(button[method]) == "function") then button[method](button); end
        end
        layoutState.lastPresetSelection = controller.desiredSpeed100;
    end
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
        layoutState.dirty = true;
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
        layoutState.dirty = true;
    end
    if (layoutState.dirty and layoutPanel) then layoutPanel(); end
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

local function textColor(widget, red, green, blue)
    if (widget and type(widget.SetTextColor) == "function") then widget:SetTextColor(red, green, blue); end
end

local function widgetValue(widget, method)
    if (widget and type(widget[method]) == "function") then
        local ok, value = pcall(widget[method], widget);
        if (ok) then return value; end
    end
    return nil;
end

local function setWidgetFont(widget, size)
    local font = widget;
    if (type(widget.GetFontString) == "function") then font = widgetValue(widget, "GetFontString") or widget; end
    -- Preserve the native localized face instead of choosing a Latin-only font.
    if (GameFontNormal and type(GameFontNormal.GetFont) == "function" and type(font.SetFont) == "function") then
        local ok, face, oldSize, flags = pcall(GameFontNormal.GetFont, GameFontNormal);
        if (ok and type(face) == "string" and face ~= "") then pcall(font.SetFont, font, face, size, flags or ""); end
    end
    widget.speedGearTextSize = size;
end

local function textWidth(widget)
    local text = widgetValue(widget, "GetText") or "";
    local size = widget.speedGearTextSize or 11;
    local font = widget;
    if (type(widget.GetFontString) == "function") then font = widgetValue(widget, "GetFontString") or widget; end
    local face, flags;
    if (type(font.GetFont) == "function") then
        local ok, currentFace, currentSize, currentFlags = pcall(font.GetFont, font);
        if (ok and type(currentFace) == "string" and finiteNumber(currentSize) and currentSize > 0) then
            face, size, flags = currentFace, currentSize, currentFlags or "";
        end
    end
    local cacheKey = (face or "native-default") .. ":" .. tostring(size) .. ":" .. (flags or "") .. ":" .. text;
    if (layoutState.widthCache[cacheKey]) then return layoutState.widthCache[cacheKey]; end
    -- Measure outside the live label's wrapping constraint. Otherwise a long
    -- chord could shrink on every reflow as its wrapped line gets measured.
    if (layoutState.measureFont) then
        if (face and type(layoutState.measureFont.SetFont) == "function") then
            pcall(layoutState.measureFont.SetFont, layoutState.measureFont, face, size, flags);
        else setWidgetFont(layoutState.measureFont, size); end
        layoutState.measureFont:SetText(text);
        font = layoutState.measureFont;
    end
    if (type(font.GetStringWidth) == "function") then
        local value = widgetValue(font, "GetStringWidth");
        if (finiteNumber(value) and value > 0) then
            if (layoutState.widthCacheCount >= 256) then layoutState.widthCache = {}; layoutState.widthCacheCount = 0; end
            layoutState.widthCache[cacheKey] = value; layoutState.widthCacheCount = layoutState.widthCacheCount + 1;
            return value;
        end
    end
    -- Early loading and older clients may not expose font metrics yet.
    -- Count UTF-8 glyphs, not bytes; the native metric always takes precedence.
    local width, longest, index = 0, 0, 1;
    while (index <= string.len(text)) do
        local byte = string.byte(text, index);
        if (byte == 10) then longest = math.max(longest, width); width = 0;
        elseif (byte < 128) then width = width + size * 0.56;
        elseif (byte >= 192) then width = width + size; end
        index = index + 1;
    end
    return math.max(longest, width);
end

local function addText(parent, size, x, y, text)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    setWidgetFont(label, size);
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    label:SetWidth(328);
    label:SetHeight(size + 4);
    label:SetJustifyH("LEFT");
    if (type(label.SetJustifyV) == "function") then label:SetJustifyV("TOP"); end
    textColor(label, 0.88, 0.87, 0.83);
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
    setWidgetFont(button, 11);
    button:SetScript("OnClick", callback);
    return button;
end

local function placeWidget(widget, x, y, width, height)
    widget:ClearAllPoints();
    widget:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -y);
    widget:SetWidth(width); widget:SetHeight(height);
end

local function labelHeight(label, width)
    label:SetWidth(width);
    local size = label.speedGearTextSize or 11;
    local measured = widgetValue(label, "GetStringHeight");
    if (finiteNumber(measured) and measured > 0) then return math.ceil(math.max(size + 2, measured + 2)); end
    local lines = math.max(1, math.ceil(textWidth(label) / math.max(1, width)));
    return math.ceil(lines * (size + 3));
end

local function fitButton(button, available)
    local width = math.min(available, math.max(44, math.ceil(textWidth(button) + 24)));
    local font = widgetValue(button, "GetFontString");
    local lines = math.max(1, math.ceil(textWidth(button) / math.max(1, width - 24)));
    if (font and type(font.SetWidth) == "function") then
        font:SetWidth(width - 24);
        -- Clear the previous height before querying wrapped native text.
        font:SetHeight(0);
        local height = widgetValue(font, "GetStringHeight");
        if (finiteNumber(height) and height > 0) then lines = math.max(lines, math.ceil(height / 14)); end
    end
    local height = math.max(24, lines * 14 + 8);
    if (font and type(font.SetHeight) == "function") then font:SetHeight(height - 8); end
    button:SetWidth(width); button:SetHeight(height);
    button.speedGearWidth, button.speedGearHeight = width, height;
    return width, height;
end

layoutPanel = function()
    if (not panelWidgets or panel.speedGearDragging) then return; end
    if (widgetValue(panel, "IsShown") == false) then return; end
    layoutState.dirty = false;
    local w = panelWidgets;
    w.details:SetText((layoutState.detailsOpen and "- " or "+ ") .. tr("details"));
    local closeWidth, closeHeight = fitButton(w.close, 160);
    local width = math.max(360, math.ceil(textWidth(w.title) + closeWidth + 44));
    local viewport = widgetValue(UIParent, "GetWidth");
    if (finiteNumber(viewport) and viewport >= 280) then width = math.min(width, viewport - 24); end
    local padding, gap, content = 16, 8, width - 32;
    panel:SetWidth(width);
    local function label(widget, y, labelWidth, x)
        local height = labelHeight(widget, labelWidth or content);
        placeWidget(widget, x or padding, y, labelWidth or content, height);
        widget:Show();
        return height;
    end
    local function buttonRow(buttons, y)
        local x, rowHeight = padding, 0;
        local _, button;
        for _, button in ipairs(buttons) do
            local bw, bh = fitButton(button, content);
            if (x > padding and x + bw > width - padding) then
                y = y + rowHeight + gap; x = padding; rowHeight = 0;
            end
            placeWidget(button, x, y, bw, bh);
            x = x + bw + gap; rowHeight = math.max(rowHeight, bh);
        end
        return y + rowHeight;
    end
    local y = 14;
    if (textWidth(w.title) + closeWidth + 12 > content) then
        y = y + label(w.title, y) + 6;
        placeWidget(w.close, width - padding - closeWidth, y, closeWidth, closeHeight);
        y = y + closeHeight + 12;
    else
        local titleHeight = label(w.title, y + 2, content - closeWidth - 12);
        placeWidget(w.close, width - padding - closeWidth, y, closeWidth, closeHeight);
        y = y + math.max(titleHeight + 2, closeHeight) + 12;
    end
    y = y + label(statusLabel, y) + 4;
    y = y + label(measurementLabel, y) + 12;
    y = buttonRow(w.presets, y) + 12;

    local customWidth = math.min(content, math.ceil(textWidth(w.customLabel)));
    local customHeight = labelHeight(w.customLabel, customWidth);
    local applyWidth, applyHeight = fitButton(w.apply, content);
    if (customWidth + 56 + applyWidth + gap * 2 <= content) then
        local rowHeight = math.max(26, customHeight, applyHeight);
        label(w.customLabel, y + (rowHeight - customHeight) / 2, customWidth);
        placeWidget(customBox, padding + customWidth + gap, y + (rowHeight - 26) / 2, 56, 26);
        placeWidget(w.apply, padding + customWidth + gap * 2 + 56, y + (rowHeight - applyHeight) / 2, applyWidth, applyHeight);
        y = y + rowHeight + 14;
    else
        y = y + label(w.customLabel, y) + 4;
        placeWidget(customBox, padding, y, 56, 26);
        placeWidget(w.apply, padding + 56 + gap, y, applyWidth, applyHeight);
        y = y + math.max(26, applyHeight) + 14;
    end
    y = y + label(w.hotkeyTitle, y) + 5;
    y = buttonRow({ hotkeyDownButton, hotkeyUpButton, w.reset }, y) + 4;
    y = y + label(hotkeyHint, y) + 10;
    if (noticeKey ~= "hint" or (controller.frameGuardTripped and controller.bridgeReady)) then
        y = y + label(noticeLabel, y) + 10;
    else noticeLabel:Hide(); end
    local stopWidth, stopHeight = fitButton(w.stop, content);
    local detailWidth, detailHeight = fitButton(w.details, content);
    placeWidget(w.stop, padding, y, stopWidth, stopHeight);
    if (stopWidth + detailWidth + gap > content) then y = y + stopHeight + gap; end
    placeWidget(w.details, width - padding - detailWidth, y, detailWidth, detailHeight);
    y = y + math.max(stopHeight, detailHeight);
    if (layoutState.detailsOpen) then
        y = y + 12;
        y = y + label(sendStatusLabel, y) + 6;
        y = y + label(w.commands, y) + 6;
        y = y + label(w.hint, y);
    else sendStatusLabel:Hide(); w.commands:Hide(); w.hint:Hide(); end
    panel:SetHeight(y + 16);
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
    panel:SetWidth(360);
    panel:SetHeight(280);
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
    panel:SetFrameStrata("DIALOG");
    layoutState.measureFont = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    layoutState.measureFont:SetWidth(10000); layoutState.measureFont:SetHeight(1000); layoutState.measureFont:Hide();
    panel:SetMovable(true);
    panel:EnableMouse(true);
    panel:RegisterForDrag("LeftButton");
    panel:SetScript("OnHide", function() customTyping = false; stopHotkeyCapture(); end);
    panel:SetScript("OnShow", function() layoutState.dirty = true; if (layoutPanel) then layoutPanel(); end end);
    if (type(panel.SetClampedToScreen) == "function") then pcall(panel.SetClampedToScreen, panel, true); end
    panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = false, edgeSize = 12, insets = { left = 4, right = 4, top = 4, bottom = 4 } });
    panel:SetBackdropColor(0.055, 0.05, 0.045, 0.97);
    if (type(panel.CreateTexture) == "function") then
        local fill = panel:CreateTexture(nil, "BACKGROUND");
        fill:SetTexture("Interface\\Buttons\\WHITE8X8");
        fill:SetVertexColor(0.055, 0.05, 0.045, 0.97);
        fill:SetPoint("TOPLEFT", panel, "TOPLEFT", 5, -5);
        fill:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -5, 5);
    end
    panel:SetScript("OnDragStart", function() this.speedGearDragging = true; this:StartMoving(); end);
    panel:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        this.speedGearDragging = false;
        local point, relative, relativePoint, x, y = this:GetPoint(1);
        local db = savedDatabase();
        db.point = point;
        db.relativePoint = relativePoint;
        db.x = x;
        db.y = y;
        layoutState.dirty = true; if (layoutPanel) then layoutPanel(); end
    end);
    local w = {};
    w.title = addText(panel, 13, 16, -16, "title");
    textColor(w.title, 1, 0.82, 0.38);
    w.close = addButton(panel, "AZSSpeedGearClose", "close", 0, 0, 44, function() setShown(false); end);
    statusLabel = addText(panel, 12, 0, 0, "inactive");
    measurementLabel = addText(panel, 11, 0, 0, "measurement_wait");
    textColor(measurementLabel, 0.72, 0.70, 0.65);
    sendStatusLabel = addText(panel, 10, 0, 0, "send_file_only");
    textColor(sendStatusLabel, 0.72, 0.70, 0.65);
    w.status, w.measurement, w.sending = statusLabel, measurementLabel, sendStatusLabel;
    local presets = { 50, 100, 200, 300, 500 };
    w.presets = {};
    local i = 1;
    while (i <= table.getn(presets)) do
        local selected = presets[i];
        table.insert(w.presets, addButton(panel, "AZSSpeedGearPreset" .. i, "×" .. speedText(selected), 0, 0, 44,
            function() requestSpeed(selected); end));
        w.presets[i].speedGearValue = selected;
        i = i + 1;
    end
    w.customLabel = addText(panel, 11, 0, 0, "custom");
    customBox = CreateFrame("EditBox", "AZSSpeedGearCustom", panel, "InputBoxTemplate");
    customBox:SetWidth(56);
    customBox:SetHeight(26);
    customBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -120);
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
    w.customBox = customBox;
    w.apply = addButton(panel, "AZSSpeedGearApply", "apply", 0, 0, 44, submitCustom);
    w.stop = addButton(panel, "AZSSpeedGearStop", "stop", 0, 0, 44, emergencyStop);
    w.hotkeyTitle = addText(panel, 10, 0, 0, "hotkeys_title");
    textColor(w.hotkeyTitle, 1, 0.82, 0.38);
    hotkeyDownButton = addButton(panel, "AZSSpeedGearHotkeyDown", "", 0, 0, 44,
        function() beginHotkeyCapture("down"); end);
    hotkeyUpButton = addButton(panel, "AZSSpeedGearHotkeyUp", "", 0, 0, 44,
        function() beginHotkeyCapture("up"); end);
    local reset = addButton(panel, "AZSSpeedGearHotkeyReset", "hotkey_reset", 0, 0, 44, function()
        stopHotkeyCapture();
        if (keyManager) then
            local ok = keyManager:Reset();
            if (not ok) then hotkeyError = "hotkey_unsupported"; end
        end
        refreshHotkeys();
    end);
    w.down, w.up, w.reset = hotkeyDownButton, hotkeyUpButton, reset;
    reset:SetScript("OnEnter", function()
        if (GameTooltip and type(GameTooltip.SetOwner) == "function") then
            GameTooltip:SetOwner(this, "ANCHOR_LEFT"); GameTooltip:SetText(tr("hotkey_reset")); GameTooltip:Show();
        end
    end);
    reset:SetScript("OnLeave", function() if (GameTooltip and type(GameTooltip.Hide) == "function") then GameTooltip:Hide(); end end);
    hotkeyHint = addText(panel, 10, 0, 0, "hotkey_hint");
    textColor(hotkeyHint, 0.72, 0.70, 0.65);
    noticeLabel = addText(panel, 11, 0, 0, "hint");
    textColor(noticeLabel, 1, 0.82, 0.38);
    w.hotkeyHint, w.notice = hotkeyHint, noticeLabel;
    w.details = addButton(panel, "AZSSpeedGearDetails", "details", 0, 0, 44, function()
        layoutState.detailsOpen = not layoutState.detailsOpen; layoutState.dirty = true; layoutPanel();
    end);
    w.commands = addText(panel, 10, 0, 0, "commands");
    w.hint = addText(panel, 10, 0, 0, "hint");
    textColor(w.commands, 0.72, 0.70, 0.65); textColor(w.hint, 0.72, 0.70, 0.65);
    panelWidgets = w;
    Gear.panelWidgets = w;
    Gear.panel = panel;
    refreshHotkeys(); layoutPanel();
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
    layoutState.dirty = true;
    layoutState.widthCache = {}; layoutState.widthCacheCount = 0;
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

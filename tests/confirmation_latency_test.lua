-- Remote Lua 5.0 regression. These clocks are independent fixture oracles;
-- a requested speed never supplies observed progress or elapsed time.
AZSSpeedGear_TEST = true;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");

local epoch = 1800000000;
local failures, checks = {}, 0;
local function check(value, message)
    checks = checks + 1;
    if (not value) then table.insert(failures, message); print("FAIL: " .. message); end
end

local function oracle(actualRate, clientRate, fps, publicationOffset, requestedSpeed100)
    local state = {
        physical = 0.10, started = 0.10, frame = 0, extraPhysicalOffset = 0,
        game = 100, clock = 1000, rawT = 100, rawUpdated = 1000,
        lastPublication = 0.10, publications = 0, frozen = false,
        actualRate = actualRate, clientRate = clientRate, fps = fps,
        offset = publicationOffset, requestedSpeed100 = requestedSpeed100,
        firstConfirmation = nil, dropTransitions = 0, droppedFrames = 0,
        confirmedFrames = 0, wasConfirmed = false,
    };
    local meter = AZSSpeedGear.NewController({
        now = function() return epoch + math.floor(state.physical + 1e-9); end,
        random = function() return 731; end,
        phase = function() return "playing"; end,
        isSolo = function() return true; end,
        clientClock = function() return state.clock; end,
        rawRunSample = function() return { t = state.rawT, updated = state.rawUpdated }; end,
        -- Keep the smooth getter advancing even when raw packets are frozen.
        -- The production meter must not mistake this interpolation for evidence.
        runTime = function() return state.rawT + state.clock - state.rawUpdated; end,
        register = function() return true; end,
        send = function() return true; end,
    });
    assert(meter:RequestSpeed(requestedSpeed100), "oracle request must be accepted");

    function state:observe(nextPhysical)
        local elapsed = nextPhysical - self.physical;
        self.game = self.game + self.actualRate * elapsed;
        self.clock = self.clock + self.clientRate * elapsed;
        self.physical = nextPhysical;
        local publication = self.offset + math.floor((self.physical - self.offset + 1e-9) / 0.2) * 0.2;
        if (not self.frozen and publication > self.lastPublication + 1e-9) then
            local age = math.max(0, self.physical - publication);
            self.rawT = self.game - self.actualRate * age;
            self.rawUpdated = self.clock - self.clientRate * age;
            self.lastPublication = publication;
            self.publications = self.publications + 1;
        end
        meter:Update();
        local confirmed = meter.confirmedSpeed100 == self.requestedSpeed100;
        if (confirmed) then
            self.confirmedFrames = self.confirmedFrames + 1;
            if (not self.firstConfirmation) then self.firstConfirmation = self.physical - self.started; end
        elseif (self.firstConfirmation) then
            self.droppedFrames = self.droppedFrames + 1;
        end
        if (self.wasConfirmed and not confirmed) then self.dropTransitions = self.dropTransitions + 1; end
        self.wasConfirmed = confirmed;
    end
    function state:tick()
        self.frame = self.frame + 1;
        self:observe(self.started + self.frame / self.fps + self.extraPhysicalOffset);
    end
    function state:observeElapsed(seconds)
        -- One delayed UI observation still sees the latest independently timed
        -- publication. Keep later fixed-cadence ticks monotonic after this gap.
        self.extraPhysicalOffset = self.extraPhysicalOffset + seconds;
        self:observe(self.physical + seconds);
    end
    function state:step(seconds)
        local count = math.floor(seconds * self.fps + 0.5);
        local i = 1;
        while (i <= count) do self:tick(); i = i + 1; end
    end
    function state:untilState(seconds, predicate)
        local count = math.floor(seconds * self.fps + 0.5);
        local i = 1;
        while (i <= count) do
            self:tick();
            if (predicate()) then return true; end
            i = i + 1;
        end
        return false;
    end
    function state:confirmationCount(seconds)
        local before = self.confirmedFrames;
        self:step(seconds);
        return self.confirmedFrames - before;
    end
    function state:describe(label)
        print(string.format("%s true_raw_rate=%.3f client_rate=%.3f fps=%d publication_phase=%.3f first_confirmation=%s dropped_frames=%d drop_transitions=%d publications=%d measured=%s confirmed=%s",
            label, self.actualRate, self.clientRate, self.fps, self.offset,
            tostring(self.firstConfirmation), self.droppedFrames, self.dropTransitions,
            self.publications, tostring(meter.measured), tostring(meter.confirmedSpeed100)));
    end
    return state, meter;
end

-- The publication period is physical 0.2 seconds, deliberately independent of
-- client time, requested speed and integer-second observation boundaries.
local rates = { 0.25, 0.5, 1, 2, 3, 5, 10 };
local offsets = { 0.01, 0.07, 0.19 };
local _, rate, offset;
for _, rate in ipairs(rates) do
    for _, offset in ipairs(offsets) do
        local fps = rate == 5 and 30 or 60;
        local state, meter = oracle(rate, rate, fps, offset, rate * 100);
        state:step(36);
        local label = string.format("stable %.2fx phase %.2f", rate, offset);
        state:describe(label);
        check(state.publications >= 170 and meter.active and not meter.frameGuardTripped,
            label .. " supplies fresh independent progress without a guard reset");
        check(state.firstConfirmation ~= nil and state.firstConfirmation <= 5 + 1 / fps,
            label .. " first confirms within five real seconds");
        check(state.firstConfirmation ~= nil and state.droppedFrames == 0
            and meter.confirmedSpeed100 == rate * 100,
            label .. " stays confirmed through at least thirty further real seconds");
    end
end

-- A client clock running at the requested rate is not proof that the raw game
-- clock has that rate. This remains wrong for every tested publication phase.
for _, offset in ipairs(offsets) do
    local state, meter = oracle(4, 2, 60, offset, 200);
    state:step(12);
    state:describe("wrong raw 4x versus requested 2x");
    check(state.firstConfirmation == nil and meter.confirmedSpeed100 ~= 200,
        string.format("raw 4x/client 2x phase %.2f must never confirm requested 2x", offset));
    -- Change only the client clock rate, retaining the independent wrong raw
    -- rate. A calibration must not turn the client ratio into simulation truth.
    state.clientRate = 0.5;
    state:step(12);
    state:describe("wrong raw persists after independent client-rate change");
    check(state.firstConfirmation == nil and meter.confirmedSpeed100 ~= 200,
        string.format("wrong raw progress remains unconfirmed after client-rate change, phase %.2f", offset));
end

local changed, changedMeter = oracle(2, 2, 60, 0.01, 200);
local established = changed:untilState(6, function() return changedMeter.confirmedSpeed100 == 200; end);
check(established, "rate-change scenario establishes true 2x before changing its independent raw rate");
if (established) then
    changed:step(8);
    local changedAt = changed.physical;
    changed.actualRate = 2.35;
    local revoked = changed:untilState(4, function() return changedMeter.confirmedSpeed100 ~= 200; end);
    changed:describe("confirmed 2x then independent raw 2.35x");
    check(revoked and changed.physical - changedAt <= 4 + 1 / changed.fps,
        "sustained 2.35x raw progress revokes requested 2x within four real seconds");
    check(changed:confirmationCount(8) == 0,
        "continued 2.35x progress cannot regain requested 2x confirmation");
    changed.actualRate = 2;
    local recovered = changed:untilState(5, function() return changedMeter.confirmedSpeed100 == 200; end);
    check(recovered, "fresh matching 2x progress recovers within five real seconds");
    if (recovered) then
        changed.frozen = true;
        local stale = changed:untilState(3, function() return changedMeter.confirmedSpeed100 ~= 200; end);
        check(stale and changed:confirmationCount(5) == 0,
            "a frozen raw stream loses confirmation within three seconds and stays unconfirmed despite interpolation");
    end
end

-- Change only the client clock while true raw progress stays at 2x. The meter
-- may suspend a calibration during the transition, but must recover true 2x
-- rather than report or assume that the new client-clock rate is game speed.
local independent, independentMeter = oracle(2, 2, 60, 0.07, 200);
local independentReady = independent:untilState(6, function() return independentMeter.confirmedSpeed100 == 200; end);
check(independentReady, "independent client-clock scenario establishes correct 2x first");
if (independentReady) then
    independent:step(6);
    independent.clientRate = 4;
    independent:step(5);
    independent:describe("raw 2x persists while client clock independently becomes 4x");
    check(independentMeter.confirmedSpeed100 == 200 and independentMeter.measured
        and math.abs(independentMeter.measured - 2) < 0.1,
        "independent client-rate changes do not become an invented simulation rate");
end

-- A single healthy delayed frame can cross two integer-second boundaries even
-- though it spans only 1.4 physical seconds. This is not a new run or stale data.
local hitched, hitchedMeter = oracle(0.5, 0.5, 60, 0.07, 50);
local hitchReady = hitched:untilState(6, function() return hitchedMeter.confirmedSpeed100 == 50; end);
check(hitchReady, "half-speed hitch scenario establishes independently measured confirmation first");
if (hitchReady) then
    local beforeGap = math.floor(hitched.physical) + 0.70;
    if (beforeGap <= hitched.physical + 1e-9) then beforeGap = beforeGap + 1; end
    hitched:step(beforeGap - hitched.physical);
    check(math.abs(hitched.physical - beforeGap) < 1e-6 and hitchedMeter.confirmedSpeed100 == 50,
        "half-speed hitch starts at physical fraction .70 while confirmed");
    local drops = hitched.droppedFrames;
    local coarseBefore = math.floor(hitched.physical);
    hitched:observeElapsed(1.40);
    hitched:describe("single fresh 1.4-second observation gap at half speed");
    check(math.floor(hitched.physical) - coarseBefore == 2 and hitchedMeter.confirmedSpeed100 == 50,
        "fresh half-speed progress retains confirmation across a single two-coarse-second boundary gap");
    hitched:step(10);
    check(hitchedMeter.confirmedSpeed100 == 50 and hitched.droppedFrames == drops,
        "ten seconds of fresh half-speed progress after the hitch never flicker to pending");
    hitched.frozen = true;
    hitched:observeElapsed(1.40);
    hitched:observeElapsed(1.40);
    check(hitchedMeter.confirmedSpeed100 ~= 50 and hitched:confirmationCount(5) == 0,
        "post-hitch frozen raw packets still revoke confirmation within three physical seconds");
end

local sparseWrong, sparseWrongMeter = oracle(4, 0.5, 60, 0.07, 50);
sparseWrong:step(3);
local wrongBeforeGap = math.floor(sparseWrong.physical) + 0.70;
if (wrongBeforeGap <= sparseWrong.physical + 1e-9) then wrongBeforeGap = wrongBeforeGap + 1; end
sparseWrong:step(wrongBeforeGap - sparseWrong.physical);
sparseWrong:observeElapsed(1.40);
sparseWrong:step(10);
sparseWrong:describe("wrong raw 4x versus requested half speed with one observation gap");
check(sparseWrong.firstConfirmation == nil and sparseWrongMeter.confirmedSpeed100 ~= 50,
    "a sparse observation cannot confirm independent raw 4x as requested half speed");

print("Confirmation latency regression: " .. checks .. " checks, " .. table.getn(failures) .. " failures.");
assert(table.getn(failures) == 0, table.concat(failures, "; "));

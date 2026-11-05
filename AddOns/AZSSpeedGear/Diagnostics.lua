-- Optional Lua 5.0 trace. Only the explicit enable operation allocates slots;
-- Frame/Event reuse them and never inspect frames, players, chat or spell data.
local Diagnostics = {};
local FRAME_CAPACITY, EVENT_CAPACITY, POST_GUARD_FRAMES = 128, 64, 32;
local PRODUCT = "AzerothSurvivorsSpeedGear";
local FRAME_CLOCK = "scaled_client_GetTime";
local WALL_CLOCK = "integer_epoch_seconds";
local SPEED_DOMAIN = "addon_requests_not_native_receipts";
local ESTIMATE_DOMAIN = "raw_run_arrival_estimate";
local OBSERVATION_DOMAIN = "controller_Update_callbacks";
local RAW_SAMPLE_TIMING = "cached_before_current_measurement";
local phases = { unknown = true, ready = true, playing = true, paused = true,
    choosing = true, dead = true, victory = true };
local clockStates = { first = true, advance = true, repeated = true,
    backwards = true, unavailable = true, not_sampled = true };
local reasons = { enabled = true, disabled = true, cleared = true,
    manual_speed = true, manual_stop = true, request_rejected = true,
    phase_suspend = true, phase_resume = true, activity_resume = true, run_reset = true,
    world_exit = true, frame_guard = true, send_failed = true,
    channel_unavailable = true, wall_clock_unavailable = true, wall_clock_backwards = true,
    client_clock_unavailable = true, client_clock_repeated = true,
    client_clock_backwards = true, coop = true, solo_unavailable = true };

local function number(value, minimum, maximum, integral)
    if (type(value) ~= "number" or value ~= value or value < minimum or value > maximum) then return nil; end
    if (integral and math.floor(value) ~= value) then return nil; end
    return value;
end

local function field(source, key)
    if (type(source) == "table") then return rawget(source, key); end
    return nil;
end

local function boolean(value)
    if (type(value) == "boolean") then return value; end
    return nil;
end

local function speed(value) return number(value, 25, 1000, true); end
local function sequence(value) return number(value, 0, 9007199254740991, true); end

-- Read only fixed, primitive fields. Unknown phase strings never enter a trace.
local function fillContext(row, source)
    row.wallSecond = number(field(source, "wallSecond"), 0, 1000000000000, true);
    row.clientClock = number(field(source, "clientClock"), 0, 1000000000000);
    row.rawRunTime = number(field(source, "rawRunTime"), 0, 1000000000000);
    row.rawUpdated = number(field(source, "rawUpdated"), 0, 1000000000000);
    local phase = field(source, "phase");
    row.phase = type(phase) == "string" and phases[phase] and phase or "unknown";
    row.target100 = speed(field(source, "target100"));
    row.requested100 = speed(field(source, "requested100"));
    row.active = boolean(field(source, "active"));
    row.guard = boolean(field(source, "guard"));
    row.observedRunEstimate = number(field(source, "observedRunEstimate"), 0, 1000000);
    row.guardSlowFrames = number(field(source, "guardSlowFrames"), 0, 1000000, true);
end

local function clearRow(row)
    for key in pairs(row) do row[key] = nil; end
end

local function newSlot(eventRow)
    -- Seed every key while enabling, not during the first captured frame.
    -- Clearing a value leaves the existing Lua table node available for reuse.
    local row = { wallSecond = false, clientClock = false, rawRunTime = false,
        rawUpdated = false, phase = false, target100 = false, requested100 = false,
        active = false, guard = false, observedRunEstimate = false,
        guardSlowFrames = false, sequence = false, clientClockState = false,
        clientFrameStep = false };
    if (eventRow) then
        row.reason = false; row.frameSequence = false;
        row.beforeTarget100 = false; row.beforeRequested100 = false;
    end
    clearRow(row);
    return row;
end

local function copyRow(source, eventRow)
    if (type(source) ~= "table") then return nil; end
    local seq = sequence(rawget(source, "sequence"));
    if (not seq or seq < 1) then return nil; end
    local state = rawget(source, "clientClockState");
    if (type(state) ~= "string" or not clockStates[state]) then return nil; end
    local row = {};
    fillContext(row, source);
    row.sequence = seq;
    row.clientClockState = state;
    row.clientFrameStep = number(rawget(source, "clientFrameStep"), 0, 1000000000000);
    if (state == "advance" and (not row.clientFrameStep or row.clientFrameStep <= 0)) then return nil; end
    if (state == "repeated" and row.clientFrameStep ~= 0) then return nil; end
    if (state ~= "advance" and state ~= "repeated" and row.clientFrameStep ~= nil) then return nil; end
    if (eventRow) then
        local reason = rawget(source, "reason");
        if (type(reason) ~= "string" or not reasons[reason]) then return nil; end
        row.reason = reason;
        row.frameSequence = sequence(rawget(source, "frameSequence"));
        if (row.frameSequence == nil) then return nil; end
        row.beforeTarget100 = speed(rawget(source, "beforeTarget100"));
        row.beforeRequested100 = speed(rawget(source, "beforeRequested100"));
    end
    return row;
end

local function header()
    return { schema = 1, product = PRODUCT, frameClock = FRAME_CLOCK,
        wallClock = WALL_CLOCK, speedDomain = SPEED_DOMAIN,
        estimateDomain = ESTIMATE_DOMAIN, observationDomain = OBSERVATION_DOMAIN,
        rawSampleTiming = RAW_SAMPLE_TIMING, nativeReceiptAvailable = false,
        frameCapacity = FRAME_CAPACITY, eventCapacity = EVENT_CAPACITY,
        postGuardFrames = POST_GUARD_FRAMES };
end

function Diagnostics.NewRecorder()
    local recorder = {};
    local state = { enabled = false, allocated = false, frames = {}, events = {},
        frameHead = 1, eventHead = 1, frameCount = 0, eventCount = 0,
        frameSequence = 0, eventSequence = 0, frozen = false,
        postCaptured = 0 };

    local function allocate()
        if (state.allocated) then return; end
        local index = 1;
        while (index <= FRAME_CAPACITY) do state.frames[index] = newSlot(false); index = index + 1; end
        index = 1;
        while (index <= EVENT_CAPACITY) do state.events[index] = newSlot(true); index = index + 1; end
        state.allocated = true;
    end

    local function reset()
        state.frameHead = 1; state.eventHead = 1;
        state.frameCount = 0; state.eventCount = 0;
        state.frameSequence = 0; state.eventSequence = 0;
        state.previousClock = nil; state.lastFrameClock = nil; state.lastFrameWall = nil;
        state.lastClockState = nil; state.lastFrameStep = nil;
        state.triggerFrameSequence = nil; state.postRemaining = nil;
        state.postCaptured = 0; state.frozen = false;
        if (state.allocated) then
            local index = 1;
            while (index <= FRAME_CAPACITY) do clearRow(state.frames[index]); index = index + 1; end
            index = 1;
            while (index <= EVENT_CAPACITY) do clearRow(state.events[index]); index = index + 1; end
        end
    end

    function recorder:IsEnabled() return state.enabled; end

    -- Return primitives so a status display need not allocate an Export copy.
    function recorder:GetCounts()
        return state.frameCount, state.eventCount, state.frozen, state.postCaptured;
    end

    function recorder:Event(reason, context)
        if (not state.enabled or type(reason) ~= "string" or not reasons[reason]) then return false; end
        local row = state.events[state.eventHead];
        fillContext(row, context);
        state.eventSequence = state.eventSequence + 1;
        row.sequence = state.eventSequence;
        row.reason = reason;
        row.frameSequence = state.frameSequence;
        row.beforeTarget100 = speed(field(context, "beforeTarget100"));
        row.beforeRequested100 = speed(field(context, "beforeRequested100"));
        row.clientFrameStep = nil; row.clientClockState = "not_sampled";
        if (state.frameSequence > 0 and row.clientClock == state.lastFrameClock and row.wallSecond == state.lastFrameWall) then
            row.clientFrameStep = state.lastFrameStep;
            row.clientClockState = state.lastClockState;
        end
        state.eventHead = state.eventHead + 1;
        if (state.eventHead > EVENT_CAPACITY) then state.eventHead = 1; end
        state.eventCount = math.min(EVENT_CAPACITY, state.eventCount + 1);
        if (reason == "frame_guard" and state.triggerFrameSequence == nil) then
            state.triggerFrameSequence = state.frameSequence;
            state.postRemaining = POST_GUARD_FRAMES;
            state.postCaptured = 0;
        end
        return true;
    end

    function recorder:SetEnabled(value, context)
        if (value == true) then
            if (state.enabled) then return false; end
            allocate(); reset(); state.enabled = true;
            self:Event("enabled", context);
            return true;
        elseif (value == false) then
            if (not state.enabled) then return false; end
            self:Event("disabled", context); state.enabled = false;
            return true;
        end
        return false;
    end

    function recorder:Clear(context)
        reset();
        if (state.enabled) then self:Event("cleared", context); end
    end

    function recorder:Frame(context)
        if (not state.enabled or state.frozen or type(context) ~= "table") then return false; end
        local row = state.frames[state.frameHead];
        fillContext(row, context);
        local clock, previous = row.clientClock, state.previousClock;
        local status, step = "unavailable", nil;
        if (clock and clock > 0) then
            if (not previous) then status = "first";
            elseif (clock > previous) then status = "advance"; step = clock - previous;
            elseif (clock == previous) then status = "repeated"; step = 0;
            else status = "backwards"; end
            state.previousClock = clock;
        else state.previousClock = nil; end
        state.frameSequence = state.frameSequence + 1;
        row.sequence = state.frameSequence;
        row.clientClockState = status; row.clientFrameStep = step;
        state.lastFrameClock = clock; state.lastFrameWall = row.wallSecond;
        state.lastClockState = status; state.lastFrameStep = step;
        state.frameHead = state.frameHead + 1;
        if (state.frameHead > FRAME_CAPACITY) then state.frameHead = 1; end
        state.frameCount = math.min(FRAME_CAPACITY, state.frameCount + 1);
        if (state.postRemaining) then
            state.postRemaining = state.postRemaining - 1;
            state.postCaptured = state.postCaptured + 1;
            if (state.postRemaining <= 0) then state.frozen = true; end
        end
        return true;
    end

    function recorder:Export()
        local report = header();
        report.recordingAtExport = state.enabled;
        report.frameCount = state.frameCount; report.eventCount = state.eventCount;
        report.frameSequence = state.frameSequence; report.eventSequence = state.eventSequence;
        report.framesFrozen = state.frozen;
        report.triggerFrameSequence = state.triggerFrameSequence;
        report.postFramesCaptured = state.postCaptured;
        report.frames = {}; report.events = {};
        local index = state.frameCount < FRAME_CAPACITY and 1 or state.frameHead;
        local destination = 1;
        while (destination <= state.frameCount) do
            report.frames[destination] = copyRow(state.frames[index], false);
            index = index + 1; if (index > FRAME_CAPACITY) then index = 1; end
            destination = destination + 1;
        end
        index = state.eventCount < EVENT_CAPACITY and 1 or state.eventHead;
        destination = 1;
        while (destination <= state.eventCount) do
            report.events[destination] = copyRow(state.events[index], true);
            index = index + 1; if (index > EVENT_CAPACITY) then index = 1; end
            destination = destination + 1;
        end
        return report;
    end

    return recorder;
end

-- Sanitize a saved report only for passive retention/display. It never creates
-- an enabled recorder, evaluates strings or calls input-supplied metamethods.
-- Fixed reads also bound the work when an old SavedVariables table is huge.
function Diagnostics.SanitizeExport(source)
    if (type(source) ~= "table" or rawget(source, "schema") ~= 1 or rawget(source, "product") ~= PRODUCT
        or rawget(source, "nativeReceiptAvailable") ~= false or rawget(source, "frameClock") ~= FRAME_CLOCK
        or rawget(source, "wallClock") ~= WALL_CLOCK or rawget(source, "speedDomain") ~= SPEED_DOMAIN
        or rawget(source, "estimateDomain") ~= ESTIMATE_DOMAIN
        or rawget(source, "observationDomain") ~= OBSERVATION_DOMAIN
        or rawget(source, "rawSampleTiming") ~= RAW_SAMPLE_TIMING) then return nil; end
    local frameCount = number(rawget(source, "frameCount"), 0, FRAME_CAPACITY, true);
    local eventCount = number(rawget(source, "eventCount"), 0, EVENT_CAPACITY, true);
    local frameSequence = sequence(rawget(source, "frameSequence"));
    local eventSequence = sequence(rawget(source, "eventSequence"));
    local post = number(rawget(source, "postFramesCaptured"), 0, POST_GUARD_FRAMES, true);
    local recording = boolean(rawget(source, "recordingAtExport"));
    local frozen = boolean(rawget(source, "framesFrozen"));
    local trigger = rawget(source, "triggerFrameSequence");
    if (trigger ~= nil) then trigger = sequence(trigger); if (trigger == nil) then return nil; end end
    if (not frameCount or not eventCount or not frameSequence or not eventSequence or not post
        or recording == nil or frozen == nil or frameCount > frameSequence or eventCount > eventSequence
        or (trigger ~= nil and trigger + post > frameSequence)
        or (trigger == nil and post ~= 0) or frozen ~= (trigger ~= nil and post == POST_GUARD_FRAMES)) then return nil; end
    local frames, events = rawget(source, "frames"), rawget(source, "events");
    if (type(frames) ~= "table" or type(events) ~= "table") then return nil; end
    local report = header();
    report.recordingAtExport = recording;
    report.frameCount = frameCount; report.eventCount = eventCount;
    report.frameSequence = frameSequence; report.eventSequence = eventSequence;
    report.framesFrozen = frozen; report.triggerFrameSequence = trigger;
    report.postFramesCaptured = post;
    report.frames = {}; report.events = {};
    local index, previous = 1, 0;
    while (index <= frameCount) do
        local row = copyRow(rawget(frames, index), false);
        if (not row or row.sequence <= previous or row.sequence > frameSequence) then return nil; end
        report.frames[index] = row; previous = row.sequence; index = index + 1;
    end
    index = 1; previous = 0;
    while (index <= eventCount) do
        local row = copyRow(rawget(events, index), true);
        if (not row or row.sequence <= previous or row.sequence > eventSequence or row.frameSequence > frameSequence) then return nil; end
        report.events[index] = row; previous = row.sequence; index = index + 1;
    end
    return report;
end

Diagnostics.FrameCapacity = FRAME_CAPACITY;
Diagnostics.EventCapacity = EVENT_CAPACITY;
Diagnostics.PostGuardFrames = POST_GUARD_FRAMES;
AZSSpeedGearDiagnostics = Diagnostics;
return Diagnostics;

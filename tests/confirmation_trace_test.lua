-- Remote Lua 5.0 replay of numerical raw arrivals from a real 0.131.0 run.
-- wallUnix is telemetry-emission time, not the original Measure call time;
-- neither the original GetTime nor AZS_RUN_UPDATED was captured. Synthetic
-- monotonic stamps below satisfy only the API-integrity contract. This fixture
-- exercises the sparse-arrival seam and is not a replay of the whole client.
AZSSpeedGear_TEST = true;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");
local fixture = dofile("tests/fixtures/confirmation_arrivals.lua");
local failures, checks = {}, 0;
local function check(value, message)
    checks = checks + 1;
    if (not value) then table.insert(failures, message); print("FAIL: " .. message); end
end

local function replay(rawScale)
    local rows = fixture.arrivals;
    local first = rows[1];
    local state = { wall = first.wallUnix, raw = first.rawT, clock = 1000, updated = 1000 };
    local meter = AZSSpeedGear.NewController({
        now = function() return state.wall; end,
        random = function() return 173; end,
        phase = function() return "playing"; end,
        isSolo = function() return true; end,
        clientClock = function() return state.clock; end,
        rawRunSample = function() return { t = state.raw, updated = state.updated }; end,
        runTime = function() return state.raw; end,
        register = function() return true; end,
        send = function() return true; end,
    });
    assert(meter:RequestSpeed(50), "half-speed replay request must be accepted");
    local firstConfirmedWall, droppedRows, confirmedRows = nil, 0, 0;
    local index = 1;
    while (index <= table.getn(rows)) do
        local row = rows[index];
        state.wall = row.wallUnix;
        -- Deliberately unrelated to elapsed time or the selected multiplier.
        -- Only fresh raw publications advance the publication identity stamp.
        state.clock = state.clock + 0.01;
        local nextRaw = first.rawT + (row.rawT - first.rawT) * rawScale;
        if (nextRaw ~= state.raw) then state.updated = state.clock; end
        state.raw = nextRaw;
        meter:Update();
        if (meter.confirmedSpeed100 == 50) then
            confirmedRows = confirmedRows + 1;
            if (not firstConfirmedWall) then firstConfirmedWall = state.wall; end
        elseif (firstConfirmedWall) then
            droppedRows = droppedRows + 1;
            print(string.format("TRACE_DROP row=%d wall=%d raw=%.3f lower=%s upper=%s measured=%s",
                index, state.wall, state.raw, tostring(meter.measurementLower),
                tostring(meter.measurementUpper), tostring(meter.measured)));
        end
        index = index + 1;
    end
    print(string.format("Recorded arrivals scale=%.1f first_confirmation_wall=%s last_wall=%d confirmed_rows=%d dropped_rows=%d",
        rawScale, tostring(firstConfirmedWall), state.wall, confirmedRows, droppedRows));
    return meter, state, firstConfirmedWall, droppedRows;
end

local meter, state, confirmedAt, drops = replay(1);
check(confirmedAt ~= nil, "recorded half-speed arrivals establish measured confirmation");
check(confirmedAt ~= nil and state.wall - confirmedAt >= 5,
    "recorded replay includes at least five wall seconds after first confirmation");
check(confirmedAt ~= nil and drops == 0 and meter.confirmedSpeed100 == 50,
    "fresh sparse recorded arrivals do not flicker from confirmed speed back to target/ellipsis");
local frozenAt = state.wall;
while (state.wall < frozenAt + 3) do
    state.wall = state.wall + 1;
    state.clock = state.clock + 0.01;
    meter:Update();
end
check(meter.confirmedSpeed100 == nil,
    "frozen recorded raw progress revokes confirmation within three wall seconds");

local wrongMeter, wrongState, wrongConfirmedAt = replay(8);
check(wrongConfirmedAt == nil and wrongMeter.confirmedSpeed100 ~= 50,
    "the same arrival cadence with eight times the raw progress never confirms half speed");
print("Recorded confirmation arrivals: " .. checks .. " checks, " .. table.getn(failures) .. " failures.");
assert(table.getn(failures) == 0, table.concat(failures, "; "));

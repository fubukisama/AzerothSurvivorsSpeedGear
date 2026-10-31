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

-- Independent adversarial oracle: true progress is exactly 0.5 game seconds
-- per physical second. Three distinct positive publications in each later
-- bucket span half a physical second, but their center phase shifts .74, .74,
-- .50, .26. A naked four-center slope is therefore 0.416, despite the correct
-- long feasible interval. Counts and half-bucket spans alone are insufficient
-- evidence for a short midpoint trend to revoke a constant measured speed.
local oracleEpoch = 1800000000;
local oracle = { physical = 0.01, raw = 100.005, clock = 1000, updated = 1000 };
local oracleMeter = AZSSpeedGear.NewController({
    now = function() return oracleEpoch + math.floor(oracle.physical); end,
    random = function() return 341; end,
    phase = function() return "playing"; end,
    isSolo = function() return true; end,
    clientClock = function() return oracle.clock; end,
    rawRunSample = function() return { t = oracle.raw, updated = oracle.updated }; end,
    runTime = function() return oracle.raw; end,
    register = function() return true; end,
    send = function() return true; end,
});
assert(oracleMeter:RequestSpeed(50), "independent phase oracle accepts half-speed request");
local oracleReady, adversarialRows, oracleDrops, uncontainedRows = false, 0, 0, 0;
local function observeOracle(physical, adversarial)
    assert(physical > oracle.physical, "physical publication instants remain increasing");
    oracle.physical = physical;
    oracle.raw = 100 + 0.5 * physical; -- Independent constant-rate physical oracle.
    oracle.clock = oracle.clock + 0.01; -- Stamp health only, unrelated to elapsed time.
    oracle.updated = oracle.clock;
    oracleMeter:Update();
    if (oracleMeter.confirmedSpeed100 == 50) then oracleReady = true; end
    if (adversarial) then
        adversarialRows = adversarialRows + 1;
        if (oracleMeter.confirmedSpeed100 ~= 50) then oracleDrops = oracleDrops + 1; end
        if (not oracleMeter.measurementLower or not oracleMeter.measurementUpper
            or oracleMeter.measurementLower < 0.45 - 1e-8
            or oracleMeter.measurementUpper > 0.55 + 1e-8) then
            uncontainedRows = uncontainedRows + 1;
        end
    end
end
local second, point;
for second = 0, 11 do
    for _, point in ipairs({ 0.10, 0.30, 0.50, 0.70, 0.90 }) do observeOracle(second + point, false); end
end
check(oracleReady and oracleMeter.confirmedSpeed100 == 50,
    "independent constant-rate oracle warms measured half-speed confirmation");
local shifted = { { 0.49, 0.74, 0.99 }, { 0.49, 0.74, 0.99 },
    { 0.25, 0.50, 0.75 }, { 0.01, 0.26, 0.51 } };
local bucket;
for second, bucket in ipairs(shifted) do
    for _, point in ipairs(bucket) do observeOracle(11 + second + point, true); end
end
observeOracle(16.10, true); -- Completes all four adversarial phase buckets.
check(adversarialRows == 13 and uncontainedRows == 0,
    "phase-shift oracle keeps the entire independently measured interval within target tolerance");
check(oracleDrops == 0 and oracleMeter.confirmedSpeed100 == 50,
    "three half-bucket publications with shifting center phase never flicker to target/ellipsis");
print(string.format("Independent phase oracle: true_rate=0.5 naked_recent_slope=0.416 rows=%d drops=%d uncontained=%d",
    adversarialRows, oracleDrops, uncontainedRows));
print("Recorded confirmation arrivals: " .. checks .. " checks, " .. table.getn(failures) .. " failures.");
assert(table.getn(failures) == 0, table.concat(failures, "; "));

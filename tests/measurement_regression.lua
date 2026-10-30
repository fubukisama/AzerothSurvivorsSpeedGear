-- Remote-CI regression only: run from the repository root with stock Lua 5.0.
-- The physical clock and true simulation rate are independent fixture oracles.
-- Neither is derived from the selected/requested speed.
AZSSpeedGear_TEST = true;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");

local epoch = 1800000000;
local physical = 0.10;
local simulationBase = 100;
local actualSimulationRate = 4;
local requestedSpeed100 = 200;
local sent = {};
local failures = {};
local function check(value, message)
    if (not value) then table.insert(failures, message); print("FAIL: " .. message); end
end

local controller = AZSSpeedGear.NewController({
    now = function() return epoch + math.floor(physical); end,
    random = function() return 321; end,
    phase = function() return "playing"; end,
    isSolo = function() return true; end,
    runTime = function() return simulationBase + actualSimulationRate * physical; end,
    clientClock = function() return 1000 + 2 * physical; end,
    rawRunSample = function()
        return { t = simulationBase + actualSimulationRate * physical, updated = 1000 + 2 * physical };
    end,
    register = function() return true; end,
    send = function(command) table.insert(sent, command); return true; end
});

local function describe(label)
    local run = simulationBase + actualSimulationRate * physical;
    print(string.format("%s physical=%.2f coarse=%.0f gameProgress=%.2f measured=%s confirmedSpeed100=%s",
        label, physical, controller:RealTime() - epoch, run,
        tostring(controller.measured), tostring(controller.confirmedSpeed100)));
end

assert(controller:RequestSpeed(requestedSpeed100), "fixture must accept the independent x2 request");
describe("request");
physical = 1.75;
controller:Update();
describe("first later coarse-second observation");
physical = 2.25;
controller:Update();
describe("next observation");

print("ORACLE physical_dt=0.50 coarse_dt=1 game_dt=2.00 actual_simulation_rate=4.00 requested_rate=2.00");
print("SEAM NOTE: rawRunSample and clientClock below are injected fixture contracts, not validation of the installed game's API implementation.");
print("The first trace observes a constant independent x4 simulation at irregular physical instants.");

check(controller.confirmedSpeed100 ~= requestedSpeed100,
    "coarse-clock aliasing must not confirm requested x2 when the independent physical-time simulation rate is x4");

-- Five raw publications per physical second and 60 observation frames per
-- second. Actual simulation and client clock rates are independent inputs;
-- runTime models the documented raw t + client-clock interpolation separately.
local function newOracle(actualRate, clientRate, frozen)
    local state = { physical = 0.10, frame = 0, rawT = 100, updated = 1000,
        revision = 0, publications = 0, frozen = frozen, firstConfirmation = nil,
        actualRate = actualRate, publishedPhysical = 0 };
    local function clientClock() return 1000 + clientRate * state.physical; end
    local meter = AZSSpeedGear.NewController({
        now = function() return epoch + math.floor(state.physical); end,
        random = function() return 654; end,
        phase = function() return "playing"; end,
        isSolo = function() return true; end,
        clientClock = clientClock,
        rawRunSample = function() return { t = state.rawT, updated = state.updated }; end,
        runTime = function() return state.rawT + clientClock() - state.updated; end,
        register = function() return true; end,
        send = function() return true; end
    });
    assert(meter:RequestSpeed(200), "oracle must accept request without choosing its simulation rate");
    function state:step(frames)
        local index = 1;
        while (index <= frames) do
            self.frame = self.frame + 1;
            self.physical = 0.10 + self.frame / 60;
            local revision = math.floor((self.physical + 1e-9) / 0.2);
            if (not self.frozen and revision > self.revision) then
                local publishedPhysical = revision * 0.2;
                self.rawT = self.rawT + self.actualRate * (publishedPhysical - self.publishedPhysical);
                self.updated = 1000 + clientRate * revision * 0.2;
                self.publishedPhysical = publishedPhysical;
                self.revision = revision;
                self.publications = self.publications + 1;
            end
            meter:Update();
            if (meter.confirmedSpeed100 == 200 and not self.firstConfirmation) then
                self.firstConfirmation = self.physical;
            end
            index = index + 1;
        end
    end
    return state, meter;
end

local frozen, frozenMeter = newOracle(4, 2, true);
frozen:step(240);
print("raw-frozen oracle: actual_rate=4 client_rate=2 publications=" .. frozen.publications
    .. " first_confirmation=" .. tostring(frozen.firstConfirmation)
    .. " final_confirmed=" .. tostring(frozenMeter.confirmedSpeed100));
check(frozen.firstConfirmation == nil and frozenMeter.confirmedSpeed100 == nil,
    "scaled client interpolation without new raw publications must not confirm simulation speed");

local wrong, wrongMeter = newOracle(4, 2, false);
wrong:step(360);
print("raw-wrong oracle: actual_rate=4 client_rate=2 publications=" .. wrong.publications
    .. " first_confirmation=" .. tostring(wrong.firstConfirmation)
    .. " final_confirmed=" .. tostring(wrongMeter.confirmedSpeed100));
check(wrong.publications > 0 and wrong.firstConfirmation == nil and wrongMeter.confirmedSpeed100 == nil,
    "fresh independent x4 server clock must not confirm requested x2 at normal frame cadence");

local right, rightMeter = newOracle(2, 2, false);
right:step(300);
print("raw-right oracle: actual_rate=2 client_rate=2 publications=" .. right.publications
    .. " first_confirmation=" .. tostring(right.firstConfirmation)
    .. " final_confirmed=" .. tostring(rightMeter.confirmedSpeed100));
check(right.publications > 0 and right.firstConfirmation ~= nil and right.firstConfirmation <= 5.10
    and rightMeter.confirmedSpeed100 == 200,
    "fresh x2 raw publications at 60 fps should establish bounded confirmation without a ten-second delay");
-- Change the independent simulation rate on a publication boundary, preserving
-- all previous raw time. The requested x2 is deliberately left unchanged.
right:step(6);
right.actualRate = 2.35;
right:step(360);
print("post-confirm oracle: requested_rate=2 actual_rate=2.35 observed=" .. tostring(rightMeter.measured)
    .. " final_confirmed=" .. tostring(rightMeter.confirmedSpeed100));
check(rightMeter.measured and rightMeter.measured > 2.2 and rightMeter.confirmedSpeed100 == nil,
    "sustained independent x2.35 progression must revoke prior requested x2 confirmation");
right.actualRate = 2;
right:step(720);
check(rightMeter.confirmedSpeed100 == 200, "fresh matching progress may confirm again after a real overspeed clears");
right.frozen = true;
right:step(180);
check(rightMeter.confirmedSpeed100 == nil,
    "a previously confirmed stream must lose confirmation after raw publications stop");

assert(table.getn(failures) == 0, table.concat(failures, "; "));
print("Measurement regression: independent raw progress and irregular observation scenarios passed.");

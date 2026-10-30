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

local controller = AZSSpeedGear.NewController({
    now = function() return epoch + math.floor(physical); end,
    random = function() return 321; end,
    phase = function() return "playing"; end,
    isSolo = function() return true; end,
    runTime = function() return simulationBase + actualSimulationRate * physical; end,
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
print("SEAM LIMIT: api.runTime exposes one number, not raw server snapshot revisions or client interpolation inputs.");
print("The stale-server-snapshot plus scaled-GetTime scenario is not validated by this regression or by the installed game here.");
print("This regression exercises only the real NewController with irregular observations of a constant independent x4 simulation.");

assert(controller.confirmedSpeed100 ~= requestedSpeed100,
    "coarse-clock aliasing must not confirm requested x2 when the independent physical-time simulation rate is x4");
print("Measurement regression: irregular coarse-clock observations did not falsely confirm x2.");

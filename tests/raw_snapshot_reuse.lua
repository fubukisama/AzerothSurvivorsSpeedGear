-- Exercise the real production adapter. All clocks/data are fixture inputs.
assert(os.getenv("GITHUB_ACTIONS") == "true", "remote CI only");
CreateFrame = nil; UIParent = nil; SlashCmdList = {};
time = function() return 1800000000; end;
GetTime = function() return 100; end;
RegisterCVar = function() end; SetCVar = function() end;
AZS_RUN = {t=0}; AZS_RUN_UPDATED = 10;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/Hotkeys.lua");
dofile("AddOns/AZSSpeedGear/Diagnostics.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");
local controller = AZSSpeedGear.controller;
local read = controller.api.rawRunSample;
local failures, checks = {}, 0;
local function check(okay, why) checks=checks+1; if not okay then table.insert(failures,why); print("FAIL: "..why); end end
local first = read();
AZS_RUN.t=3; AZS_RUN_UPDATED=11;
local nextSample=read();
check(first==nextSample, "raw adapter reuses one borrowed snapshot");
check(nextSample.t==3 and nextSample.updated==11, "borrowed snapshot reflects current publication");
controller:Measure(1800000000,100,true);
check(controller.rawRunValue==3, "measurement seeds scalar values from the adapter");
AZS_RUN.t=9;AZS_RUN_UPDATED=12;read();
check(controller.rawRunValue==3, "an adapter read does not mutate retained measurement history");
controller:Measure(1800000001,101,true);
check(controller.rawRunValue==9, "a later measurement consumes the new scalars");
AZS_RUN=nil;
check(read()==nil, "missing publication is still unavailable");
AZS_RUN={t=10};AZS_RUN_UPDATED=13;
check(read()==first and first.t==10 and first.updated==13, "recovery retains the same bounded snapshot");
collectgarbage();collectgarbage(65536);
local before=gcinfo();
for i=1,10000 do read(); end
local growth=gcinfo()-before;
collectgarbage();
print(string.format("RAW_SNAPSHOT reads=10000 retained_allocator_growth_kb=%.0f",growth));
check(growth<16, "unchanged adapter reads do not create per-read tables");
print(string.format("Raw snapshot: %d checks, %d failures",checks,table.getn(failures)));
if table.getn(failures)>0 then os.exit(1); end

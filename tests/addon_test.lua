-- Run from the repository root using a stock Lua 5.0 interpreter.
local function loadMain()
    AZSSpeedGearNativeLocale = "zh";
    dofile("AddOns/AZSSpeedGear/Localization.lua");
    dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
    dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");
end
AZSSpeedGear_TEST = true;
loadMain();
local checks = 0;
local function check(condition, message)
    checks = checks + 1;
    if (not condition) then error(message); end
end

local function fixture(available)
    local state = { now = 1800000000, run = 0, phase = "ready", solo = true, sent = {} };
    local api = {
        now = function() return state.now; end,
        random = function() return 321; end,
        phase = function() return state.phase; end,
        isSolo = function() return state.solo; end,
        runTime = function() return state.run; end,
        register = function() return available ~= false; end,
        send = function(command) table.insert(state.sent, command); return true; end
    };
    local controller = AZSSpeedGear.NewController(api);
    return state, controller;
end

local function latest(state)
    return state.sent[table.getn(state.sent)];
end

local state, controller = fixture();
controller:Update();
check(latest(state) == "SG1|1800000000321|1|1800000000|100|0", "initial inactive protocol");
state.phase = "playing";
controller:Update();
check(controller.active and controller.speed100 == 100, "enter starts at x1");
check(string.find(latest(state), "|100|1$") ~= nil, "playing active request");
check(controller:RequestSpeed(500), "x5 accepted");
check(string.find(latest(state), "|500|1$") ~= nil, "speed request immediately emitted");
local count = table.getn(state.sent);
state.now = state.now + 2;
state.run = 10;
controller:Update();
check(table.getn(state.sent) == count, "heartbeat not sent before 3 real seconds");
state.now = state.now + 1;
state.run = 15;
controller:Update();
check(table.getn(state.sent) == count + 1, "heartbeat uses real seconds");
check(controller.measured == 5, "measured actual x5 over 3 seconds");

state.phase = "choosing";
controller:Update();
check(not controller.active and controller.speed100 == 100, "choosing immediately stops");
check(controller.measured == nil and string.find(latest(state), "|100|0$") ~= nil, "choosing clears measurement and emits inactive");
state.phase = "playing";
controller:Update();
check(controller.speed100 == 500, "choosing resumes this run's requested x5");
controller:RequestSpeed(300);
state.solo = false;
controller:Update();
check(not controller.active and controller.speed100 == 100, "co-op immediately stops");
check(not controller:RequestSpeed(200), "co-op refuses speed request");
state.solo = nil;
controller:Update();
check(not controller.active, "unknown solo state stays inactive");
state.solo = true;
controller:Update();
check(controller.active and controller.speed100 == 300, "solo resumes retained desired speed");

check(not controller:RequestSpeed(24), "reject below x0.25");
check(not controller:RequestSpeed(1001), "reject above x10");
check(not controller:RequestSpeed(0 / 0), "reject NaN");
check(not controller:RequestSpeed(1 / 0), "reject infinity");
check(controller:RequestSpeed(25), "accept x0.25");
check(controller:RequestSpeed(1000), "accept x10");
controller:EmergencyStop();
check(controller.speed100 == 100 and string.find(latest(state), "|100|1$") ~= nil, "emergency requests x1");
check(controller.desiredSpeed100 == 100, "emergency also clears retained desired speed");
controller:RequestSpeed(500);
controller:Shutdown();
check(not controller.active and string.find(latest(state), "|100|0$") ~= nil, "logout sends inactive");
check(controller.desiredSpeed100 == 100, "world exit clears retained desired speed");

local phases = { "paused", "dead", "victory", "ready" };
local i = 1;
while (i <= table.getn(phases)) do
    state.phase = "playing";
    controller:Update();
    controller:RequestSpeed(200);
    state.phase = phases[i];
    controller:Update();
    check(not controller.active and controller.speed100 == 100, "inactive phase resets " .. phases[i]);
    state.phase = "playing";
    controller:Update();
    local expected = 100;
    if (phases[i] == "paused") then expected = 200; end
    check(controller.speed100 == expected, "resume or new run policy for " .. phases[i]);
    i = i + 1;
end

local unavailable, noBridge = fixture(false);
unavailable.phase = "playing";
noBridge:Update();
check(not noBridge.active and table.getn(unavailable.sent) == 0, "missing channel does not claim connection");
check(not noBridge:RequestSpeed(200), "missing channel refuses commands");

local unknown, noPhase = fixture();
unknown.phase = nil;
noPhase:Update();
check(not noPhase.active and string.find(latest(unknown), "|100|0$") ~= nil, "missing game API remains inactive");

local measured, meter = fixture();
measured.phase = "playing";
meter:Update();
measured.now = measured.now + 3;
measured.run = 3;
meter:Update();
check(meter.measured == 1, "actual x1 displayed despite requested speed being independent");
meter:RequestSpeed(500);
check(meter.measured == nil, "speed request clears old measurement");
measured.now = measured.now + 3;
measured.run = measured.run + 3;
meter:Update();
check(meter.measured == 1 and meter.speed100 == 500, "failed acceleration is honestly measured x1");
measured.run = 0;
meter:Update();
check(meter.speed100 == 100 and meter.desiredSpeed100 == 100, "significant run-time rollback starts a new run at x1");
measured.now = measured.now - 10;
meter:Update();
check(meter.measured == nil, "wall-clock rollback resets measurement");

local jitter, jitterMeter = fixture();
jitter.phase = "playing";
jitter.run = 100;
jitterMeter:Update();
local runReads = 0;
jitterMeter.api.runTime = function() runReads = runReads + 1; return jitter.run; end;
local second = 1;
while (second <= 3) do
    jitter.now = 1800000000 + second;
    jitter.run = 100 + second;
    jitterMeter:Update();
    jitter.run = jitter.run - 0.04;
    jitterMeter:Update();
    second = second + 1;
end
check(runReads == 6, "each Update reads the native run clock once");
check(jitterMeter.measured == 1, "small server corrections allow a complete three-second measurement");
check(jitterMeter.previousRun == 103, "small rollback retains observed high-water mark");
-- An unchanged high-water mark is not evidence of a running simulation.
second = 4;
while (second <= 6) do
    jitter.now = 1800000000 + second;
    jitter.run = 102.9;
    jitterMeter:Update();
    second = second + 1;
end
check(jitterMeter.measured == nil, "frozen clock with jitter cannot produce a positive measured rate");
-- Drop more than one second: start a new window at the corrected value.
jitter.now = jitter.now + 1;
jitter.run = 101.5;
jitterMeter:Update();
check(jitterMeter.measured == nil and jitterMeter.measureStart == jitter.now and jitterMeter.measureRun == 101.5,
    "significant rollback clears the measurement and resets its baseline");
jitter.now = jitter.now + 3;
jitter.run = 104.5;
jitterMeter:Update();
check(jitterMeter.measured == 1, "measurement resumes from the significant-rollback baseline");

local broken, bad = fixture();
bad.api.send = function() error("unavailable CVar"); end;
broken.phase = "playing";
bad:Update();
check(not bad.active and not bad.bridgeReady and bad.speed100 == 100, "CVar errors fail inactive without propagating");

-- Exercise the production wiring with 1.12-style event/this globals and frames.
local frames = {};
local cvars = {};
local writes = {};
local wall = 1800001000;
local runClock = 0;
local gamePhase = "playing";
local function frameStub(name)
    local frame = { shown = true, scripts = {} };
    function frame:SetWidth(value) self.width = value; end
    function frame:SetHeight(value) self.height = value; end
    function frame:SetPoint(point, relative, relativePoint, x, y)
        self.point = point; self.relative = relative; self.relativePoint = relativePoint; self.x = x; self.y = y;
    end
    function frame:GetPoint() return self.point, self.relative, self.relativePoint, self.x, self.y; end
    function frame:ClearAllPoints() end
    function frame:SetFrameStrata() end
    function frame:SetMovable(value) self.movable = value; end
    function frame:SetClampedToScreen(value) self.clamped = value; end
    function frame:EnableMouse() end
    function frame:RegisterForDrag() end
    function frame:SetBackdrop() end
    function frame:SetBackdropColor() end
    function frame:SetJustifyH() end
    function frame:SetText(value) self.text = value; end
    function frame:GetText() return self.text; end
    function frame:SetScript(key, callback) self.scripts[key] = callback; end
    function frame:RegisterEvent() end
    function frame:StartMoving() self.moving = true; end
    function frame:StopMovingOrSizing() self.moving = false; end
    function frame:SetAutoFocus() end
    function frame:SetMaxLetters() end
    function frame:ClearFocus() end
    function frame:Show() self.shown = true; end
    function frame:Hide() self.shown = false; end
    function frame:CreateFontString() return frameStub(); end
    if (name) then frames[name] = frame; end
    return frame;
end

UIParent = frameStub("UIParent");
CreateFrame = function(kind, name) return frameStub(name); end;
RegisterCVar = function(name, value) if (not cvars[name]) then cvars[name] = value; end end;
SetCVar = function(name, value) cvars[name] = value; table.insert(writes, value); end;
GetNumPartyMembers = function() return 0; end;
GetNumRaidMembers = function() return 0; end;
AZS_PARTY = {};
AZS_GetPhase = function() return gamePhase; end;
AZS_GetRunTime = function() return runClock; end;
time = function() return wall; end;
SlashCmdList = {};
AZSSpeedGearDB = { show = false, point = "CENTER", relativePoint = "CENTER", x = 35, y = -40 };
AZSSpeedGear_TEST = nil;
loadMain();
local driver = AZSSpeedGear.driver;
local function fire(name, argument)
    event = name;
    arg1 = argument;
    this = driver;
    driver.scripts.OnEvent();
end
fire("ADDON_LOADED", "AZSSpeedGear");
check(not AZSSpeedGear.panel.shown, "saved hidden panel restored");
check(AZSSpeedGear.panel.x == 35 and AZSSpeedGear.panel.y == -40, "saved position restored");
fire("PLAYER_ENTERING_WORLD");
check(AZSSpeedGear.controller.active and AZSSpeedGear.controller.speed100 == 100, "world entry starts at x1");
SlashCmdList.AZSSPEEDGEAR("2");
check(AZSSpeedGear.controller.speed100 == 200, "slash speed request reaches CVar bridge");
SlashCmdList.AZSSPEEDGEAR("hide");
local beforeHeartbeat = table.getn(writes);
wall = wall + 3;
runClock = 3;
driver.scripts.OnUpdate();
check(table.getn(writes) == beforeHeartbeat + 1, "hidden panel keeps real-time heartbeat");
check(AZSSpeedGear.controller.measured == 1, "production measurement reports actual x1 for x2 request");
AZS_PARTY = { { name = "Friend" } };
driver.scripts.OnUpdate();
check(not AZSSpeedGear.controller.active and string.find(cvars.AZSSpeedGearCommand, "|100|0$") ~= nil, "AZS_PARTY blocks stale zero native party counts");
AZS_PARTY = {};
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.speed100 == 200, "same run resumes desired speed after protection clears");
gamePhase = "paused";
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.speed100 == 100 and AZSSpeedGear.controller.desiredSpeed100 == 200, "pause suspends command and retains intent");
gamePhase = "playing";
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.speed100 == 200, "resume restores same-run desired speed");
SlashCmdList.AZSSPEEDGEAR("show");
check(AZSSpeedGear.panel.shown and AZSSpeedGearDB.show, "slash show restores panel");
frames.AZSSpeedGearPreset1.scripts.OnClick();
check(AZSSpeedGear.controller.speed100 == 50, "x0.5 preset closure");
frames.AZSSpeedGearPreset5.scripts.OnClick();
check(AZSSpeedGear.controller.speed100 == 500, "x5 preset closure");
frames.AZSSpeedGearCustom:SetText("0.25");
frames.AZSSpeedGearApply.scripts.OnClick();
check(AZSSpeedGear.controller.speed100 == 25, "custom x0.25 applies");
frames.AZSSpeedGearStop.scripts.OnClick();
check(AZSSpeedGear.controller.speed100 == 100 and AZSSpeedGear.controller.desiredSpeed100 == 100, "UI emergency clears current and desired speed");
SlashCmdList.AZSSPEEDGEAR("3");
fire("PLAYER_LEAVING_WORLD");
driver.scripts.OnUpdate();
check(not AZSSpeedGear.controller.active and AZSSpeedGear.controller.desiredSpeed100 == 100, "stale playing phase cannot reactivate after world exit");
fire("PLAYER_ENTERING_WORLD");
check(AZSSpeedGear.controller.speed100 == 100, "new world defaults x1");
check(AZSSpeedGearDB.speed100 == nil and AZSSpeedGearDB.desiredSpeed100 == nil, "speeds never enter SavedVariables");

local function clickLauncher()
    this = AZSSpeedGear.launcher;
    this.scripts.OnMouseDown();
    this.scripts.OnClick();
end

check(AZSSpeedGear.launcher.shown and AZSSpeedGear.launcher.movable, "independent launcher is visible and movable in world");
check(AZSSpeedGear.launcher.clamped and AZSSpeedGear.panel.clamped, "launcher and panel use native screen clamping");
SlashCmdList.AZSSPEEDGEAR("hide");
check(AZSSpeedGear.launcher.shown and not AZSSpeedGear.panel.shown, "slash hide affects panel only");
clickLauncher();
check(AZSSpeedGear.panel.shown and AZSSpeedGearDB.show, "launcher click opens panel");
clickLauncher();
check(not AZSSpeedGear.panel.shown and not AZSSpeedGearDB.show, "launcher click closes panel");
clickLauncher();
frames.AZSSpeedGearClose.scripts.OnClick();
check(AZSSpeedGear.launcher.shown and not AZSSpeedGear.panel.shown, "panel close button leaves launcher available");

-- Dragging saves a separate anchor and must not also toggle the panel.
this = AZSSpeedGear.launcher;
this.scripts.OnMouseDown();
this.scripts.OnDragStart();
check(this.moving, "launcher begins native movement");
this:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -92, -128);
this.scripts.OnDragStop();
check(not this.moving, "launcher stops native movement");
check(AZSSpeedGearDB.launcherPoint == "TOPRIGHT" and AZSSpeedGearDB.launcherRelativePoint == "TOPRIGHT"
    and AZSSpeedGearDB.launcherX == -92 and AZSSpeedGearDB.launcherY == -128, "launcher position saved independently");
check(AZSSpeedGearDB.x == 35 and AZSSpeedGearDB.y == -40, "launcher drag does not overwrite panel anchor");
this.scripts.OnClick();
check(not AZSSpeedGear.panel.shown, "drag release click cannot toggle panel");
clickLauncher();
check(AZSSpeedGear.panel.shown, "normal click after drag works");
-- Some clients do not dispatch OnClick after a drag: the next press still works.
this = AZSSpeedGear.launcher;
this.scripts.OnMouseDown();
this.scripts.OnDragStart();
this.scripts.OnDragStop();
clickLauncher();
check(not AZSSpeedGear.panel.shown, "next mouse press clears suppression when drag emitted no click");

this = AZSSpeedGear.panel;
this.scripts.OnDragStart();
this:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 120, 160);
this.scripts.OnDragStop();
check(AZSSpeedGearDB.point == "BOTTOMLEFT" and AZSSpeedGearDB.x == 120 and AZSSpeedGearDB.y == 160,
    "panel retains its independent drag persistence");
check(AZSSpeedGearDB.launcherX == -92 and AZSSpeedGearDB.launcherY == -128, "panel drag does not overwrite launcher anchor");

local heartbeatWithHiddenLauncher = table.getn(writes);
AZSSpeedGear.launcher:Hide();
wall = wall + 3;
runClock = runClock + 3;
driver.scripts.OnUpdate();
check(table.getn(writes) == heartbeatWithHiddenLauncher + 1 and AZSSpeedGear.controller.active,
    "hiding launcher does not stop independent heartbeat driver");
fire("PLAYER_LEAVING_WORLD");
check(not AZSSpeedGear.launcher.shown, "world exit hides launcher");
fire("PLAYER_ENTERING_WORLD");
check(AZSSpeedGear.launcher.shown, "world entry restores launcher");

-- Reload using the retained database: both positions and old panel preference survive.
SlashCmdList.AZSSPEEDGEAR("show");
loadMain();
driver = AZSSpeedGear.driver;
fire("ADDON_LOADED", "AZSSpeedGear");
check(AZSSpeedGear.panel.shown and AZSSpeedGearDB.show, "existing shown preference survives reload");
check(AZSSpeedGear.panel.point == "BOTTOMLEFT" and AZSSpeedGear.panel.x == 120 and AZSSpeedGear.panel.y == 160,
    "panel anchor restored after reload");
check(AZSSpeedGear.launcher.point == "TOPRIGHT" and AZSSpeedGear.launcher.x == -92 and AZSSpeedGear.launcher.y == -128,
    "launcher anchor restored after reload");
check(not AZSSpeedGear.launcher.shown, "launcher stays hidden until world entry after reload");
fire("PLAYER_ENTERING_WORLD");
check(AZSSpeedGear.launcher.shown, "reloaded launcher appears on world entry");

AZSSpeedGearDB.launcherPoint = "INVALID";
AZSSpeedGearDB.launcherX = 0 / 0;
AZSSpeedGearDB.launcherY = 100000;
loadMain();
driver = AZSSpeedGear.driver;
fire("ADDON_LOADED", "AZSSpeedGear");
check(AZSSpeedGear.launcher.point == "RIGHT" and AZSSpeedGear.launcher.x == -24 and AZSSpeedGear.launcher.y == 80,
    "invalid saved launcher coordinates fall back to visible default anchor");
check(AZSSpeedGear.panel.x == 120 and AZSSpeedGear.panel.y == 160, "invalid launcher data does not affect panel position");

AZSSpeedGearDB = nil;
loadMain();
driver = AZSSpeedGear.driver;
fire("ADDON_LOADED", "AZSSpeedGear");
fire("PLAYER_ENTERING_WORLD");
check(AZSSpeedGearDB.show == false and not AZSSpeedGear.panel.shown and AZSSpeedGear.launcher.shown,
    "fresh install starts with launcher only");

-- The original locale checks exercise idle captions; active measurement text is
-- covered below, including a language switch after a confirmed speed change.
gamePhase = "paused";
driver.scripts.OnUpdate();
local selectedSpeed = AZSSpeedGear.controller.speed100;
local savedLauncherX = AZSSpeedGearDB.launcherX;
AZSSpeedGearNativeLocale = "ja";
wall = wall + 1;
driver.scripts.OnUpdate();
check(AZSSpeedGearI18n.code == "ja", "UI follows native Japanese selection");
check(AZSSpeedGear.launcher.text == AZSSpeedGearI18n.catalogs.ja.launcher, "floating launcher caption switches language");
check(frames.AZSSpeedGearClose.text == AZSSpeedGearI18n.catalogs.ja.close, "existing close button switches without rebuild");
check(frames.AZSSpeedGearApply.text == AZSSpeedGearI18n.catalogs.ja.apply, "existing apply button switches language");
check(AZSSpeedGear.controller.speed100 == selectedSpeed and AZSSpeedGearDB.launcherX == savedLauncherX,
    "language refresh preserves speed state and position");
AZSSpeedGearNativeLocale = "de";
wall = wall + 1;
driver.scripts.OnUpdate();
check(AZSSpeedGear.launcher.text == AZSSpeedGearI18n.catalogs.de.launcher, "floating launcher follows German selection");
check(AZSSpeedGear.launcher.width >= 64 and AZSSpeedGear.launcher.width <= 160, "localized launcher stays within readable width limits");
check(AZSSpeedGearDB.language == nil, "language synchronization does not persist an override");

-- Confirmed launcher suffixes must come from the real measurement state machine.
-- Never seed controller.measured directly: advance the wall and game clocks.
AZSSpeedGearNativeLocale = "zh";
gamePhase = "playing";
AZS_PARTY = {};
fire("PLAYER_LEAVING_WORLD");
fire("PLAYER_ENTERING_WORLD");
SlashCmdList.AZSSPEEDGEAR("hide");
SlashCmdList.AZSSPEEDGEAR("2");
local launcherCaption = AZSSpeedGearI18n.Text("launcher");
check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "new x2 request shows pending rather than an unverified success");
wall = wall + 3;
runClock = runClock + 6;
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.measured == 2, "launcher x2 confirmation uses measured game progress");
check(not AZSSpeedGear.panel.shown and AZSSpeedGear.launcher.text == launcherCaption .. " ×2",
    "confirmed x2 appears on launcher while main panel is hidden");

SlashCmdList.AZSSPEEDGEAR("5");
check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "requesting x5 immediately removes the old confirmed x2 caption");
wall = wall + 3;
runClock = runClock + 3;
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.measured == 1 and AZSSpeedGear.controller.speed100 == 500,
    "failed x5 switch retains honest measured x1");
check(AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "measured x1 cannot confirm a requested x5 launcher suffix");

SlashCmdList.AZSSPEEDGEAR("0.5");
wall = wall + 4;
runClock = runClock + 2;
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.measured == 0.5 and AZSSpeedGear.launcher.text == launcherCaption .. " ×0.5",
    "confirmed fractional x0.5 uses a compact decimal suffix");
SlashCmdList.AZSSPEEDGEAR("0.5");
wall = wall + 4;
runClock = runClock + 1;
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.measured == 0.25, "low-speed mismatch fixture measures actual x0.25");
check(AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "requested x0.5 with actual x0.25 cannot use the panel's broad absolute tolerance");

SlashCmdList.AZSSPEEDGEAR("stop");
check(AZSSpeedGear.controller.speed100 == 100 and AZSSpeedGear.controller.measured == nil
    and AZSSpeedGear.launcher.text == launcherCaption .. " …", "emergency x1 remains pending until measured");
wall = wall + 3;
runClock = runClock + 3;
driver.scripts.OnUpdate();
check(AZSSpeedGear.controller.measured == 1 and AZSSpeedGear.launcher.text == launcherCaption .. " ×1",
    "emergency restore gains a confirmed x1 suffix only after measurement");
gamePhase = "paused";
driver.scripts.OnUpdate();
check(not AZSSpeedGear.controller.active and AZSSpeedGear.controller.measured == nil
    and AZSSpeedGear.launcher.text == launcherCaption, "pause removes all pending and confirmed launcher suffixes");

gamePhase = "playing";
driver.scripts.OnUpdate();
SlashCmdList.AZSSPEEDGEAR("2");
wall = wall + 3;
runClock = runClock + 6;
driver.scripts.OnUpdate();
check(AZSSpeedGear.launcher.text == launcherCaption .. " ×2", "same-run resumed x2 can be confirmed again");
local confirmedSpeed = AZSSpeedGear.controller.speed100;
local confirmedLauncherX = AZSSpeedGear.launcher.x;
local confirmedLauncherY = AZSSpeedGear.launcher.y;
AZSSpeedGearNativeLocale = "ja";
wall = wall + 1;
runClock = runClock + 2;
driver.scripts.OnUpdate();
check(AZSSpeedGearI18n.code == "ja" and AZSSpeedGear.launcher.text == AZSSpeedGearI18n.catalogs.ja.launcher .. " ×2",
    "Japanese refresh preserves the confirmed suffix after rebinding captions");
check(AZSSpeedGear.launcher.width > 64 and AZSSpeedGear.launcher.width <= 160,
    "fallback launcher width includes the complete Japanese caption and confirmed suffix");
check(AZSSpeedGear.controller.speed100 == confirmedSpeed and AZSSpeedGear.launcher.x == confirmedLauncherX
    and AZSSpeedGear.launcher.y == confirmedLauncherY, "confirmed caption localization preserves speed and launcher anchor");

print("AZSSpeedGear addon state and protocol: " .. checks .. " checks passed");

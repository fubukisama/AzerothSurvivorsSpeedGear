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

for code, catalog in pairs(AZSSpeedGearI18n.catalogs) do
    check(catalog.title == "AzerothSurvivorsSpeedGear", "project title remains exact English repository name in " .. code);
end

local function fixture(available, pulseMode)
    local state = { now = 1800000000, run = 0, client = 1000, rawT = 0, rawUpdated = 1000,
        phase = "ready", solo = true, sent = {}, pulses = {} };
    local api = {
        now = function() return state.now; end,
        random = function() return 321; end,
        phase = function() return state.phase; end,
        isSolo = function() return state.solo; end,
        runTime = function() return state.run; end,
        clientClock = function() return state.client; end,
        rawRunSample = function() return { t = state.rawT, updated = state.rawUpdated }; end,
        register = function() return available ~= false; end,
        send = function(command) table.insert(state.sent, command); return true; end
    };
    if (pulseMode) then
        api.pulse = function()
            table.insert(state.pulses, state.now);
            if (pulseMode == "error") then error("console unavailable"); end
            if (pulseMode == "false") then return false; end
            return true;
        end;
    end
    local controller = AZSSpeedGear.NewController(api);
    return state, controller;
end

local function latest(state)
    return state.sent[table.getn(state.sent)];
end

local function advanceFixture(state, controller, seconds, rate)
    local startNow, startRun, startClient = state.now, state.run, state.client;
    local frame = 1;
    local published = 0;
    while (frame <= seconds * 60) do
        local elapsed = frame / 60;
        state.now = startNow + math.floor(elapsed + 1e-9);
        state.run = startRun + rate * elapsed;
        state.client = startClient + elapsed;
        local publication = math.floor((elapsed + 1e-9) / 0.2);
        if (publication > published) then
            state.rawT = startRun + rate * publication * 0.2;
            state.rawUpdated = startClient + publication * 0.2;
            published = publication;
        end
        controller:Update();
        frame = frame + 1;
    end
end

local state, controller = fixture();
controller:Update();
check(latest(state) == "SG1|1800000000321|1|1800000000|100|0", "initial inactive protocol");
check(controller.sendStatus == "file_only", "CVar-only capability is not reported as backend confirmation");
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
check(table.getn(state.sent) == count, "fallback heartbeat not sent before five real seconds");
state.now = state.now + 1;
state.run = 15;
controller:Update();
check(table.getn(state.sent) == count, "three seconds no longer dirties fallback config");
check(controller.confirmedSpeed100 == nil, "sparse smooth-clock samples alone cannot confirm x5");
advanceFixture(state, controller, 2, 5);
check(table.getn(state.sent) == count + 1, "fallback heartbeat writes at five real seconds");

local pulsed, pulsedController = fixture(true, true);
pulsed.phase = "playing";
pulsedController:Update();
local pulseWrites = table.getn(pulsed.sent);
local pulseQueries = table.getn(pulsed.pulses);
pulsedController:RequestSpeed(500);
check(table.getn(pulsed.sent) == pulseWrites + 1 and table.getn(pulsed.pulses) == pulseQueries + 1,
    "new request emits immediately and immediately queries its CVar");
check(pulsedController.sendStatus == "instant_attempt", "successful pulse reports only an instant request attempt");
pulseWrites = table.getn(pulsed.sent);
pulseQueries = table.getn(pulsed.pulses);
advanceFixture(pulsed, pulsedController, 4, 5);
check(table.getn(pulsed.pulses) == pulseQueries + 4 and table.getn(pulsed.sent) == pulseWrites,
    "one-second console pulses keep delivery fresh without dirtying config");
pulsedController:Update();
check(table.getn(pulsed.pulses) == pulseQueries + 4, "multiple frame updates in one second do not duplicate console pulses");
advanceFixture(pulsed, pulsedController, 1, 5);
check(table.getn(pulsed.sent) == pulseWrites + 1 and table.getn(pulsed.pulses) == pulseQueries + 5,
    "five-second fallback write includes one query without a duplicate periodic pulse");
local failedPulse, failedPulseController = fixture(true, "error");
failedPulse.phase = "playing";
failedPulseController:Update();
check(failedPulseController:RequestSpeed(200) and failedPulseController.bridgeReady and failedPulseController.active,
    "failed console pulse does not disable successful CVar fallback");
check(failedPulseController.sendStatus == "file_only", "throwing pulse reports file fallback capability without a receipt");
local writesBeforePulseFailure = table.getn(failedPulse.sent);
advanceFixture(failedPulse, failedPulseController, 5, 2);
check(table.getn(failedPulse.sent) == writesBeforePulseFailure + 1 and failedPulseController.bridgeReady,
    "console failure still permits subsequent five-second fallback writes");
local rejectedPulse, rejectedPulseController = fixture(true, "false");
rejectedPulse.phase = "playing";
rejectedPulseController:Update();
check(rejectedPulseController.sendStatus == "file_only" and rejectedPulseController.bridgeReady,
    "explicitly rejected pulse leaves CVar fallback available");

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
check(noBridge.sendStatus == "unavailable", "missing request API is distinct from file fallback");
check(not noBridge:RequestSpeed(200), "missing channel refuses commands");

local unknown, noPhase = fixture();
unknown.phase = nil;
noPhase:Update();
check(not noPhase.active and string.find(latest(unknown), "|100|0$") ~= nil, "missing game API remains inactive");

local measured, meter = fixture();
measured.phase = "playing";
meter:Update();
advanceFixture(measured, meter, 4, 1);
check(meter.measured and math.abs(meter.measured - 1) < 0.05, "actual x1 displayed from fresh raw observations");
meter:RequestSpeed(500);
check(meter.measured == nil, "speed request clears old measurement");
advanceFixture(measured, meter, 4, 1);
check(meter.measured and math.abs(meter.measured - 1) < 0.05 and meter.speed100 == 500, "failed acceleration is honestly measured x1");
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
check(jitterMeter.confirmedSpeed100 == nil, "smooth-clock corrections without raw publications remain unconfirmed");
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
check(jitterMeter.measured == nil and jitterMeter.confirmedSpeed100 == nil,
    "significant rollback clears measurement and waits for another observed boundary");
advanceFixture(jitter, jitterMeter, 4, 1);
check(jitterMeter.measured and math.abs(jitterMeter.measured - 1) < 0.05, "fresh raw observations restore measurement after rollback");

local aligned, alignedMeter = fixture();
aligned.phase = "playing";
aligned.run = 100;
alignedMeter:Update();
alignedMeter:RequestSpeed(500);
aligned.run = 104.5;
alignedMeter:Update();
check(alignedMeter.measured == nil and alignedMeter.confirmedSpeed100 == nil,
    "within-second progress cannot create a partial-window confirmation");
aligned.now = aligned.now + 1;
aligned.run = 105;
alignedMeter:Update();
check(alignedMeter.confirmedSpeed100 == nil,
    "later coarse samples without a fresh raw publication remain uncertain");
aligned.now = aligned.now + 1;
aligned.run = 110;
alignedMeter:Update();
check(alignedMeter.confirmedSpeed100 == nil,
    "one coarse second cannot manufacture confirmation from smooth-clock values");
alignedMeter:RequestSpeed(100);
check(alignedMeter.measured == nil and alignedMeter.confirmedSpeed100 == nil,
    "every request invalidates both measured and confirmed state");

local broken, bad = fixture();
bad.api.send = function() error("unavailable CVar"); end;
broken.phase = "playing";
bad:Update();
check(not bad.active and not bad.bridgeReady and bad.speed100 == 100, "CVar errors fail inactive without propagating");
check(bad.sendStatus == "unavailable", "failed CVar send cannot retain an instant-attempt capability");

-- Exercise the production wiring with 1.12-style event/this globals and frames.
local frames = {};
local cvars = {};
local writes = {};
local queries = {};
local wall = 1800001000;
local runClock = 0;
local uiClientClock = 1000;
local gamePhase = "playing";
local function frameStub(name)
    local frame = { shown = true, scripts = {}, fontStrings = {} };
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
    function frame:CreateFontString()
        local font = frameStub();
        table.insert(self.fontStrings, font);
        return font;
    end
    if (name) then frames[name] = frame; end
    return frame;
end

UIParent = frameStub("UIParent");
CreateFrame = function(kind, name) return frameStub(name); end;
RegisterCVar = function(name, value) if (not cvars[name]) then cvars[name] = value; end end;
SetCVar = function(name, value) cvars[name] = value; table.insert(writes, value); end;
ConsoleExec = function(command) table.insert(queries, command); end;
GetNumPartyMembers = function() return 0; end;
GetNumRaidMembers = function() return 0; end;
AZS_PARTY = {};
AZS_GetPhase = function() return gamePhase; end;
AZS_GetRunTime = function() return runClock; end;
AZS_RUN = { t = 0 };
AZS_RUN_UPDATED = 1000;
GetTime = function() return uiClientClock; end;
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
local function advanceUI(seconds, rate)
    -- Physical observation cadence and client clock are fixed independently of
    -- the requested speed. Only this explicit actual-rate oracle moves raw t.
    local startWall, startRun, startClient = wall, runClock, uiClientClock;
    local frame = 1;
    local published = 0;
    while (frame <= seconds * 60) do
        local elapsed = frame / 60;
        wall = startWall + math.floor(elapsed + 1e-9);
        runClock = startRun + rate * elapsed;
        uiClientClock = startClient + elapsed;
        local publication = math.floor((elapsed + 1e-9) / 0.2);
        if (publication > published) then
            AZS_RUN.t = startRun + rate * publication * 0.2;
            AZS_RUN_UPDATED = startClient + publication * 0.2;
            published = publication;
        end
        driver.scripts.OnUpdate();
        frame = frame + 1;
    end
end
local function hasPanelText(text)
    local index = 1;
    while (index <= table.getn(AZSSpeedGear.panel.fontStrings)) do
        if (AZSSpeedGear.panel.fontStrings[index].text == text) then return true; end
        index = index + 1;
    end
    return false;
end
fire("ADDON_LOADED", "AZSSpeedGear");
check(not AZSSpeedGear.panel.shown, "saved hidden panel restored");
check(AZSSpeedGear.panel.x == 35 and AZSSpeedGear.panel.y == -40, "saved position restored");
fire("PLAYER_ENTERING_WORLD");
check(AZSSpeedGear.controller.active and AZSSpeedGear.controller.speed100 == 100, "world entry starts at x1");
check(AZSSpeedGear.controller.sendStatus == "instant_attempt" and hasPanelText(AZSSpeedGearI18n.Text("send_instant_attempt")),
    "production nil-returning ConsoleExec is displayed as an attempt rather than native acknowledgement");
check(hasPanelText("AzerothSurvivorsSpeedGear"), "panel title uses exact English project name");
SlashCmdList.AZSSPEEDGEAR("2");
check(AZSSpeedGear.controller.speed100 == 200, "slash speed request reaches CVar bridge");
SlashCmdList.AZSSPEEDGEAR("hide");
local beforeHeartbeat = table.getn(writes);
local queriesBeforeHeartbeat = table.getn(queries);
advanceUI(5, 1);
check(table.getn(writes) == beforeHeartbeat + 1, "hidden panel keeps real-time heartbeat");
check(table.getn(queries) == queriesBeforeHeartbeat + 5 and queries[table.getn(queries)] == "AZSSpeedGearCommand",
    "hidden panel retains one-second queries of only the owned command CVar");
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 1) < 0.05, "production measurement reports fresh raw x1 for x2 request");
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
advanceUI(5, 1);
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
advanceUI(2, 2);
check(AZSSpeedGear.controller.measured and AZSSpeedGear.controller.confirmedSpeed100 == nil
    and not AZSSpeedGear.controller.measurementMismatch, "wide interval remains uncertain even when its point estimate matches x2");
check(hasPanelText(string.format(AZSSpeedGearI18n.Text("target_wait"), "2"))
    and not hasPanelText(AZSSpeedGearI18n.Text("below_target")), "uncertainty is shown as measuring rather than a false speed mismatch");
advanceUI(2, 2);
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 2) < 0.05, "launcher x2 confirmation uses independent raw progress");
check(not AZSSpeedGear.panel.shown and AZSSpeedGear.launcher.text == launcherCaption .. " ×2",
    "confirmed x2 appears on launcher while main panel is hidden");
SlashCmdList.AZSSPEEDGEAR("2");
advanceUI(4, 4);
check(AZSSpeedGear.controller.measurementMismatch and AZSSpeedGear.controller.confirmedSpeed100 == nil
    and hasPanelText(AZSSpeedGearI18n.Text("below_target")), "independent x4 progress against requested x2 reports a generic mismatch, not a successful speed");

SlashCmdList.AZSSPEEDGEAR("5");
check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "requesting x5 immediately removes the old confirmed x2 caption");
advanceUI(4, 1);
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 1) < 0.05 and AZSSpeedGear.controller.speed100 == 500,
    "failed x5 switch retains honest measured x1");
check(AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "measured x1 cannot confirm a requested x5 launcher suffix");

SlashCmdList.AZSSPEEDGEAR("0.5");
advanceUI(4, 0.5);
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 0.5) < 0.05 and AZSSpeedGear.launcher.text == launcherCaption .. " ×0.5",
    "confirmed fractional x0.5 uses a compact decimal suffix");
SlashCmdList.AZSSPEEDGEAR("0.5");
advanceUI(4, 0.25);
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 0.25) < 0.05, "low-speed mismatch fixture measures actual x0.25");
check(AZSSpeedGear.launcher.text == launcherCaption .. " …",
    "requested x0.5 with actual x0.25 cannot use the panel's broad absolute tolerance");

SlashCmdList.AZSSPEEDGEAR("stop");
check(AZSSpeedGear.controller.speed100 == 100 and AZSSpeedGear.controller.measured == nil
    and AZSSpeedGear.launcher.text == launcherCaption .. " …", "emergency x1 remains pending until measured");
advanceUI(4, 1);
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 1) < 0.05 and AZSSpeedGear.launcher.text == launcherCaption .. " ×1",
    "emergency restore gains a confirmed x1 suffix only after measurement");
gamePhase = "paused";
driver.scripts.OnUpdate();
check(not AZSSpeedGear.controller.active and AZSSpeedGear.controller.measured == nil
    and AZSSpeedGear.launcher.text == launcherCaption, "pause removes all pending and confirmed launcher suffixes");

gamePhase = "playing";
driver.scripts.OnUpdate();
SlashCmdList.AZSSPEEDGEAR("2");
advanceUI(4, 2);
check(AZSSpeedGear.launcher.text == launcherCaption .. " ×2", "same-run resumed x2 can be confirmed again");
local confirmedSpeed = AZSSpeedGear.controller.speed100;
local confirmedLauncherX = AZSSpeedGear.launcher.x;
local confirmedLauncherY = AZSSpeedGear.launcher.y;
AZSSpeedGearNativeLocale = "ja";
advanceUI(1, 2);
check(AZSSpeedGearI18n.code == "ja" and AZSSpeedGear.launcher.text == AZSSpeedGearI18n.catalogs.ja.launcher .. " ×2",
    "Japanese refresh preserves the confirmed suffix after rebinding captions");
check(AZSSpeedGear.launcher.width > 64 and AZSSpeedGear.launcher.width <= 160,
    "fallback launcher width includes the complete Japanese caption and confirmed suffix");
check(AZSSpeedGear.controller.speed100 == confirmedSpeed and AZSSpeedGear.launcher.x == confirmedLauncherX
    and AZSSpeedGear.launcher.y == confirmedLauncherY, "confirmed caption localization preserves speed and launcher anchor");

-- Diagnostic baselines: the fixture observes integer time() and immediate CVar
-- writes only. It cannot measure config-file flushing, native application time,
-- physical movement, or a 0.2-second duration within the same Unix second.
gamePhase = "playing";
AZSSpeedGearNativeLocale = "zh";
wall = math.floor(wall) + 1;
fire("PLAYER_LEAVING_WORLD");
fire("PLAYER_ENTERING_WORLD");
local baselineCaption = AZSSpeedGearI18n.Text("launcher");
local function sampleBaseline(seconds, actualRate)
    advanceUI(seconds, actualRate);
end
local writesBeforeRequest = table.getn(writes);
local requestedAt = wall;
SlashCmdList.AZSSPEEDGEAR("5");
check(table.getn(writes) == writesBeforeRequest + 1, "speed request writes CVar without waiting for the measurement window");
local switchingNotice = nil;
local noticeIndex = 1;
while (noticeIndex <= table.getn(AZSSpeedGear.panel.fontStrings)) do
    local label = AZSSpeedGear.panel.fontStrings[noticeIndex];
    if (label.text == AZSSpeedGearI18n.Text("switching")) then switchingNotice = label; end
    noticeIndex = noticeIndex + 1;
end
check(switchingNotice ~= nil, "unconfirmed request retains a visible switching notice");
sampleBaseline(1, 5);
check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == baselineCaption .. " …",
    "baseline x5 remains pending after one integer clock tick");
sampleBaseline(3, 5);
check(AZSSpeedGear.controller.measured and math.abs(AZSSpeedGear.controller.measured - 5) < 0.05 and AZSSpeedGear.launcher.text == baselineCaption .. " ×5",
    "x5 confirms only after a sufficiently bounded raw observation window");
check(switchingNotice.text == AZSSpeedGearI18n.Text("hint"), "confirmed speed clears the stale switching notice even with panel hidden");
print("BASELINE request->CVar=0 fixture ticks; request->launcher-confirm=" .. (wall - requestedAt)
    .. " integer seconds (perfect immediate x5 response; native latency not modeled)");

local rapidSpeeds = { 100, 500, 100, 500, 100, 500 };
local rapidIndex = 1;
while (rapidIndex <= table.getn(rapidSpeeds)) do
    local nextRate = rapidSpeeds[rapidIndex] / 100;
    SlashCmdList.AZSSPEEDGEAR(tostring(nextRate));
    check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == baselineCaption .. " …",
        "rapid switch immediately removes previous confirmation " .. rapidIndex);
    sampleBaseline(1, nextRate);
    check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == baselineCaption .. " …",
        "rapid switch cannot inherit a previous measurement " .. rapidIndex);
    rapidIndex = rapidIndex + 1;
end
sampleBaseline(3, 5);
check(AZSSpeedGear.launcher.text == baselineCaption .. " ×5", "rapid-switch sequence confirms only after settling on its final target");
print("BASELINE rapid 1<->5: 6 requests one integer second apart; stale success captions=0; confirmation follows a bounded raw observation window");

local transientPhases = { "choosing", "paused" };
local transientIndex = 1;
while (transientIndex <= table.getn(transientPhases)) do
    local beforeTransient = table.getn(writes);
    gamePhase = transientPhases[transientIndex];
    driver.scripts.OnUpdate();
    check(not AZSSpeedGear.controller.active and AZSSpeedGear.controller.measured == nil
        and AZSSpeedGear.launcher.text == baselineCaption, "same-second transient clears current confirmation " .. gamePhase);
    gamePhase = "playing";
    driver.scripts.OnUpdate();
    check(AZSSpeedGear.controller.active and AZSSpeedGear.controller.speed100 == 500
        and AZSSpeedGear.controller.measured == nil and AZSSpeedGear.launcher.text == baselineCaption .. " …",
        "same-second resume retains target but restarts confirmation " .. transientPhases[transientIndex]);
    check(table.getn(writes) == beforeTransient + 2
        and string.find(writes[beforeTransient + 1], "|100|0$") ~= nil
        and string.find(writes[beforeTransient + 2], "|500|1$") ~= nil,
        "same-second transient emits inactive then active commands " .. transientPhases[transientIndex]);
    sampleBaseline(4, 5);
    check(AZSSpeedGear.launcher.text == baselineCaption .. " ×5", "transient resume requires a new full measurement window");
    transientIndex = transientIndex + 1;
end
print("BASELINE short choosing/paused: same-second active0->active1, desired x5 retained, confirmation requires new bounded raw observations");
print("SEAM LIMIT: integer time() cannot establish a 0.2s delay or whether both CVar values reached native code before config coalescing");

sampleBaseline(4, 4.4);
check(AZSSpeedGear.controller.speed100 == 500 and AZSSpeedGear.controller.confirmedSpeed100 == nil
    and AZSSpeedGear.launcher.text == baselineCaption .. " …",
    "sustained twelve-percent deviation revokes x5 confirmation within the bounded grace period");
sampleBaseline(8, 4.9);
check(AZSSpeedGear.controller.speed100 == 500 and AZSSpeedGear.launcher.text == baselineCaption .. " ×5",
    "same target regains its success caption when a later measured window matches");
print("BASELINE fixed target x5: sustained x4.4 revokes confirmation; fresh x4.9 observations can re-establish it");
sampleBaseline(4, 1);
check(AZSSpeedGear.controller.confirmedSpeed100 == nil
    and AZSSpeedGear.launcher.text == baselineCaption .. " …", "a clear speed failure immediately revokes prior confirmation");
sampleBaseline(1, 4.4);
check(AZSSpeedGear.controller.confirmedSpeed100 == nil and AZSSpeedGear.launcher.text == baselineCaption .. " …",
    "hysteresis cannot grant a fresh confirmation outside the strict entry threshold");
sampleBaseline(8, 4.9);
check(AZSSpeedGear.controller.confirmedSpeed100 == 500, "matching observation can re-establish confirmation after a real mismatch");
sampleBaseline(4, 0);
check(AZSSpeedGear.controller.measured == nil and AZSSpeedGear.controller.confirmedSpeed100 == nil
    and AZSSpeedGear.launcher.text == baselineCaption .. " …", "a frozen run clock cannot retain a successful speed caption");
ConsoleExec = nil;
local writesWithoutConsole = table.getn(writes);
advanceUI(5, 5);
check(AZSSpeedGear.controller.bridgeReady and AZSSpeedGear.controller.active and table.getn(writes) == writesWithoutConsole + 1,
    "missing ConsoleExec leaves the real production adapter's CVar fallback working");
check(AZSSpeedGear.controller.sendStatus == "file_only" and hasPanelText(AZSSpeedGearI18n.Text("send_file_only")),
    "missing ConsoleExec refreshes sender capability while the panel is hidden");
ConsoleExec = function() return false; end;
advanceUI(1, 5);
check(AZSSpeedGear.controller.sendStatus == "file_only" and AZSSpeedGear.controller.bridgeReady,
    "production rejected ConsoleExec result preserves honest fallback state");
ConsoleExec = function() error("console call failed"); end;
advanceUI(1, 5);
check(AZSSpeedGear.controller.sendStatus == "file_only" and AZSSpeedGear.controller.bridgeReady,
    "production throwing ConsoleExec result preserves fallback state");
ConsoleExec = function(command) table.insert(queries, command); end;
advanceUI(1, 5);
check(AZSSpeedGear.controller.sendStatus == "instant_attempt" and hasPanelText(AZSSpeedGearI18n.Text("send_instant_attempt")),
    "successful later pulse refreshes sender capability without claiming backend connection");
AZSSpeedGearNativeLocale = "ja";
advanceUI(1, 5);
check(hasPanelText(AZSSpeedGearI18n.catalogs.ja.send_instant_attempt) and hasPanelText("AzerothSurvivorsSpeedGear"),
    "language change translates sender capability and keeps English project title");
local statusMessages = {};
DEFAULT_CHAT_FRAME = { AddMessage = function(self, text) table.insert(statusMessages, text); end };
local beforeStatusWrites = table.getn(writes);
local beforeStatusSpeed = AZSSpeedGear.controller.speed100;
SlashCmdList.AZSSPEEDGEAR("status");
check(table.getn(statusMessages) == 2 and string.find(statusMessages[1], AZSSpeedGearI18n.Text("send_instant_attempt"), 1, true) ~= nil
    and string.find(statusMessages[2], "AZSSpeedGear-status.json", 1, true) ~= nil,
    "status command gives sender capability and the actual native diagnostic filename");
check(table.getn(writes) == beforeStatusWrites and AZSSpeedGear.controller.speed100 == beforeStatusSpeed,
    "status inspection does not emit speed requests or alter the selected speed");

print("AZSSpeedGear addon state and protocol: " .. checks .. " checks passed");

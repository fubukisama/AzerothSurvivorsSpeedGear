-- Real production driver/UI fixture. Run only with the remote Lua 5.0 runner.
-- Wall seconds, client-clock scale and callback cadence are independent inputs.
local checks = 0;
local function check(value, message)
    checks = checks + 1;
    if (not value) then error(message); end
end

local frames, cvars, bindings = {}, {}, { Q = "STRAFELEFT", E = "STRAFERIGHT" };
local physical, clientClock, gameRun = 0.125, 1000, 100;
local wallOffset, missingWall, phase = 0, false, "playing";
local counters = { measuredFormats = 0, hotkeyFormats = 0, bodyWrites = 0, controllerCalls = 0 };
local realFormat = string.format;
string.format = function(pattern, ...)
    if (AZSSpeedGearI18n) then
        if (pattern == AZSSpeedGearI18n.Text("measured")) then
            counters.measuredFormats = counters.measuredFormats + 1;
        end
        if (pattern == AZSSpeedGearI18n.Text("hotkey_down") or pattern == AZSSpeedGearI18n.Text("hotkey_up")) then
            counters.hotkeyFormats = counters.hotkeyFormats + 1;
        end
    end
    return realFormat(pattern, unpack(arg));
end;

local function invoke(frame, script, value)
    local oldThis, oldArg = this, arg1;
    this, arg1 = frame, value;
    if (frame and frame.scripts[script]) then frame.scripts[script](); end
    this, arg1 = oldThis, oldArg;
end
local function stub(name, kind, parent)
    local frame = { name = name, kind = kind, parent = parent, shown = true, scripts = {}, fonts = {} };
    function frame:SetWidth(value) self.width = value; end
    function frame:SetHeight(value) self.height = value; end
    function frame:GetWidth() return self.width or 100; end
    function frame:GetHeight() return self.height or 20; end
    function frame:SetFont(face, size, flags) self.face, self.size, self.flags = face, size, flags; end
    function frame:GetFont() return self.face or "fixture", self.size or 12, self.flags or ""; end
    function frame:GetFontString()
        if (self.kind ~= "Button") then return nil; end
        if (not self.font) then self.font = stub(nil, "ButtonFont", self); end
        return self.font;
    end
    function frame:GetStringWidth() return string.len(self:GetText() or "") * (self.size or 12) * 0.55; end
    function frame:GetStringHeight() return (self.size or 12) * 1.2; end
    function frame:SetPoint(point, relative, relativePoint, x, y)
        self.point, self.relative, self.relativePoint, self.x, self.y = point, relative, relativePoint, x, y;
    end
    function frame:GetPoint() return self.point or "CENTER", self.relative or UIParent, self.relativePoint or "CENTER", self.x or 0, self.y or 0; end
    function frame:ClearAllPoints() end
    function frame:SetFrameStrata() end
    function frame:SetMovable() end
    function frame:SetClampedToScreen() end
    function frame:EnableMouse() end
    function frame:EnableKeyboard(value) self.keyboard = value and true or false; end
    function frame:RegisterForDrag() end
    function frame:SetBackdrop() end
    function frame:SetBackdropColor() end
    function frame:SetJustifyH() end
    function frame:SetTextColor() end
    function frame:SetAutoFocus() end
    function frame:SetMaxLetters() end
    function frame:StartMoving() end
    function frame:StopMovingOrSizing() end
    function frame:LockHighlight() self.highlighted = true; end
    function frame:UnlockHighlight() self.highlighted = false; end
    function frame:SetText(value)
        self.text = value;
        local w = AZSSpeedGear and AZSSpeedGear.panelWidgets;
        if (w and (self == w.status or self == w.measurement or self == w.sending or self == w.notice)) then
            counters.bodyWrites = counters.bodyWrites + 1;
        end
    end
    function frame:GetText()
        if (self.kind == "ButtonFont") then return self.parent.text; end
        return self.text;
    end
    function frame:SetScript(script, callback) self.scripts[script] = callback; end
    function frame:RegisterEvent() end
    function frame:ClearFocus() invoke(self, "OnEditFocusLost"); end
    function frame:Show()
        local changed = not self.shown; self.shown = true;
        if (changed) then invoke(self, "OnShow"); end
    end
    function frame:Hide()
        local changed = self.shown; self.shown = false;
        if (changed) then invoke(self, "OnHide"); end
    end
    function frame:IsShown() return self.shown; end
    function frame:CreateFontString()
        local font = stub(nil, "FontString", self); table.insert(self.fonts, font); return font;
    end
    if (name) then frames[name] = frame; _G[name] = frame; end
    return frame;
end

UIParent = stub("UIParent"); UIParent:SetWidth(960); UIParent:SetHeight(540);
GameFontNormal = stub("GameFontNormal", "Font");
GameTooltip = stub("GameTooltip"); GameTooltip:Hide();
function GameTooltip:SetOwner(owner) self.owner = owner; end
ChatFrameEditBox = stub("ChatFrameEditBox"); ChatFrameEditBox:Hide();
ChatFrame1EditBox = stub("ChatFrame1EditBox"); ChatFrame1EditBox:Hide();
GameMenuFrame = stub("GameMenuFrame"); GameMenuFrame:Hide();
CreateFrame = function(kind, name, parent) return stub(name, kind, parent); end;
RegisterCVar = function(name, value) if (not cvars[name]) then cvars[name] = value; end end;
SetCVar = function(name, value) cvars[name] = value; end;
ConsoleExec = function() return true; end;
GetNumPartyMembers = function() return 0; end;
GetNumRaidMembers = function() return 0; end;
AZS_PARTY = {};
AZS_GetPhase = function() return phase; end;
AZS_GetRunTime = function() return gameRun; end;
AZS_RUN, AZS_RUN_UPDATED = { t = gameRun }, clientClock;
GetTime = function() return clientClock; end;
time = function()
    if (missingWall) then return nil; end
    return 1800000000 + math.floor(physical + 1e-9) + wallOffset;
end;
GetBindingAction = function(key) return bindings[key] or ""; end;
SetBinding = function(key, action) bindings[key] = action; return 1; end;
IsAltKeyDown = function() return false; end;
IsControlKeyDown = function() return false; end;
IsShiftKeyDown = function() return false; end;
SlashCmdList = {};
AZSSpeedGearNativeLocale = "en";
AZSSpeedGearDB = { show = false };
AZSSpeedGear_TEST = nil;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/Hotkeys.lua");
dofile("AddOns/AZSSpeedGear/Diagnostics.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");

local driver, controller = AZSSpeedGear.driver, AZSSpeedGear.controller;
local realUpdate = controller.Update;
local measurementOverride, mismatch = 2.07, false;
controller.Update = function(self)
    counters.controllerCalls = counters.controllerCalls + 1;
    realUpdate(self);
    -- The display seam receives changing, independently supplied measurement
    -- values after the real controller has processed clock, phase and guard.
    if (self.active) then
        self.measured = measurementOverride;
        self.measurementMismatch = mismatch;
        self.confirmedSpeed100 = not mismatch and self.speed100 or nil;
    end
end;
local function fire(name, value)
    local oldEvent = event; event = name; invoke(driver, "OnEvent", value); event = oldEvent;
end
local function step(fps, clientRate)
    physical = physical + 1 / fps; clientClock = clientClock + clientRate / fps;
    gameRun = gameRun + 1 / fps;
    AZS_RUN.t, AZS_RUN_UPDATED = gameRun, clientClock;
    invoke(driver, "OnUpdate", clientRate / fps);
end
local function run(seconds, fps, clientRate)
    local index = 1;
    while (index <= math.floor(seconds * fps + 0.5)) do
        measurementOverride = 2 + math.mod(index, 90) / 1000;
        step(fps, clientRate); index = index + 1;
    end
end
local function resetCounts()
    counters.measuredFormats, counters.hotkeyFormats, counters.bodyWrites, counters.controllerCalls = 0, 0, 0, 0;
end
local function click(name) invoke(frames[name], "OnClick"); end
local function measurementText() return AZSSpeedGear.panelWidgets.measurement:GetText(); end
local function expectedMeasurement() return realFormat(AZSSpeedGearI18n.Text("measured"), controller.measured); end
local function show() SlashCmdList.AZSSPEEDGEAR("show"); end
local function hide() SlashCmdList.AZSSPEEDGEAR("hide"); end

fire("ADDON_LOADED", "AZSSpeedGear"); fire("PLAYER_ENTERING_WORLD");
SlashCmdList.AZSSPEEDGEAR("2"); run(2, 60, 1);
check(not AZSSpeedGear.panel:IsShown(), "fixture begins with the real panel hidden");
resetCounts(); run(5, 60, 1);
check(counters.controllerCalls == 300, "all 300 hidden frames still execute the production controller");
check(counters.measuredFormats == 0, "hidden panel does not format changing measurement text");
check(counters.bodyWrites == 0, "hidden panel does not rewrite body widgets");
check(counters.hotkeyFormats == 0, "unchanged hidden hotkeys do not rebuild their captions every frame");

measurementOverride = 2.07; controller.measured = measurementOverride;
show();
check(AZSSpeedGear.panel:IsShown() and measurementText() == expectedMeasurement(),
    "opening the panel displays its current measurement immediately");

local rates = { 0.25, 1, 5 };
for _, rate in ipairs(rates) do
    run(2, 60, rate); resetCounts(); run(5, 60, rate);
    check(counters.controllerCalls == 300, "UI budget does not throttle the controller at client clock " .. rate);
    check(counters.measuredFormats >= 20 and counters.measuredFormats <= 52,
        "steady numeric refresh stays in a bounded wall-second budget at client clock " .. rate);
end

-- The cadence adapts to actual callback counts, not a presumed 60 FPS clock.
run(2, 10, 1); resetCounts(); run(3, 10, 1);
check(counters.controllerCalls == 30 and counters.measuredFormats >= 12 and counters.measuredFormats <= 32,
    "a 60-to-10 FPS transition retains bounded useful display updates");
run(2, 120, 1); resetCounts(); run(3, 120, 1);
check(counters.controllerCalls == 360 and counters.measuredFormats >= 12 and counters.measuredFormats <= 32,
    "a 10-to-120 FPS transition does not multiply the display budget");

-- A numeric budget cannot delay input, target changes, warnings or restoration.
SlashCmdList.AZSSPEEDGEAR("5");
check(controller.speed100 == 500 and string.find(AZSSpeedGear.launcher.text, "5", 1, true),
    "a speed request updates controller and floating caption synchronously");
click("AZSSpeedGearStop");
check(controller.speed100 == 100 and controller.desiredSpeed100 == 100,
    "emergency stop bypasses the numeric display budget");
check(AZSSpeedGear.StepHotkey(1) and controller.speed100 == 200,
    "a faster shortcut is delivered without waiting for the display budget");
check(AZSSpeedGear.StepHotkey(-1) and controller.speed100 == 100,
    "a slower shortcut is delivered without waiting for the display budget");
frames.AZSSpeedGearCustom:SetText("1.5"); click("AZSSpeedGearApply");
check(controller.speed100 == 150 and string.find(AZSSpeedGear.launcher.text, "1.5", 1, true) ~= nil,
    "custom input updates the target and caption synchronously");
SlashCmdList.AZSSPEEDGEAR("2");
mismatch = true; step(60, 1);
check(string.find(AZSSpeedGear.launcher.text, "!", 1, true) ~= nil,
    "a new mismatch warning updates the floating caption in the same frame");
mismatch = false; step(60, 1);

-- Protection runs before rendering, with the exact existing 250ms/3-frame rule.
SlashCmdList.AZSSPEEDGEAR("5");
step(60, 0.25 * 60); step(60, 0.25 * 60);
check(not controller.frameGuardTripped, "two exact 250ms steps do not trip protection");
step(60, 0.251 * 60); step(60, 0.251 * 60);
check(not controller.frameGuardTripped, "two over-budget frames remain insufficient");
step(60, 0.251 * 60);
check(controller.frameGuardTripped and controller.speed100 == 100,
    "the third over-budget frame restores 1x without waiting for a display slot");
check(AZSSpeedGear.panelWidgets.status:GetText() == AZSSpeedGearI18n.Text("frame_guard"),
    "the protection notice is visible immediately");

SlashCmdList.AZSSPEEDGEAR("2"); run(1, 60, 1);
hide(); run(1, 60, 1);
measurementOverride = 2.08; controller.measured = measurementOverride;
show(); check(measurementText() == expectedMeasurement(), "reopening never shows a stale hidden measurement");

click("AZSSpeedGearHotkeyDown");
check(frames.AZSSpeedGearHotkeyDown.text == "…", "starting rebinding updates its button immediately");
invoke(AZSSpeedGear.panel, "OnKeyDown", "R");
check(string.find(frames.AZSSpeedGearHotkeyDown.text, "R", 1, true) ~= nil,
    "custom binding completion updates its caption synchronously");
invoke(AZSSpeedGear.panel, "OnDragStart"); run(0.2, 60, 1);
invoke(AZSSpeedGear.panel, "OnDragStop");
check(not AZSSpeedGear.panel.speedGearDragging, "drag completion is not owned by the numeric timer");

AZSSpeedGearNativeLocale = "ja"; wallOffset = wallOffset + 1; step(60, 1);
check(AZSSpeedGear.panelWidgets.status:GetText() == realFormat(AZSSpeedGearI18n.Text("target_measured"), "2"),
    "language changes refresh visible status immediately");

measurementOverride = 2.09; wallOffset = wallOffset + 100; step(60, 1);
check(measurementText() == expectedMeasurement(), "a forward wall-clock jump resets the display budget");
measurementOverride = 2.01; wallOffset = wallOffset - 500; step(60, 1);
check(measurementText() == expectedMeasurement(), "a backward wall-clock jump cannot freeze the display");
missingWall = true; step(60, 1);
check(AZSSpeedGear.panelWidgets.status:GetText() == AZSSpeedGearI18n.Text("real_clock_unavailable"),
    "a missing independent clock is shown immediately");
click("AZSSpeedGearStop");
check(controller.desiredSpeed100 == 100, "stop remains safe with a missing wall clock");
missingWall = false; wallOffset = 0; step(60, 1);
check(AZSSpeedGear.panelWidgets.status:GetText() ~= AZSSpeedGearI18n.Text("real_clock_unavailable"),
    "a recovered clock resumes visible status without reopening the panel");

hide(); invoke(AZSSpeedGear.launcher, "OnEnter"); run(2, 60, 1);
resetCounts(); run(3, 60, 1);
check(GameTooltip:IsShown() and counters.measuredFormats >= 12 and counters.measuredFormats <= 32,
    "visible tooltip numbers share the bounded refresh cadence while the panel stays hidden");
check(counters.bodyWrites == 0, "hovering the launcher does not wake hidden panel body writes");
invoke(AZSSpeedGear.launcher, "OnLeave");

-- The optional controls use the same production panel and driver. They do not
-- alter key handling, statistical events or the existing frame guard.
check(not controller:DiagnosticsEnabled(), "diagnostic recording starts off");
check(AZSSpeedGear.lightweightCombatText == false, "lightweight text starts off");
show(); click("AZSSpeedGearDetails");
check(frames.AZSSpeedGearLightText:IsShown() and frames.AZSSpeedGearDiagnosticToggle:IsShown(),
    "optional controls are reachable in Details");
check(type(AZSSpeedGearDiagnostics.NewRecorder) == "function",
    "named native widgets cannot replace the diagnostic module global");
local beforeFlag = AZSSpeedGear.lightweightCombatText;
KeijinUI = nil; click("AZSSpeedGearLightText");
check(AZSSpeedGear.lightweightCombatText == beforeFlag, "missing Keijin cannot claim an active display mode");
KeijinUI = {damageText={azsgPerformanceRevision=1}};
click("AZSSpeedGearLightText");
check(AZSSpeedGear.lightweightCombatText and AZSSpeedGearDB.lightweightCombatText,
    "compatible lightweight mode persists an explicit opt-in");
click("AZSSpeedGearLightText");
check(not AZSSpeedGear.lightweightCombatText and AZSSpeedGearDB.lightweightCombatText == false,
    "lightweight display can be restored without changing speed");
click("AZSSpeedGearDiagnosticToggle"); run(1, 60, 1);
check(controller:DiagnosticsEnabled(), "diagnostics start only after clicking their control");
local trace = controller:ExportDiagnostics();
check(trace.frameCount > 0 and trace.nativeReceiptAvailable == false,
    "diagnostic context is available without inventing native receipts");
click("AZSSpeedGearKeepTrace");
check(AZSSpeedGearDB.diagnosticTrace and AZSSpeedGearDB.diagnosticTrace.frameCount > 0,
    "the snapshot button retains a bounded report in the addon's own save");
trace.frames[1].phase = "untrusted";
check(controller:ExportDiagnostics().frames[1].phase ~= "untrusted", "exported rows do not alias the recorder");
SlashCmdList.AZSSPEEDGEAR("5");
step(60, 0.251 * 60); step(60, 0.251 * 60); step(60, 0.251 * 60);
check(controller.frameGuardTripped and controller.speed100 == 100,
    "enabled diagnostics preserve the same third-frame restoration");
run(1, 60, 1);
local _, _, frozen = controller:DiagnosticCounts();
check(frozen and AZSSpeedGearDB.diagnosticTrace.framesFrozen,
    "the first protected window is automatically retained after its bounded post-window");
click("AZSSpeedGearDiagnosticToggle");
check(not controller:DiagnosticsEnabled(), "the record control stops collection immediately");
local languages = {"en","zh","ja","pl","cs","de","pt","es","fr","ro","tr","ru","uk","ko"};
for _, code in ipairs(languages) do
    AZSSpeedGearNativeLocale = code; AZSSpeedGearI18n.Refresh();
    check(frames.AZSSpeedGearLightText.text == AZSSpeedGearI18n.Text("perf_lite_off"),
        "lightweight caption follows game language: " .. code);
    check(frames.AZSSpeedGearDiagnosticToggle.text == AZSSpeedGearI18n.Text("diagnostics_off"),
        "diagnostic caption follows game language: " .. code);
    for _, control in ipairs({frames.AZSSpeedGearLightText,frames.AZSSpeedGearDiagnosticToggle,frames.AZSSpeedGearKeepTrace}) do
        check(control:GetWidth() <= AZSSpeedGear.panel:GetWidth() - 32,
            "optional button width fits the panel: " .. code);
    end
end
click("AZSSpeedGearDiagnosticToggle"); hide(); run(0.2, 60, 1);
fire("PLAYER_LEAVING_WORLD");
check(not controller:DiagnosticsEnabled() and AZSSpeedGearDB.diagnosticTrace,
    "leaving the world stops recording and retains the last report");

string.format = realFormat;
print("UI refresh budget checks passed: " .. checks);

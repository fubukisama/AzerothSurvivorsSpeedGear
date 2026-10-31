-- Production Lua/UI/Bindings.xml integration, run only by remote Lua 5.0 CI.
-- This fake client cannot establish OS key delivery or native game acceptance.
local checks = 0;
local function check(condition, message)
    checks = checks + 1;
    if (not condition) then error(message); end
end
local function copy(source)
    local result = {};
    for key, value in pairs(source) do result[key] = value; end
    return result;
end
local function same(left, right)
    for key, value in pairs(left) do if (right[key] ~= value) then return false; end end
    for key, value in pairs(right) do if (left[key] ~= value) then return false; end end
    return true;
end

local frames, writes, cvars = {}, {}, {};
local wall, clientClock = 1800001000, 1000;
local gamePhase = "playing";
local bindings = { Q = "STRAFELEFT", E = "STRAFERIGHT", W = "MOVEFORWARD",
    A = "TURNLEFT", S = "MOVEBACKWARD", D = "TURNRIGHT", R = "RELOAD" };
local originals = copy(bindings);
local gameActions, savedBindings, saveArgument = {}, nil, nil;
local saveThrows = false;
local modifiers = { alt = false, ctrl = false, shift = false };

local function invoke(frame, script, argument)
    local previousThis, previousArg = this, arg1;
    this, arg1 = frame, argument;
    if (frame.scripts[script]) then frame.scripts[script](); end
    this, arg1 = previousThis, previousArg;
end

local function frameStub(name)
    local frame = { shown = true, scripts = {}, fontStrings = {}, events = {}, keyboard = false };
    function frame:SetWidth(value) self.width = value; end
    function frame:SetHeight(value) self.height = value; end
    function frame:SetPoint(point, relative, relativePoint, x, y)
        self.point, self.relative, self.relativePoint, self.x, self.y = point, relative, relativePoint, x, y;
    end
    function frame:GetPoint() return self.point, self.relative, self.relativePoint, self.x, self.y; end
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
    function frame:SetText(value) self.text = value; end
    function frame:GetText() return self.text; end
    function frame:SetScript(script, callback) self.scripts[script] = callback; end
    function frame:RegisterEvent(name) self.events[name] = true; end
    function frame:StartMoving() end
    function frame:StopMovingOrSizing() end
    function frame:SetAutoFocus() end
    function frame:SetMaxLetters() end
    function frame:ClearFocus() invoke(self, "OnEditFocusLost"); end
    function frame:Show() self.shown = true; end
    function frame:Hide()
        local wasShown = self.shown;
        self.shown = false;
        if (wasShown) then invoke(self, "OnHide"); end
    end
    function frame:IsShown() return self.shown; end
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
ConsoleExec = function() return true; end;
GetNumPartyMembers = function() return 0; end;
GetNumRaidMembers = function() return 0; end;
AZS_PARTY = {};
AZS_GetPhase = function() return gamePhase; end;
AZS_GetRunTime = function() return 0; end;
AZS_RUN, AZS_RUN_UPDATED = { t = 0 }, clientClock;
GetTime = function() return clientClock; end;
time = function() return wall; end;
GetBindingAction = function(key) return bindings[key] or ""; end;
SetBinding = function(key, action) bindings[key] = action; return 1; end;
SaveBindings = function(scope)
    saveArgument = scope;
    savedBindings = copy(bindings);
    if (saveThrows) then error("original SaveBindings failure"); end
    return 1;
end;
IsAltKeyDown = function() return modifiers.alt; end;
IsControlKeyDown = function() return modifiers.ctrl; end;
IsShiftKeyDown = function() return modifiers.shift; end;
ChatFrameEditBox = frameStub("ChatFrameEditBox"); ChatFrameEditBox:Hide();
ChatFrame1EditBox = frameStub("ChatFrame1EditBox"); ChatFrame1EditBox:Hide();
GameMenuFrame = frameStub("GameMenuFrame"); GameMenuFrame:Hide();
SlashCmdList = {};
AZSSpeedGearNativeLocale = "en";
AZSSpeedGearDB = { show = false };
AZSSpeedGear_TEST = nil;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/Hotkeys.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");

-- Compile the packaged XML bodies rather than duplicating their implementation.
local xmlFile = assert(io.open("AddOns/AZSSpeedGear/Bindings.xml", "r"));
local xml = xmlFile:read("*a"); xmlFile:close();
local actions, actionCount = {}, 0;
for name, body in string.gfind(xml, '<Binding%s+name="([^"]+)"[^>]*>(.-)</Binding>') do
    actions[name] = assert(loadstring(body, "Bindings.xml:" .. name));
    actionCount = actionCount + 1;
end
check(actionCount == 2 and actions.AZSG_SLOWER and actions.AZSG_FASTER,
    "packaged Bindings.xml provides both executable shortcut actions");

local driver = AZSSpeedGear.driver;
local function fire(name, argument)
    local previousEvent = event;
    event = name; invoke(driver, "OnEvent", argument); event = previousEvent;
end
local function press(key)
    local panel = AZSSpeedGear.panel;
    if (panel and panel.keyboard) then invoke(panel, "OnKeyDown", key); return; end
    local action = bindings[key];
    if (actions[action]) then actions[action]();
    elseif (action) then table.insert(gameActions, action); end
end
local function release(key) invoke(AZSSpeedGear.panel, "OnKeyUp", key); end
local function click(name) invoke(frames[name], "OnClick"); end
local function hasPanelText(text)
    for _, font in ipairs(AZSSpeedGear.panel.fontStrings) do
        if (font.text == text) then return true; end
    end
    return false;
end
local function latest() return writes[table.getn(writes)]; end
local function checkSpeed(speed100, message)
    check(AZSSpeedGear.controller.speed100 == speed100 and AZSSpeedGear.controller.desiredSpeed100 == speed100,
        message .. " updates controller intent");
    check(string.find(latest(), "|" .. speed100 .. "|1$") ~= nil, message .. " reaches the SG1 CVar bridge");
end

check(same(bindings, originals), "loading addon source leaves the base key map unchanged");
fire("ADDON_LOADED", "AZSSpeedGear");
check(same(bindings, originals) and not AZSSpeedGear.hotkeys.active,
    "saved-variable loading before world entry does not override game keys");
check(AZSSpeedGearDB.hotkeyDown == "Q" and AZSSpeedGearDB.hotkeyUp == "E",
    "production load initializes persistent Q and E defaults");
check(not AZSSpeedGear.panel.shown and not AZSSpeedGear.panel.keyboard, "hidden panel never owns raw keyboard input");
fire("PLAYER_ENTERING_WORLD");
check(bindings.Q == "AZSG_SLOWER" and bindings.E == "AZSG_FASTER", "world entry installs the XML binding actions");
checkSpeed(100, "world entry x1");
press("Q"); checkSpeed(50, "hidden-panel Q to x0.5");
press("Q"); checkSpeed(25, "hidden-panel Q to x0.25");
local previousWrites = table.getn(writes);
press("Q"); press("Q");
check(AZSSpeedGear.controller.speed100 == 25 and table.getn(writes) == previousWrites,
    "minimum speed clamps with no redundant request or wrap");
local faster = { 50, 100, 200, 300, 500, 1000 };
for _, speed in ipairs(faster) do press("E"); checkSpeed(speed, "hidden-panel E to " .. speed); end
previousWrites = table.getn(writes);
press("E"); press("E");
check(AZSSpeedGear.controller.speed100 == 1000 and table.getn(writes) == previousWrites,
    "maximum speed clamps with no redundant request or wrap");
check(not AZSSpeedGear.panel.shown and not AZSSpeedGear.panel.keyboard,
    "using shortcuts never opens the panel or enables keyboard capture");

SlashCmdList.AZSSPEEDGEAR("show");
check(AZSSpeedGear.panel.shown and not AZSSpeedGear.panel.keyboard,
    "an ordinary open panel does not capture movement keys");
local movementKeys = { "W", "A", "S", "D" };
local movementBefore = table.getn(gameActions);
for _, key in ipairs(movementKeys) do press(key); end
check(table.getn(gameActions) == movementBefore + 4 and bindings.W == originals.W and bindings.A == originals.A
    and bindings.S == originals.S and bindings.D == originals.D, "opening the panel preserves all WASD game bindings");
frames.AZSSpeedGearCustom:SetText("1.5"); click("AZSSpeedGearApply");
checkSpeed(150, "custom x1.5");
press("Q"); checkSpeed(100, "custom x1.5 slower neighbor");
frames.AZSSpeedGearCustom:SetText("1.5"); click("AZSSpeedGearApply");
press("E"); checkSpeed(200, "custom x1.5 faster neighbor");

invoke(frames.AZSSpeedGearCustom, "OnEditFocusGained");
previousWrites = table.getn(writes); press("Q"); press("E");
check(table.getn(writes) == previousWrites and AZSSpeedGear.controller.speed100 == 200,
    "typing in the custom speed field blocks shortcut execution");
invoke(frames.AZSSpeedGearCustom, "OnEditFocusLost");
local blockedFrames = { ChatFrameEditBox, ChatFrame1EditBox, GameMenuFrame };
for _, frame in ipairs(blockedFrames) do
    frame:Show(); previousWrites = table.getn(writes); press("Q"); press("E");
    check(table.getn(writes) == previousWrites and AZSSpeedGear.controller.speed100 == 200,
        "visible chat or game menu blocks shortcut execution");
    frame:Hide();
end
press("Q"); checkSpeed(100, "shortcut resumes after text input ends");

click("AZSSpeedGearHotkeyDown");
check(AZSSpeedGear.panel.keyboard and frames.AZSSpeedGearHotkeyDown.text == "…"
    and hasPanelText(AZSSpeedGearI18n.Text("hotkey_listening")), "clicking a binding starts visible temporary capture");
previousWrites = table.getn(writes); press("SHIFT"); press("UNKNOWN");
check(AZSSpeedGear.panel.keyboard and AZSSpeedGearDB.hotkeyDown == "Q" and table.getn(writes) == previousWrites,
    "modifier-only and unknown events keep listening without changing bindings or speed");
modifiers.alt, modifiers.ctrl, modifiers.shift = true, 1, true;
press("R");
modifiers.alt, modifiers.ctrl, modifiers.shift = false, false, false;
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyDown == nil,
    "successful capture immediately stops raw keyboard input");
check(AZSSpeedGearDB.hotkeyDown == "ALT-CTRL-SHIFT-R" and bindings["ALT-CTRL-SHIFT-R"] == "AZSG_SLOWER"
    and bindings.Q == "STRAFELEFT", "modifier capture saves canonical chord and restores the previous game action");
check(frames.AZSSpeedGearHotkeyDown.text == string.format(AZSSpeedGearI18n.Text("hotkey_down"), "ALT-CTRL-SHIFT-R"),
    "binding button displays the captured chord");
press("ALT-CTRL-SHIFT-R"); checkSpeed(50, "captured chord uses real XML dispatch");
click("AZSSpeedGearHotkeyReset");
check(AZSSpeedGearDB.hotkeyDown == "Q" and AZSSpeedGearDB.hotkeyUp == "E" and bindings["ALT-CTRL-SHIFT-R"] == nil,
    "reset restores Q and E and removes previously unbound custom chord");

-- A delayed client may report the OS modifier as released while dispatching an
-- earlier key-down. The recorder must retain the modifier event order itself.
modifiers.alt, modifiers.ctrl, modifiers.shift = false, nil, false;
previousWrites = table.getn(writes);
click("AZSSpeedGearHotkeyUp"); press("CTRL"); press("T");
check(AZSSpeedGearDB.hotkeyUp == "CTRL-T" and bindings["CTRL-T"] == "AZSG_FASTER"
    and bindings.E == "STRAFERIGHT", "queued CTRL then T captures CTRL-T even when the native modifier query is nil");
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyDown == nil
    and AZSSpeedGear.panel.scripts.OnKeyUp == nil, "successful queued modifier capture removes both keyboard handlers");
click("AZSSpeedGearHotkeyReset");
click("AZSSpeedGearHotkeyUp"); press("CTRL"); release("CTRL"); press("T");
check(AZSSpeedGearDB.hotkeyUp == "T" and bindings.T == "AZSG_FASTER" and bindings["CTRL-T"] == nil,
    "a modifier released before the normal key is not retained in the chord");
click("AZSSpeedGearHotkeyReset");
modifiers.ctrl = 1;
click("AZSSpeedGearHotkeyUp"); press("CTRL"); release("CTRL"); press("T");
modifiers.ctrl = nil;
check(AZSSpeedGearDB.hotkeyUp == "T" and bindings.T == "AZSG_FASTER" and bindings["CTRL-T"] == nil,
    "an observed Ctrl release overrides a stale native query that still reports Ctrl held");
click("AZSSpeedGearHotkeyReset");
click("AZSSpeedGearHotkeyDown"); press("SHIFT"); press("ALT"); press("CTRL"); press("R");
check(AZSSpeedGearDB.hotkeyDown == "ALT-CTRL-SHIFT-R" and bindings["ALT-CTRL-SHIFT-R"] == "AZSG_SLOWER",
    "queued Shift Alt and Ctrl events form a canonical combined chord with stale native queries");
click("AZSSpeedGearHotkeyReset");
click("AZSSpeedGearHotkeyUp"); press("SHIFT"); press("ALT"); release("ALT"); press("T");
check(AZSSpeedGearDB.hotkeyUp == "SHIFT-T" and bindings["SHIFT-T"] == "AZSG_FASTER",
    "releasing Alt clears only Alt while the queued Shift press remains held");
click("AZSSpeedGearHotkeyReset");

-- The native query is still needed when a modifier was already held before
-- clicking the recorder and therefore has no key-down event in this capture.
modifiers.ctrl = 1;
click("AZSSpeedGearHotkeyUp"); press("T");
modifiers.ctrl = nil;
check(AZSSpeedGearDB.hotkeyUp == "CTRL-T" and bindings["CTRL-T"] == "AZSG_FASTER",
    "a modifier already held before recording is read from the native query");
click("AZSSpeedGearHotkeyReset");

click("AZSSpeedGearHotkeyUp"); press("CTRL"); press("ESCAPE");
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyDown == nil
    and AZSSpeedGear.panel.scripts.OnKeyUp == nil, "Escape removes both capture handlers after a modifier press");
click("AZSSpeedGearHotkeyUp"); press("T");
check(AZSSpeedGearDB.hotkeyUp == "T", "cancelled recording does not leak a modifier into the next recording");
click("AZSSpeedGearHotkeyReset");
click("AZSSpeedGearHotkeyUp"); press("SHIFT"); AZSSpeedGear.panel:Hide();
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyDown == nil
    and AZSSpeedGear.panel.scripts.OnKeyUp == nil, "panel hide removes both capture handlers after a modifier press");
SlashCmdList.AZSSPEEDGEAR("show");
click("AZSSpeedGearHotkeyUp"); press("T");
check(AZSSpeedGearDB.hotkeyUp == "T", "hidden recording does not leak a modifier into the next recording");
click("AZSSpeedGearHotkeyReset");
check(table.getn(writes) == previousWrites, "recording queued modifiers never changes speed or emits a speed request");
modifiers.alt, modifiers.ctrl, modifiers.shift = false, false, false;

click("AZSSpeedGearHotkeyUp"); press("Q");
check(AZSSpeedGear.panel.keyboard and AZSSpeedGearDB.hotkeyUp == "E"
    and hasPanelText(AZSSpeedGearI18n.Text("hotkey_duplicate")), "duplicate assignment reports the problem and keeps listening");
press("ESCAPE");
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyUp == nil and AZSSpeedGearDB.hotkeyUp == "E"
    and hasPanelText(AZSSpeedGearI18n.Text("hotkey_hint")), "Escape cancels duplicate capture without changing settings");
click("AZSSpeedGearHotkeyUp"); press("BACKSPACE");
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGearDB.hotkeyUp == "" and bindings.E == "STRAFERIGHT",
    "Backspace disables a shortcut and restores its original game action");
check(frames.AZSSpeedGearHotkeyUp.text == string.format(AZSSpeedGearI18n.Text("hotkey_up"), AZSSpeedGearI18n.Text("hotkey_unbound")),
    "disabled shortcut caption uses the localized unbound label");
click("AZSSpeedGearHotkeyReset");
check(AZSSpeedGearDB.hotkeyDown == "Q" and AZSSpeedGearDB.hotkeyUp == "E" and not AZSSpeedGear.panel.keyboard,
    "reset returns both settings to defaults without leaving capture enabled");

local liveBindings = copy(bindings);
check(SaveBindings(2) == 1 and saveArgument == 2, "wrapped production SaveBindings forwards its scope and result");
check(same(savedBindings, originals), "game saving clones the original key table rather than temporary addon overrides");
check(same(bindings, liveBindings), "game saving immediately reapplies live addon shortcuts");
for _, action in pairs(savedBindings) do
    check(action ~= "AZSG_SLOWER" and action ~= "AZSG_FASTER", "saved key map contains no temporary addon command");
end
saveThrows = true;
local saveOk, saveError = pcall(SaveBindings, 2);
saveThrows = false;
check(not saveOk and string.find(tostring(saveError), "original SaveBindings failure", 1, true)
    and same(bindings, liveBindings), "throwing original SaveBindings preserves its error and restores live shortcuts");

click("AZSSpeedGearHotkeyDown");
check(AZSSpeedGear.panel.keyboard, "capture begins before panel-hide cancellation");
AZSSpeedGear.panel:Hide();
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyDown == nil and AZSSpeedGear.panel.scripts.OnKeyUp == nil,
    "native OnHide cancels capture and removes its keyboard handler");
SlashCmdList.AZSSPEEDGEAR("show");
check(not AZSSpeedGear.panel.keyboard, "reopening the panel does not resume stale capture");

-- Refresh existing widgets in every supported language without rebuilding them.
local downButton, upButton, resetButton = frames.AZSSpeedGearHotkeyDown, frames.AZSSpeedGearHotkeyUp, frames.AZSSpeedGearHotkeyReset;
for code, catalog in pairs(AZSSpeedGearI18n.catalogs) do
    AZSSpeedGearNativeLocale = code;
    wall = wall + 1;
    invoke(driver, "OnUpdate");
    check(downButton.text == string.format(catalog.hotkey_down, "Q")
        and upButton.text == string.format(catalog.hotkey_up, "E") and resetButton.text == catalog.hotkey_reset,
        "existing hotkey buttons follow game language " .. code);
end
check(AZSSpeedGearDB.hotkeyDown == "Q" and AZSSpeedGearDB.hotkeyUp == "E" and same(bindings, liveBindings),
    "language refresh preserves custom settings and binding ownership");

click("AZSSpeedGearHotkeyUp");
fire("PLAYER_LEAVING_WORLD");
check(not AZSSpeedGear.panel.keyboard and AZSSpeedGear.panel.scripts.OnKeyDown == nil and AZSSpeedGear.panel.scripts.OnKeyUp == nil,
    "world exit cancels active capture");
check(same(bindings, originals) and not AZSSpeedGear.hotkeys.active, "world exit restores the complete original game key map");
check(not AZSSpeedGear.controller.active and AZSSpeedGear.controller.desiredSpeed100 == 100,
    "world exit resets speed intent to x1");
previousWrites = table.getn(writes); press("E");
check(table.getn(writes) == previousWrites and gameActions[table.getn(gameActions)] == "STRAFERIGHT",
    "outside the world E retains its base game action and sends no speed request");
fire("PLAYER_ENTERING_WORLD");
check(bindings.Q == "AZSG_SLOWER" and bindings.E == "AZSG_FASTER" and not AZSSpeedGear.panel.keyboard,
    "next world reinstalls saved shortcuts without restarting capture");
press("E"); checkSpeed(200, "shortcut works after world reentry");
fire("PLAYER_LOGOUT");
check(same(bindings, originals) and not AZSSpeedGear.panel.keyboard, "logout releases all temporary bindings and keyboard capture");

print("Production hotkey UI/XML checks passed: " .. checks);

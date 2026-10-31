-- Run from the repository root with stock Lua 5.0 in remote CI only.
dofile("AddOns/AZSSpeedGear/Hotkeys.lua");
local Hotkeys = AZSSpeedGearHotkeys;
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
    for key, value in pairs(left) do
        if (right[key] ~= value) then return false; end
    end
    for key, value in pairs(right) do
        if (left[key] ~= value) then return false; end
    end
    return true;
end

local function fixture(database)
    local state = {
        bindings = { Q = "STRAFELEFT", E = "STRAFERIGHT", R = "RELOAD",
            ["CTRL-R"] = "ORIGINAL_CTRL_R", ["ALT-T"] = "ORIGINAL_ALT_T" },
        writes = {}, failures = {}, event = nil
    };
    local api = {
        getBinding = function(key) return state.bindings[key] or ""; end,
        setBinding = function(key, action)
            table.insert(state.writes, { key = key, action = action });
            if ((state.failures[key] or 0) > 0) then
                state.failures[key] = state.failures[key] - 1;
                return nil;
            end
            state.bindings[key] = action;
            if (state.event) then state.event(); end
            return 1;
        end
    };
    local db = database or {};
    local manager = Hotkeys.NewManager(api, db);
    return state, manager, db;
end

check(Hotkeys.Normalize("q") == "Q", "letter binding is canonical uppercase");
check(Hotkeys.Normalize(" shift-ctrl-alt-r ") == "ALT-CTRL-SHIFT-R",
    "modifiers use the engine's canonical ALT CTRL SHIFT order");
check(Hotkeys.Normalize("CTRL-LEFTBRACKET") == "CTRL-[", "punctuation aliases normalize after modifiers");
check(Hotkeys.Normalize("F12") == "F12", "function keys are accepted");
check(Hotkeys.Normalize("NUMPAD4") == "NUMPAD4", "numpad keys are accepted");
check(Hotkeys.Normalize("MOUSEWHEELUP") == "MOUSEWHEELUP", "mouse wheel binding is accepted");
check(Hotkeys.Normalize("BUTTON5") == "BUTTON5", "extra mouse button binding is accepted");
check(Hotkeys.Normalize("") == "" and Hotkeys.Normalize("  ") == "", "empty binding disables a direction");
check(Hotkeys.Normalize(nil) == nil and Hotkeys.Normalize(7) == nil, "non-string saved bindings are invalid");
check(Hotkeys.Normalize("CTRL") == nil and Hotkeys.Normalize("SHIFT-ALT") == nil,
    "modifier-only input is not a binding");
check(Hotkeys.Normalize("UNKNOWN") == nil and Hotkeys.Normalize("F25") == nil,
    "unsupported key names are rejected");

local steps = { 25, 50, 100, 200, 300, 500, 1000 };
local index = 1;
while (index <= table.getn(steps)) do
    local lower = steps[math.max(1, index - 1)];
    local upper = steps[math.min(table.getn(steps), index + 1)];
    check(Hotkeys.NextSpeed(steps[index], -1) == lower, "slower preset step " .. steps[index]);
    check(Hotkeys.NextSpeed(steps[index], 1) == upper, "faster preset step " .. steps[index]);
    index = index + 1;
end
check(Hotkeys.NextSpeed(150, -1) == 100 and Hotkeys.NextSpeed(150, 1) == 200,
    "custom x1.5 moves to the adjacent lower or upper preset");
check(Hotkeys.NextSpeed(26, -1) == 25 and Hotkeys.NextSpeed(999, 1) == 1000,
    "custom values near limits step to the corresponding boundary");
check(Hotkeys.NextSpeed(25, -1) == 25 and Hotkeys.NextSpeed(1000, 1) == 1000,
    "minimum and maximum clamp without cycling to the other end");

local state, manager, db = fixture();
local originals = copy(state.bindings);
check(manager:Available(), "complete binding API is available");
check(manager:GetKey("down") == "Q" and manager:GetKey("up") == "E", "default Q and E are initialized");
check(db.hotkeyDown == "Q" and db.hotkeyUp == "E", "default keys persist in addon settings");
check(table.getn(state.writes) == 0 and same(state.bindings, originals),
    "constructing a manager does not change game bindings before entering the world");
check(manager:Apply(), "entering the world applies bindings");
check(state.bindings.Q == "AZSG_SLOWER" and state.bindings.E == "AZSG_FASTER", "defaults override only the live key table");
check(manager:Release(), "leaving the world releases bindings");
check(same(state.bindings, originals), "release restores the complete original key table");

check(manager:SetKey("down", "ctrl-r"), "inactive customization succeeds");
check(manager:GetKey("down") == "CTRL-R" and db.hotkeyDown == "CTRL-R", "custom key is canonical and saved");
check(same(state.bindings, originals), "inactive customization leaves the game's bindings alone");
check(manager:Apply(), "custom bindings apply when entering the world");
check(state.bindings.Q == "STRAFELEFT" and state.bindings["CTRL-R"] == "AZSG_SLOWER",
    "custom down key leaves Q with its original game action");
check(manager:SetKey("down", "R"), "active rebinding succeeds");
check(state.bindings["CTRL-R"] == "ORIGINAL_CTRL_R" and state.bindings.R == "AZSG_SLOWER",
    "active rebind restores the previous key before using the new one");
check(manager:Release() and same(state.bindings, originals), "release restores keys after several rebindings");
check(manager:SetKey("down", "ALT-Y") and manager:Apply(), "previously unbound keys can be assigned");
check(state.bindings["ALT-Y"] == "AZSG_SLOWER", "new binding takes the requested action");
check(manager:Release() and state.bindings["ALT-Y"] == nil and same(state.bindings, originals),
    "release removes a temporary key that was originally unbound");

state, manager, db = fixture();
check(manager:Apply(), "duplicate fixture applies");
local before = copy(state.bindings);
local ok, reason = manager:SetKey("down", "e");
check(not ok and reason == "duplicate", "same nonempty key cannot control both directions");
check(db.hotkeyDown == "Q" and db.hotkeyUp == "E" and same(state.bindings, before),
    "duplicate rejection is transactional");
ok, reason = manager:SetKey("down", "UNKNOWN");
check(not ok and reason == "invalid" and same(state.bindings, before), "unsupported customization leaves live bindings intact");
check(manager:SetKey("down", ""), "a hotkey can be disabled");
check(state.bindings.Q == "STRAFELEFT" and db.hotkeyDown == "" and manager:GetKey("down") == "",
    "disabling restores the original game action and persists the empty binding");
check(manager:SetKey("up", ""), "both directions can be disabled independently");
check(state.bindings.E == "STRAFERIGHT", "disabling the second direction restores its original action");
check(manager:Reset(), "reset restores Q and E");
check(db.hotkeyDown == "Q" and db.hotkeyUp == "E" and state.bindings.Q == "AZSG_SLOWER"
    and state.bindings.E == "AZSG_FASTER", "reset updates settings and active bindings together");
check(manager:Release(), "reset fixture releases");

state, manager, db = fixture();
check(manager:Apply(), "external ownership fixture applies");
state.bindings.Q = "OTHER_ADDON_ACTION";
manager:Apply();
check(state.bindings.Q == "OTHER_ADDON_ACTION", "routine apply never reclaims a binding changed by another addon");
check(manager:Release(), "external ownership fixture releases");
check(state.bindings.Q == "OTHER_ADDON_ACTION" and state.bindings.E == "STRAFERIGHT",
    "release preserves newer external ownership while restoring keys still owned by this addon");

state, manager, db = fixture();
originals = copy(state.bindings);
state.failures.E = 1;
ok, reason = manager:Apply();
check(not ok and reason == "set_failed", "failed game SetBinding is reported");
check(same(state.bindings, originals), "a partial first apply rolls back earlier successful key changes");
check(manager:Apply(), "a transient apply failure can be retried");
before = copy(state.bindings);
state.failures["CTRL-R"] = 1;
ok, reason = manager:SetKey("down", "CTRL-R");
check(not ok and reason == "set_failed", "failed rebind is reported");
check(db.hotkeyDown == "Q" and same(state.bindings, before), "failed rebind restores both settings and live bindings");
check(manager:SetKey("down", "CTRL-R") and manager:SetKey("up", "ALT-T"), "custom pair is installed for reset rollback");
before = copy(state.bindings);
state.failures.E = 1;
ok, reason = manager:Reset();
check(not ok and reason == "set_failed", "failed reset is reported");
check(db.hotkeyDown == "CTRL-R" and db.hotkeyUp == "ALT-T" and same(state.bindings, before),
    "failed reset restores both custom keys atomically");
check(manager:Release() and same(state.bindings, originals), "failure recovery does not lose original game actions");

state, manager, db = fixture();
originals = copy(state.bindings);
-- Real SetBinding fires UPDATE_BINDINGS synchronously. A listener must not
-- recursively install the hotkeys while a transaction or save is in progress.
state.event = function() manager:Apply(); end;
check(manager:Apply(), "synchronous binding events do not recurse during apply");
before = copy(state.bindings);
local saved = nil;
local first, second, third = manager:WithBaseBindings(function(scope, identifier)
    check(scope == "account" and identifier == 2, "save wrapper forwards callback arguments");
    saved = copy(state.bindings);
    manager:Apply();
    check(same(state.bindings, originals), "binding events cannot reinstall temporary hotkeys during save");
    local changed, changeReason = manager:SetKey("down", "R");
    check(not changed and changeReason == "busy" and db.hotkeyDown == "Q",
        "reentrant settings edits cannot alter addon keys midway through saving");
    return "saved", nil, 7;
end, "account", 2);
check(first == "saved" and second == nil and third == 7, "save wrapper forwards multiple results including nil holes");
check(same(saved, originals), "saving clones the user's original bindings rather than temporary Q and E overrides");
check(same(state.bindings, before), "temporary live hotkeys are reapplied immediately after save");
local callbackOk, callbackError = pcall(function()
    manager:WithBaseBindings(function()
        check(same(state.bindings, originals), "throwing save still starts with original bindings");
        error("intentional save failure");
    end);
end);
check(not callbackOk and string.find(tostring(callbackError), "intentional save failure", 1, true),
    "original save errors remain visible to the caller");
check(same(state.bindings, before), "hotkeys are restored even when the original save throws");
state.event = nil;
check(manager:Release(), "save wrapper fixture releases");
manager:WithBaseBindings(function()
    check(same(state.bindings, originals), "inactive save uses original bindings directly");
end);
check(same(state.bindings, originals), "saving while inactive does not activate hotkeys");

state, manager, db = fixture();
check(manager:Apply(), "save ownership change fixture applies");
manager:WithBaseBindings(function()
    state.bindings.Q = "USER_CHANGED_Q";
end);
check(state.bindings.Q == "USER_CHANGED_Q" and state.bindings.E == "AZSG_FASTER",
    "a new binding made while the base table is exposed is preserved during reapply");
check(manager:Release() and state.bindings.Q == "USER_CHANGED_Q" and state.bindings.E == "STRAFERIGHT",
    "release also preserves user bindings changed during save");

state, manager, db = fixture({ hotkeyDown = 11, hotkeyUp = "UNKNOWN" });
check(db.hotkeyDown == "Q" and db.hotkeyUp == "E", "corrupt saved bindings recover to defaults");
state, manager, db = fixture({ hotkeyDown = "ctrl-r", hotkeyUp = "CTRL-R" });
check(manager:GetKey("down") ~= manager:GetKey("up"), "duplicate saved assignments are repaired");
state, manager, db = fixture({ hotkeyDown = "", hotkeyUp = "" });
check(db.hotkeyDown == "" and db.hotkeyUp == "", "explicit disabled settings survive load");

local missing = Hotkeys.NewManager({}, {});
check(not missing:Available(), "missing binding API is recognized");
ok, reason = missing:Apply();
check(not ok and reason == "unavailable", "missing API fails without throwing");
check(missing:Release(), "missing API has no live bindings to release");
local called = false;
missing:WithBaseBindings(function() called = true; end);
check(called, "missing binding API never blocks the original game save");

print("Hotkey checks passed: " .. checks);

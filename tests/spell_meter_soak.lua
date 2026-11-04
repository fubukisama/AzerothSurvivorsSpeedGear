-- Remote Lua 5.0 regression only. Supply the independently downloaded/pinned
-- AZSSpellMeter 1.32 source as arg[1]. No game assets or saves are loaded.
-- This isolates the real collapsed-bubble -> refresh -> refreshWindow path.
-- Geometry mutation counts are an operation oracle, not GPU/FPS measurements.
assert(arg and arg[1], "usage: lua50 tests/spell_meter_soak.lua /pinned/AZSSpellMeter.lua");
assert(debug and debug.getupvalue and debug.setupvalue, "remote stock Lua debug API required");
local frames = {};
local hiddenWrites, bubbleWrites, popupWrites, fullRefreshes = 0, 0, 0, 0;
local clock = 1000;
local nativeTotal = 0;
local function widget(name, owner)
    local self = { name = name, shown = true, scripts = {}, width = 394, height = 241, text = "", owner = owner };
    local function mutation()
        if (self.owner == "main" and not frames.main.shown) then hiddenWrites = hiddenWrites + 1; end
        if (self.owner == "bubble") then bubbleWrites = bubbleWrites + 1; end
        if (self.owner == "popup") then popupWrites = popupWrites + 1; end
    end
    function self:RegisterEvent() end
    function self:SetScript(eventName, callback) self.scripts[eventName] = callback; end
    function self:IsShown() return self.shown; end
    function self:Hide() mutation(); self.shown = false; end
    function self:Show() mutation(); self.shown = true; end
    function self:SetText(value) mutation(); self.text = value; end
    function self:GetText() return self.text; end
    function self:GetWidth() return self.width; end
    function self:GetHeight() return self.height; end
    function self:SetWidth(value) mutation(); self.width = value; end
    function self:SetHeight(value) mutation(); self.height = value; end
    function self:GetStringWidth() return string.len(self.text or "") * 6; end
    local _, name;
    for _, name in ipairs({ "ClearAllPoints", "SetPoint", "SetTextColor", "SetTexture", "SetTexCoord", "SetVertexColor" }) do
        self[name] = mutation;
    end
    return self;
end
UIParent = widget("UIParent");
SlashCmdList = {};
CreateFrame = function(kind, name) local frame = widget(name); frames[name] = frame; return frame; end;
GetTime = function() return clock; end;
AZS_GetRunTime = function() return clock - 1000; end;
AZS_GetMeter = function() return {}, nativeTotal, 0; end;
AZS_GetHealing = function() return {}, 4321, 0; end;
AZS_GetHealing = AZS_GetMeter;
UnitName = function() return "FixturePlayer"; end;
AZSSpellMeterDB = { mini = true, shown = true, view = "damage", viewChosen = true };
dofile(arg[1]);

local function upvalue(fn, name, value, replace)
    local index = 1;
    while (true) do
        local found, current = debug.getupvalue(fn, index);
        if (not found) then error("source seam missing upvalue: " .. name); end
        if (found == name) then
            if (replace) then debug.setupvalue(fn, index, value); end
            return current;
        end
        index = index + 1;
    end
end
local driver = assert(frames.AZSSpellMeterDriver, "production driver exists");
local refresh = upvalue(driver.scripts.OnUpdate, "refresh");
local createUI = upvalue(driver.scripts.OnEvent, "createUI");
local buildMainList = upvalue(createUI, "buildMainList");
local onBubbleUpdate = upvalue(buildMainList, "onBubbleUpdate");
local onMainUpdate = upvalue(buildMainList, "onMainUpdate");
local main = widget("main", "main"); frames.main = main; main.shown = false;
main.totalText = widget("total", "main");
main.dpsText = widget("dps", "main");
main.countText = widget("kills", "main");
main.bubbleText = widget("bubbleText", "bubble");
local rows = {};
for index = 1, 25 do rows[index] = widget("row" .. index, "main"); end
main.rows = rows;
local bubble = widget("bubble", "bubble"); bubble.parked = true; bubble.moving = false;
upvalue(refresh, "frame", main, true);
upvalue(onBubbleUpdate, "bubble", bubble, true);
local meterState = { spells = {}, total = 0, elapsed = 0, kills = 0 };
upvalue(refresh, "state", meterState, true);
-- Remove unrelated game-lifecycle queries. The expensive window function and
-- real bubble timing/dispatch remain production closures, not reimplementations.
upvalue(refresh, "watchRun", function() end, true);
upvalue(refresh, "noteDeath", function() end, true);
upvalue(refresh, "hideStockMeter", function() end, true);
local originalWindow = upvalue(refresh, "refreshWindow");
upvalue(refresh, "refreshWindow", function(win)
    fullRefreshes = fullRefreshes + 1;
    return originalWindow(win);
end, true);

local failures = {};
local function check(okay, description)
    if (not okay) then table.insert(failures, description); print("FAIL: " .. description); end
end
local function run(realSeconds, elapsedRate)
    local count = math.floor(realSeconds * 60);
    for index = 1, count do
        arg1 = elapsedRate / 60;
        clock = clock + arg1;
        onBubbleUpdate();
    end
end
local before, calls = hiddenWrites, fullRefreshes;
run(20, 1);
print(string.format("MINI early_1x hidden_mutations=%d full_window_refreshes=%d bubble_mutations=%d",
    hiddenWrites - before, fullRefreshes - calls, bubbleWrites));
check(hiddenWrites == before, "collapsed bubble must not mutate the hidden main table at 1x");
before, calls = hiddenWrites, fullRefreshes;
run(20, 3);
print(string.format("MINI accelerated hidden_mutations=%d full_window_refreshes=%d",
    hiddenWrites - before, fullRefreshes - calls));
check(hiddenWrites == before, "collapsed bubble must not mutate the hidden main table under accelerated updates");
before, calls = hiddenWrites, fullRefreshes;
run(20, 1);
print(string.format("MINI returned_1x hidden_mutations=%d full_window_refreshes=%d",
    hiddenWrites - before, fullRefreshes - calls));
check(hiddenWrites == before, "returning to 1x must not retain collapsed-table refresh work");
-- Hostile deaths bypass the periodic 0.2s throttle in the production handler,
-- even if the creature has no credited player spell in lastBlow.
before, calls = hiddenWrites, fullRefreshes;
event, arg1 = "CHAT_MSG_COMBAT_HOSTILE_DEATH", "Fixture creature dies.";
for index = 1, 1000 do driver.scripts.OnEvent(); end
print(string.format("MINI death_burst events=1000 hidden_mutations=%d full_window_refreshes=%d",
    hiddenWrites - before, fullRefreshes - calls));
check(hiddenWrites == before, "collapsed bubble must not rebuild hidden rows for each hostile-death event");
nativeTotal = 1234; run(0.5, 1);
check(main.bubbleText.text == "1234", "collapsed bubble still shows the exact native aggregate");
nativeTotal = 5678; run(0.5, 1);
check(main.bubbleText.text == "5678" and bubble.width == 40,
    "collapsed aggregate and its caption width keep updating after the repair");
main.shown = true; bubble.shown = false; AZSSpellMeterDB.mini = false;
calls = fullRefreshes;
arg1 = 0.21; clock = clock + arg1; onMainUpdate();
check(fullRefreshes > calls, "visible main window still refreshes through its original periodic updater");
local popup = widget("popup", "popup"); popup.fixed = "healing";
popup.totalText, popup.dpsText, popup.countText = widget("pop-total", "popup"), widget("pop-rate", "popup"), widget("pop-kills", "popup");
popup.rows = {};
for index = 1, 25 do popup.rows[index] = widget("pop-row" .. index, "popup"); end
local popped = upvalue(refresh, "popped"); popped.healing = popup;
main.shown = false; bubble.shown = true; AZSSpellMeterDB.mini = true;
local beforePopup = popupWrites; before = hiddenWrites;
run(0.5, 1);
check(popupWrites > beforePopup and popup.totalText.text == "4321", "visible detached window still refreshes its own view while the main table is collapsed");
check(hiddenWrites == before, "refreshing a visible detached window does not lay out the hidden main table");
popped.healing = nil;
-- Positive data-integrity control: kill attribution is immediate even while a
-- different view is selected. The existing periodic path supplies the repaint.
AZSSpellMeterDB.view = "healing";
event, arg1 = "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Fixture Bolt hits Fixture creature for 5 Physical.";
driver.scripts.OnEvent();
local priorKills = meterState.kills;
calls = fullRefreshes;
event, arg1 = "CHAT_MSG_COMBAT_HOSTILE_DEATH", "Fixture creature dies.";
driver.scripts.OnEvent();
check(meterState.kills == priorKills + 1 and meterState.spells["Fixture Bolt"].kills == 1,
    "kill credit is applied synchronously before any periodic repaint");
check(fullRefreshes == calls, "death credit defers repaint to the existing periodic updater");
print("SEAM LIMIT: empty native meter isolates hidden GUI writes; this is not a whole-game FPS, memory-leak or restart-cause proof.");
assert(table.getn(failures) == 0, table.concat(failures, "; "));

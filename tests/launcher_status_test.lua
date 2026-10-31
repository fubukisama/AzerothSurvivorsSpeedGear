-- Production UI regression, executed only by remote Lua 5.0 CI.
-- Clocks and true simulation rates are independent of requested speeds.
local checks = 0;
local function check(value, message)
    checks = checks + 1;
    if (not value) then error(message); end
end

local frames, cvars = {}, {};
local physical, clientClock, gameRun = 0.10, 1000, 100;
local epoch = 1800000000;
local phase = "playing";
local lastPublication = physical;

local function stub(name)
    local frame = { shown = true, scripts = {}, fonts = {} };
    function frame:SetWidth(value) self.width = value; end
    function frame:SetHeight(value) self.height = value; end
    function frame:SetPoint() end
    function frame:GetPoint() return "CENTER", UIParent, "CENTER", 0, 0; end
    function frame:ClearAllPoints() end
    function frame:SetFrameStrata() end
    function frame:SetMovable() end
    function frame:SetClampedToScreen() end
    function frame:EnableMouse() end
    function frame:EnableKeyboard() end
    function frame:RegisterForDrag() end
    function frame:SetBackdrop() end
    function frame:SetBackdropColor() end
    function frame:SetJustifyH() end
    function frame:SetText(value) self.text = value; end
    function frame:GetText() return self.text; end
    function frame:SetScript(name, callback) self.scripts[name] = callback; end
    function frame:RegisterEvent() end
    function frame:StartMoving() end
    function frame:StopMovingOrSizing() end
    function frame:SetAutoFocus() end
    function frame:SetMaxLetters() end
    function frame:ClearFocus() end
    function frame:Show() self.shown = true; end
    function frame:Hide()
        local wasShown = self.shown; self.shown = false;
        if (wasShown and self.scripts.OnHide) then
            local oldThis = this; this = self; self.scripts.OnHide(); this = oldThis;
        end
    end
    function frame:IsShown() return self.shown; end
    function frame:CreateFontString()
        local font = stub(); table.insert(self.fonts, font); return font;
    end
    if (name) then frames[name] = frame; end
    return frame;
end

UIParent = stub("UIParent");
GameTooltip = stub("GameTooltip");
function GameTooltip:SetOwner(owner) self.owner = owner; end
GameTooltip:Hide();
CreateFrame = function(kind, name) return stub(name); end;
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
time = function() return epoch + math.floor(physical + 1e-9); end;
SlashCmdList = {};
AZSSpeedGearNativeLocale = "zh";
AZSSpeedGearDB = { show = false };
AZSSpeedGear_TEST = nil;
dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
dofile("AddOns/AZSSpeedGear/AZSSpeedGear.lua");

local driver = AZSSpeedGear.driver;
local function fire(name, value)
    event, arg1, this = name, value, driver;
    driver.scripts.OnEvent();
end
local function update()
    this = driver; driver.scripts.OnUpdate();
end
local function advance(seconds, actualRate, clientRate, publicationOffset)
    local count = math.floor(seconds * 60 + 0.5);
    local frame = 1;
    while (frame <= count) do
        physical = physical + 1 / 60;
        gameRun = gameRun + actualRate / 60;
        clientClock = clientClock + clientRate / 60;
        -- Five raw server publications per physical second, deliberately
        -- staggered against integer wall-clock boundaries when offset = .01.
        local published = publicationOffset + math.floor((physical - publicationOffset + 1e-9) / 0.2) * 0.2;
        if (published > lastPublication + 1e-9) then
            -- Floating-point rounding at an exact period boundary must never
            -- manufacture a publication timestamp in the client's future.
            local age = math.max(0, physical - published);
            AZS_RUN.t = gameRun - actualRate * age;
            AZS_RUN_UPDATED = clientClock - clientRate * age;
            lastPublication = published;
        end
        update(); frame = frame + 1;
    end
end
local function request(value) SlashCmdList.AZSSPEEDGEAR(value); end
local function caption() return AZSSpeedGearI18n.Text("launcher"); end
local function text() return AZSSpeedGear.launcher.text; end
local function target(value)
    if (AZSSpeedGearI18n.code == "ja") then return "目標 ×" .. value; end
    return "目标 ×" .. value;
end
local function pending(value, message)
    check(text() == target(value) .. " …", message);
end
local function hover(script)
    local oldThis = this; this = AZSSpeedGear.launcher;
    AZSSpeedGear.launcher.scripts[script](); this = oldThis;
end
local function tooltipHas(value)
    return GameTooltip.shown and string.find(GameTooltip.text or "", value, 1, true) ~= nil;
end

fire("ADDON_LOADED", "AZSSpeedGear");
fire("PLAYER_ENTERING_WORLD");
request("2");
check(AZSSpeedGear.controller.confirmedSpeed100 == nil and AZSSpeedGear.controller.measured == nil,
    "a fresh request has no measurement or backend receipt");
pending("2", "pending x2 launcher must retain its numeric request instead of only an ellipsis");
check(not AZSSpeedGear.panel.shown, "numeric launcher status works while the panel is hidden");
hover("OnEnter");
check(GameTooltip.owner == AZSSpeedGear.launcher
    and tooltipHas(string.format(AZSSpeedGearI18n.Text("target_wait"), "2"))
    and not tooltipHas(string.format(AZSSpeedGearI18n.Text("target_measured"), "2")),
    "hovering a fresh target explains that its request has not been measured");

advance(36, 2, 2, 0.01);
local controller = AZSSpeedGear.controller;
check(controller.active and controller.speed100 == 200 and not controller.frameGuardTripped,
    "independent stable 2x fixture remains active at high frame rate");
check(controller.measured and math.abs(controller.measured - 2) < 0.05,
    "staggered raw publications supply real positive progress");
if (controller.confirmedSpeed100 == 200) then
    check(text() == caption() .. " ×2", "confirmed progress removes only the pending marker");
else
    pending("2", "long conservative measurement must not hide the numeric request");
end
check(tooltipHas(string.format(AZSSpeedGearI18n.Text("measured"), controller.measured)),
    "hovered tooltip follows independently observed progress without equating it to a native receipt");

request("2");
advance(8, 1, 1, 0.01);
check(controller.measurementMismatch and controller.confirmedSpeed100 == nil,
    "independent actual 1x against requested 2x is a definite mismatch");
check(text() == target("2") .. " !", "mismatch retains the target number with an explicit warning marker");
check(tooltipHas(AZSSpeedGearI18n.Text("below_target"))
    and tooltipHas(string.format(AZSSpeedGearI18n.Text("measured"), controller.measured)),
    "a definite mismatch explains the warning and the independent measured rate");
request("5");
pending("5", "a new request immediately replaces the previous target and warning");
check(tooltipHas(string.format(AZSSpeedGearI18n.Text("target_wait"), "5"))
    and not tooltipHas(AZSSpeedGearI18n.Text("below_target")),
    "changing the target while hovered refreshes its pending description and removes the old mismatch");

-- Three real over-budget client-frame intervals trigger the existing guard.
local index = 1;
while (index <= 3) do
    physical = physical + 0.2; gameRun = gameRun + 0.2; clientClock = clientClock + 0.5;
    AZS_RUN.t = gameRun; AZS_RUN_UPDATED = clientClock; lastPublication = physical;
    update(); index = index + 1;
end
check(controller.frameGuardTripped and controller.speed100 == 100 and controller.desiredSpeed100 == 100,
    "real frame guard restores both current and desired request to 1x");
pending("1", "guard fallback must replace a stale x5 number with pending x1");
check(tooltipHas(AZSSpeedGearI18n.Text("frame_guard"))
    and tooltipHas(string.format(AZSSpeedGearI18n.Text("target_wait"), "1")),
    "guard fallback explains the automatic restore and its unconfirmed 1x request");

phase = "paused"; update();
check(not controller.active and text() == caption(), "pause clears the previous active numeric status");
check(tooltipHas(AZSSpeedGearI18n.Text("inactive")), "paused tooltip reports inactive status");
phase = "ready"; update();
check(not controller.active and text() == caption(), "ready state does not retain a previous speed claim");
phase = "playing"; update();
request("2");
AZSSpeedGearNativeLocale = "ja";
physical = physical + 1;
update();
pending("2", "pending numeric target follows a game-language change");
check(tooltipHas(string.format(AZSSpeedGearI18n.Text("target_wait"), "2")),
    "a hovered pending explanation follows the game-language change");

-- Aligned, independently advanced raw publications can still reach the
-- unadorned success caption through the actual measurement state machine.
request("2");
advance(8, 2, 2, 0);
check(controller.confirmedSpeed100 == 200 and text() == caption() .. " ×2",
    "bounded confirmed measurements retain the unadorned numeric suffix");
check(tooltipHas(string.format(AZSSpeedGearI18n.Text("target_measured"), "2")),
    "only measured confirmation changes the hover explanation to confirmed");
request("0.5"); pending("0.5", "fractional pending values use compact decimal text");
advance(8, 0.5, 0.5, 0);
check(controller.confirmedSpeed100 == 50 and text() == caption() .. " ×0.5",
    "fractional confirmed measurements remove the pending marker");
hover("OnLeave");
check(not GameTooltip.shown and not AZSSpeedGear.launcher.speedGearHovered,
    "leaving the launcher hides the hover explanation");
hover("OnEnter");
check(GameTooltip.shown, "hover explanation can reopen before world exit");
fire("PLAYER_LEAVING_WORLD");
check(not AZSSpeedGear.launcher.shown and text() == caption(), "leaving the world removes numeric status and hides the launcher");
check(not GameTooltip.shown and not AZSSpeedGear.launcher.speedGearHovered,
    "world exit hides the launcher tooltip and clears hover state");
print("Launcher status regression: " .. checks .. " checks passed.");

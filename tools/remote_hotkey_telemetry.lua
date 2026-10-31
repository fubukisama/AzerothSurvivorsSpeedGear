-- Isolated, remote real-game observations. Not included in the release package.
-- Only physical input invokes the production hotkey function. This wrapper
-- records its synchronous result before an independent safety guard can reset it.
local frame = CreateFrame("Frame");
local cvar = "AZSGHotkeyTelemetry";
local seq, frames, actions = 0, 0, 0;
local direction, before, after, accepted = 0, 100, 100, 0;
local instance = math.floor(time() * 1000 + math.random(1, 999));
local initialized, wrapped = false, false;
local playingOptionAttempts = 0;
local captureWrapper;
local captureEvents = 0;
local captureKey, captureCtrl, captureShift, captureAlt = "none", "none", "none", "none";
local emit;
local function safe(fn)
    if (type(fn) ~= "function") then return nil; end
    local ok, result = pcall(fn); if (ok) then return result; end
end
local function shown(widget)
    if (not widget or type(widget.IsShown) ~= "function") then return 0; end
    local ok, value = pcall(widget.IsShown, widget);
    return ok and (value == true or value == 1) and 1 or 0;
end
local function token(value)
    if (type(value) ~= "string" or value == "") then return "none"; end
    return string.sub(string.gsub(value, "[^A-Za-z0-9_-]", "_"), 1, 64);
end
local function rawModifier(fn)
    if (type(fn) ~= "function") then return "missing"; end
    local ok, value = pcall(fn);
    if (not ok) then return "error"; end
    return token(type(value) .. "_" .. tostring(value));
end
local function binding(key)
    local ok, value = pcall(GetBindingAction, key);
    return ok and token(value) or "unavailable";
end
local function center(widget)
    if (not widget or type(widget.GetCenter) ~= "function" or type(widget.GetEffectiveScale) ~= "function") then return "-1|-1"; end
    local x, y = widget:GetCenter();
    local scale = widget:GetEffectiveScale();
    local rootScale = UIParent:GetEffectiveScale();
    local width, height = GetScreenWidth() * rootScale, GetScreenHeight() * rootScale;
    if (type(x) ~= "number" or type(y) ~= "number" or width <= 0 or height <= 0) then return "-1|-1"; end
    return string.format("%.6f|%.6f", x * scale / width, 1 - y * scale / height);
end
local function install()
    if (not initialized and type(RegisterCVar) == "function") then
        RegisterCVar(cvar, ""); initialized = true;
        if (type(AZS_SetStoringLevels) == "function") then pcall(AZS_SetStoringLevels, true); end
    end
    -- The character/server may not exist when the observer first loads. Retry
    -- this ordinary disposable game option only on the first playing frames.
    if (playingOptionAttempts < 3 and safe(AZS_GetPhase) == "playing" and type(AZS_SetStoringLevels) == "function") then
        playingOptionAttempts = playingOptionAttempts + 1;
        pcall(AZS_SetStoringLevels, true);
    end
    if (not wrapped and AZSSpeedGear and type(AZSSpeedGear.StepHotkey) == "function") then
        local original = AZSSpeedGear.StepHotkey;
        AZSSpeedGear.StepHotkey = function(value)
            actions = actions + 1; direction = value;
            before = AZSSpeedGear.controller.desiredSpeed100;
            local result = original(value);
            after = AZSSpeedGear.controller.desiredSpeed100;
            accepted = result and 1 or 0;
            emit();
            return result;
        end;
        wrapped = true;
    end
    -- Observe only the production recorder that is already active. Never add a
    -- keyboard listener outside capture or replace its modifier calculation.
    local panel = AZSSpeedGear and AZSSpeedGear.panel;
    local original = panel and panel:GetScript("OnKeyDown");
    if (original and original ~= captureWrapper) then
        captureWrapper = function()
            captureEvents = captureEvents + 1;
            captureKey = token(arg1);
            captureCtrl = rawModifier(IsControlKeyDown);
            captureShift = rawModifier(IsShiftKeyDown);
            captureAlt = rawModifier(IsAltKeyDown);
            original();
            emit();
        end;
        panel:SetScript("OnKeyDown", captureWrapper);
    end
end
emit = function()
    if (not initialized or not AZSSpeedGear or not AZSSpeedGear.controller) then return; end
    local gear, db = AZSSpeedGear, AZSSpeedGearDB or {};
    local controller = gear.controller;
    seq = seq + 1;
    local capture = gear.panel and gear.panel:GetScript("OnKeyDown") and 1 or 0;
    local run = type(AZS_RUN) == "table" and AZS_RUN or {};
    local payload = "AZSGH1|" .. seq .. "|" .. string.format("%.0f", instance) .. "|" .. token(safe(AZS_GetPhase))
        .. "|" .. controller.desiredSpeed100 .. "|" .. controller.speed100 .. "|" .. (controller.frameGuardTripped and 1 or 0)
        .. "|" .. (controller.active and 1 or 0) .. "|" .. token(db.hotkeyDown) .. "|" .. token(db.hotkeyUp)
        .. "|" .. binding("Q") .. "|" .. binding("E") .. "|" .. binding("R") .. "|" .. binding("CTRL-T")
        .. "|" .. capture .. "|" .. shown(gear.panel) .. "|" .. actions .. "|" .. direction .. "|" .. before .. "|" .. after .. "|" .. accepted
        .. "|" .. frames .. "|" .. string.format("%.6f", type(run.t) == "number" and run.t or -1)
        .. "|" .. shown(ChatFrameEditBox) .. "|" .. shown(GameMenuFrame)
        .. "|" .. center(gear.launcher) .. "|" .. center(AZSSpeedGearHotkeyDown) .. "|" .. center(AZSSpeedGearHotkeyUp)
        .. "|" .. center(AZSSpeedGearClose) .. "|" .. center(AZSSpeedGearStop)
        .. "|" .. captureKey .. "|" .. captureCtrl .. "|" .. captureShift .. "|" .. captureAlt
        .. "|" .. rawModifier(IsControlKeyDown) .. "|" .. captureEvents;
    SetCVar(cvar, payload); ConsoleExec(cvar);
end;
frame:RegisterEvent("PLAYER_ENTERING_WORLD");
frame:SetScript("OnEvent", function() install(); emit(); end);
frame:SetScript("OnUpdate", function() frames = frames + 1; install(); emit(); end);

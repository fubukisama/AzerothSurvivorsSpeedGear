-- Isolated remote observation only. Never included in the release package.
local frame = CreateFrame("Frame");
local cvar = "AZSGLauncherTelemetry";
local seq, frames, actions = 0, 0, 0;
local direction, before, after, accepted = 0, 100, 100, 0;
local initialized, wrapped = false, false;
local storeReadyAttempted, storePlayingAttempts = false, 0;
local storeOptionAttempts, storeOptionPcallOk = 0, -1;
local instance = math.floor(time() * 1000 + math.random(1, 999));
local emit;
local function safe(fn)
    if (type(fn) ~= "function") then return nil; end
    local ok, result = pcall(fn); if (ok) then return result; end
end
local function number(value)
    if (type(value) ~= "number" or value ~= value or value < -1e10 or value > 1e10) then return -1; end
    return value;
end
local function shown(widget)
    if (not widget or type(widget.IsShown) ~= "function") then return 0; end
    local ok, value = pcall(widget.IsShown, widget);
    return ok and (value == true or value == 1) and 1 or 0;
end
local function textOf(widget)
    if (not widget or type(widget.GetText) ~= "function") then return ""; end
    local ok, value = pcall(widget.GetText, widget);
    return ok and type(value) == "string" and value or "";
end
local function hex(value)
    if (type(value) ~= "string" or string.len(value) > 256) then return "none"; end
    local result = "";
    local index = 1;
    while (index <= string.len(value)) do
        result = result .. string.format("%02X", string.byte(value, index));
        index = index + 1;
    end
    return result == "" and "none" or result;
end
local function speedText(value)
    return string.gsub(string.gsub(string.format("%.2f", value / 100), "0+$", ""), "%.$", "");
end
local function install()
    if (not initialized and type(RegisterCVar) == "function") then
        RegisterCVar(cvar, ""); initialized = true;
    end
    -- This ordinary game option is confined to the disposable test state.
    -- READY means the run/player exists, unlike early addon loading. A few
    -- playing-frame retries tolerate the game's asynchronous option handling.
    -- pcall success is an API-call observation, not a server acknowledgement.
    local phase = safe(AZS_GetPhase);
    if (type(AZS_SetStoringLevels) == "function" and
        ((phase == "ready" and not storeReadyAttempted) or
        (phase == "playing" and storePlayingAttempts < 3))) then
        if (phase == "ready") then storeReadyAttempted = true;
        else storePlayingAttempts = storePlayingAttempts + 1; end
        storeOptionAttempts = storeOptionAttempts + 1;
        local okay = pcall(AZS_SetStoringLevels, true);
        storeOptionPcallOk = okay and 1 or 0;
    end
    if (not wrapped and AZSSpeedGear and type(AZSSpeedGear.StepHotkey) == "function") then
        local original = AZSSpeedGear.StepHotkey;
        AZSSpeedGear.StepHotkey = function(value)
            actions = actions + 1; direction = value;
            before = AZSSpeedGear.controller.desiredSpeed100;
            local result = original(value);
            after = AZSSpeedGear.controller.desiredSpeed100;
            accepted = result and 1 or 0;
            -- Request rendering is synchronous: preserve the short-lived 2x
            -- caption even if the production frame guard soon restores 1x.
            emit();
            return result;
        end;
        wrapped = true;
    end
end
emit = function()
    if (not initialized or not AZSSpeedGear or not AZSSpeedGear.controller or not AZSSpeedGearI18n) then return; end
    local gear, i18n = AZSSpeedGear, AZSSpeedGearI18n;
    local controller = gear.controller;
    local actual = textOf(gear.launcher);
    local expected, kind = i18n.Text("launcher"), "inactive";
    if (controller.active) then
        local speed = speedText(controller.speed100);
        if (number(controller.measured) > 0 and controller.confirmedSpeed100 == controller.speed100) then
            expected = expected .. " ×" .. speed; kind = "confirmed";
        else
            expected = string.format(i18n.Text("launcher_target"), speed);
            if (controller.measurementMismatch) then expected = expected .. " !"; kind = "mismatch";
            else expected = expected .. " …"; kind = "pending"; end
        end
    end
    local run = type(AZS_RUN) == "table" and AZS_RUN or {};
    seq = seq + 1;
    local phase = safe(AZS_GetPhase) or "unknown";
    if (not string.find(phase, "^[a-z]+$")) then phase = "unknown"; end
    local payload = "AZSGL1|" .. seq .. "|" .. string.format("%.0f", instance) .. "|" .. phase
        .. "|" .. number(controller.speed100) .. "|" .. number(controller.desiredSpeed100)
        .. "|" .. (controller.active and 1 or 0) .. "|" .. (controller.frameGuardTripped and 1 or 0)
        .. "|" .. number(controller.confirmedSpeed100) .. "|" .. string.format("%.6f", number(controller.measured))
        .. "|" .. (controller.measurementMismatch and 1 or 0) .. "|" .. shown(gear.launcher)
        .. "|" .. hex(actual) .. "|" .. hex(expected) .. "|" .. actions .. "|" .. direction
        .. "|" .. before .. "|" .. after .. "|" .. accepted .. "|" .. frames
        .. "|" .. string.format("%.6f", number(run.t)) .. "|" .. shown(ChatFrameEditBox)
        .. "|" .. shown(GameMenuFrame) .. "|" .. (i18n.code or "unknown") .. "|" .. kind
        .. "|" .. string.format("%.0f", number(safe(time)))
        .. "|" .. string.format("%.6f", number(controller.measurementLower))
        .. "|" .. string.format("%.6f", number(controller.measurementUpper))
        .. "|" .. storeOptionAttempts .. "|" .. storeOptionPcallOk;
    SetCVar(cvar, payload); ConsoleExec(cvar);
end;
frame:RegisterEvent("PLAYER_ENTERING_WORLD");
frame:SetScript("OnEvent", function() install(); emit(); end);
frame:SetScript("OnUpdate", function() frames = frames + 1; install(); emit(); end);

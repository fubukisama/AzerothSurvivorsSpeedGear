-- Remote, disposable game acceptance only. Never shipped in the addon package.
-- Game APIs supply observations; the external runner owns the trusted clock.
local frame = CreateFrame("Frame");
local cvar = "AZSGAcceptanceTelemetry";
local sequence, runPackets, spellPackets, stops, hits, resets = 0, 0, 0, 0, 0, 0;
local firstPlaying, previousCd, previousSpell, previousStamp, lastTarget;
local pulse = 0;
local updates = 0;
local initialized = false;
local function number(value)
    if (type(value) ~= "number" or value ~= value or value < -1e10 or value > 1e10) then return -1; end
    return value;
end
local function fmt(value) return string.format("%.6f", number(value)); end
local function safe(fn)
    if (type(fn) ~= "function") then return nil; end
    local ok, value = pcall(fn);
    if (ok) then return value; end
    return nil;
end
local function shown(widget)
    if (not widget or type(widget.IsShown) ~= "function") then return -1; end
    local ok, value = pcall(widget.IsShown, widget);
    if (not ok) then return -1; end
    if (value == true or value == 1) then return 1; end
    return 0;
end
local instance = math.floor((safe(time) or 0) * 1000 + math.random(1, 999));
local function initialize()
    if (initialized) then return; end
    if (type(RegisterCVar) ~= "function" or type(ConsoleExec) ~= "function") then return; end
    RegisterCVar(cvar, "");
    -- This is a normal game option, confined to the runner's disposable state.
    if (type(AZS_SetStoringLevels) == "function") then pcall(AZS_SetStoringLevels, true); end
    if (type(SetMapToCurrentZone) == "function") then pcall(SetMapToCurrentZone); end
    initialized = true;
end
frame:RegisterEvent("PLAYER_ENTERING_WORLD");
frame:RegisterEvent("CHAT_MSG_ADDON");
frame:RegisterEvent("SPELLCAST_STOP");
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE");
frame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS");
frame:SetScript("OnEvent", function()
    if (event == "PLAYER_ENTERING_WORLD") then initialize();
    elseif (event == "CHAT_MSG_ADDON") then
        if (arg1 == "AZSRUN") then runPackets = runPackets + 1; end
        if (arg1 == "AZSSPELLS") then spellPackets = spellPackets + 1; end
    elseif (event == "SPELLCAST_STOP") then stops = stops + 1;
    else hits = hits + 1; end
end);
frame:SetScript("OnUpdate", function()
    updates = updates + 1;
    initialize();
    if (not initialized) then return; end
    pulse = pulse + (arg1 or 0);
    if (pulse < 0.2) then return; end
    pulse = 0;
    local now = safe(time);
    local phase = safe(AZS_GetPhase) or "unknown";
    if (phase == "playing" and not firstPlaying and type(now) == "number") then firstPlaying = now; end
    local elapsed = firstPlaying and now and now - firstPlaying or -1;
    local stage = 0;
    if (elapsed >= 5 and elapsed < 17) then stage = 1;
    elseif (elapsed >= 17 and elapsed < 23) then stage = 2;
    elseif (elapsed >= 23 and elapsed < 35) then stage = 3;
    elseif (elapsed >= 35 and elapsed < 41) then stage = 4;
    elseif (elapsed >= 41) then stage = 5; end
    local mode = AZSGAcceptanceMode == "hooked" and 1 or 0;
    local target = mode == 1 and (stage == 3 or stage == 4) and 200 or 100;
    local accepted = 0;
    if (mode == 1 and AZSSpeedGear and AZSSpeedGear.controller) then
        local controller = AZSSpeedGear.controller;
        if (target ~= lastTarget) then
            if (controller:RequestSpeed(target)) then lastTarget = target; end
        end
        if (lastTarget == target) then accepted = 1; end
    end
    local x, y = -1, -1;
    if (type(GetPlayerMapPosition) == "function") then
        local ok, a, b = pcall(GetPlayerMapPosition, "player");
        if (ok and not (a == 0 and b == 0)) then x, y = number(a), number(b); end
    end
    local spell, cd, cdmax = -1, -1, -1;
    if (type(AZS_SPELLS) == "table") then
        local i;
        for i = 1, table.getn(AZS_SPELLS) do
            local row = AZS_SPELLS[i];
            if (number(row.cdmax) > 0 and number(row.spell) > 0) then
                spell, cd, cdmax = number(row.spell), number(row.cd), number(row.cdmax);
                break;
            end
        end
    end
    if (AZS_SPELLS_UPDATED ~= previousStamp) then
        if (previousSpell == spell and previousCd and cd > previousCd + 0.15) then resets = resets + 1; end
        previousCd, previousSpell, previousStamp = cd, spell, AZS_SPELLS_UPDATED;
    end
    sequence = sequence + 1;
    local run = type(AZS_RUN) == "table" and AZS_RUN or {};
    local payload = "AZSGT1|" .. sequence .. "|" .. mode .. "|" .. target .. "|" .. stage .. "|" .. phase
        .. "|" .. fmt(run.t) .. "|" .. fmt(safe(GetTime)) .. "|" .. fmt(now)
        .. "|" .. fmt(x) .. "|" .. fmt(y) .. "|" .. fmt(safe(GetCurrentMapContinent))
        .. "|" .. fmt(safe(GetCurrentMapZone)) .. "|" .. fmt(spell) .. "|" .. fmt(cd) .. "|" .. fmt(cdmax)
        .. "|" .. resets .. "|" .. stops .. "|" .. hits .. "|" .. fmt(run.hp)
        .. "|" .. runPackets .. "|" .. spellPackets .. "|" .. accepted
        .. "|" .. shown(ChatFrameEditBox) .. "|" .. shown(GameMenuFrame)
        .. "|" .. string.format("%.0f", instance) .. "|" .. string.format("%.0f", updates);
    SetCVar(cvar, payload);
    ConsoleExec(cvar);
end);

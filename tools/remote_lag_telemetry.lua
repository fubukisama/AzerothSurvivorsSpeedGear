-- Disposable remote-client observation only; never included in a release.
-- The private harness must prepend AZSG_LAG_PROBE_REMOTE = true.
-- No damage is injected, and no game/speed/protection setting is changed.
-- Native call counters include wrapper overhead; trusted elapsed time belongs
-- to the external parent process, not GetTime/QPC or callback milliseconds.
if (AZSG_LAG_PROBE_REMOTE ~= true) then return; end

local frame = CreateFrame("Frame");
local cvar = "AZSGLagTelemetry";
local S = {
    seq = 0, frames = 0, updates = 0, widths = 0, fonts = 0, spawns = 0, misses = 0,
    activePeak = 0, hookedWidths = 0, hookedFonts = 0, unsupported = 0,
    preexisting = 0, observerReads = 0, requestedSizes = {}, actualSizes = {},
    requestedCount = 0, actualCount = 0, sizeOverflow = 0,
    labels = setmetatable({}, { __mode = "k" }),
};
local function increment(key, value)
    S[key] = math.min(2147483647, (S[key] or 0) + (value or 1));
end
local function safe(fn)
    if (type(fn) ~= "function") then return nil; end
    local okay, result = pcall(fn); if (okay) then return result; end
end
local function method(widget, name)
    if (widget and type(widget[name]) == "function") then
        increment("observerReads");
        local okay, result = pcall(widget[name], widget); if (okay) then return result; end
    end
end
local function number(value)
    if (type(value) ~= "number" or value ~= value or math.abs(value) > 1e15) then return -1; end
    return value;
end
local function visible(widget)
    local value = method(widget, "IsShown");
    return value == true or value == 1;
end
local function rememberSize(value, actual)
    if (type(value) ~= "number" or value ~= value or value < 1 or value > 256) then
        increment("sizeOverflow"); return;
    end
    -- Integer sizes are what the production integration requests. Preserve an
    -- observed fractional request as a separate key rather than silently round.
    local key = string.format("%.4f", value);
    local set, countKey = S.requestedSizes, "requestedCount";
    if (actual) then set, countKey = S.actualSizes, "actualCount"; end
    if (not set[key]) then
        if (S[countKey] >= 128) then increment("sizeOverflow"); return; end
        set[key] = true; increment(countKey);
    end
end
local function instrumentFont(font, existing)
    if (not font or S.labels[font]) then return; end
    S.labels[font] = true;
    if (existing) then increment("preexisting"); end
    if (type(font.GetStringWidth) == "function") then
        local original = font.GetStringWidth;
        local wrapper = function(self)
            increment("widths"); return original(self);
        end;
        local okay = pcall(function() font.GetStringWidth = wrapper; end);
        if (okay and font.GetStringWidth == wrapper) then increment("hookedWidths");
        else increment("unsupported"); end
    else increment("unsupported"); end
    if (type(font.SetFont) == "function") then
        local original = font.SetFont;
        local wrapper = function(self, ...)
            increment("fonts"); rememberSize(arg[2], false);
            return original(self, unpack(arg));
        end;
        local okay = pcall(function() font.SetFont = wrapper; end);
        if (okay and font.SetFont == wrapper) then increment("hookedFonts");
        else increment("unsupported"); end
    else increment("unsupported"); end
end
local function scanActive(gear, sample)
    local active = gear and gear.damageText and gear.damageText.active;
    if (type(active) ~= "table") then return -1; end
    local count = table.getn(active);
    S.activePeak = math.max(S.activePeak, count);
    -- The installed producer caps this at sixty. The observer remains bounded
    -- even if a different version breaks that contract.
    for index = 1, math.min(count, 256) do
        local item = active[index];
        if (type(item) == "table" and item.fs) then
            instrumentFont(item.fs, true);
            if (sample and type(item.fs.GetFont) == "function") then
                increment("observerReads");
                local okay, face, size = pcall(item.fs.GetFont, item.fs);
                if (okay) then rememberSize(size, true); end
            end
        end
    end
    return count;
end
local function install()
    if (not S.registered and type(RegisterCVar) == "function") then
        local okay = pcall(RegisterCVar, cvar, ""); S.registered = okay;
    end
    local gear = KeijinUI;
    if (type(gear) ~= "table" or not gear.damageText) then return; end
    S.loaded = 1;
    if (gear.version ~= "4.6.1-damageonly.1") then S.versionUnsupported = 1; return; end
    local damage = gear.damageText;
    local host = damage.drivers and damage.drivers[2];
    if (not host) then return; end
    if (not S.createHook and type(host.CreateFontString) == "function") then
        local original = host.CreateFontString;
        local wrapper = function(self, ...)
            local font = original(self, unpack(arg));
            instrumentFont(font, false); return font;
        end;
        local okay = pcall(function() host.CreateFontString = wrapper; end);
        if (okay and host.CreateFontString == wrapper) then S.createHook = 1;
        else S.createHook = -1; increment("unsupported"); end
    end
    if (not S.spawnHook and type(damage.Spawn) == "function") then
        local original = damage.Spawn;
        damage.Spawn = function(...)
            increment("spawns"); return original(unpack(arg));
        end;
        S.spawnHook = true;
    end
    if (not S.missHook and type(damage.SpawnMiss) == "function") then
        local original = damage.SpawnMiss;
        damage.SpawnMiss = function(...)
            increment("misses"); return original(unpack(arg));
        end;
        S.missHook = true;
    end
    if (not S.updateHook and type(host.GetScript) == "function" and type(host.SetScript) == "function") then
        local original = host:GetScript("OnUpdate");
        if (type(original) == "function") then
            local wrapper = function()
                increment("updates"); scanActive(gear, false); return original();
            end;
            local okay = pcall(host.SetScript, host, "OnUpdate", wrapper);
            if (okay and host:GetScript("OnUpdate") == wrapper) then S.updateHook = 1;
            else S.updateHook = -1; increment("unsupported"); end
        end
    end
    scanActive(gear, false);
end
local function frameCounts()
    if (type(EnumerateFrames) ~= "function") then return -1, -1, 0; end
    local previous, count, shown = nil, 0, 0;
    while (count < 8192) do
        increment("observerReads");
        local okay, nextFrame = pcall(EnumerateFrames, previous);
        if (not okay) then return -1, -1, 0; end
        if (not nextFrame) then return count, shown, 0; end
        if (nextFrame == previous) then return -1, -1, 1; end
        count = count + 1;
        if (visible(nextFrame)) then shown = shown + 1; end
        previous = nextFrame;
    end
    return -1, -1, 1; -- capped, not a claimed total of 8192
end
local function worldCounts()
    if (not WorldFrame or type(WorldFrame.GetChildren) ~= "function") then return -1, -1, -1, 0; end
    local known = method(WorldFrame, "GetNumChildren");
    if (type(known) == "number" and known > 2048) then return known, -1, -1, 1; end
    increment("observerReads");
    local okay, children = pcall(function() return { WorldFrame:GetChildren() }; end);
    if (not okay) then return -1, -1, -1, 0; end
    local count, shown, regions = table.getn(children), 0, 0;
    if (count > 2048) then return count, -1, -1, 1; end
    for _, child in ipairs(children) do
        if (visible(child)) then shown = shown + 1; end
        if (type(child.GetNumRegions) == "function") then
            local value = method(child, "GetNumRegions");
            if (type(value) == "number") then regions = regions + value; end
        elseif (type(child.GetRegions) == "function") then
            increment("observerReads");
            local found, list = pcall(function() return { child:GetRegions() }; end);
            if (found) then regions = regions + table.getn(list); end
        end
    end
    return count, shown, regions, 0;
end
local function emit(now)
    if (not S.registered or type(SetCVar) ~= "function" or type(ConsoleExec) ~= "function") then return; end
    local total, totalShown, enumCapped = frameCounts();
    local children, childShown, regions, worldCapped = worldCounts();
    local active = scanActive(KeijinUI, true);
    local memory, threshold = -1, -1;
    if (type(gcinfo) == "function") then
        local okay, value, limit = pcall(gcinfo);
        if (okay) then memory, threshold = number(value), number(limit); end
    end
    local phase = safe(AZS_GetPhase);
    if (type(phase) ~= "string" or not string.find(phase, "^[a-z_]+$") or string.len(phase) > 24) then phase = "unknown"; end
    local controller = AZSSpeedGear and AZSSpeedGear.controller or {};
    local meterRows, meterTotal = -1, -1;
    if (type(AZS_GetMeter) == "function") then
        local okay, rows, total = pcall(AZS_GetMeter);
        if (okay and type(rows) == "table") then meterRows = table.getn(rows); meterTotal = number(total); end
    end
    S.seq = S.seq + 1;
    local fields = { "AZSGP1", S.seq, now, phase, S.frames, S.loaded or 0, S.updates, S.widths,
        S.fonts, S.spawns, S.misses, S.activePeak, active, S.hookedWidths, S.hookedFonts,
        S.unsupported, S.preexisting, S.requestedCount, S.actualCount, S.sizeOverflow,
        children, childShown, regions, worldCapped, total, totalShown, enumCapped,
        S.observerReads, number(controller.desiredSpeed100), number(controller.speed100),
        controller.frameGuardTripped and 1 or 0, memory, threshold, now < 0 and 1 or 0,
        S.updateHook or 0, S.createHook or 0, S.versionUnsupported or 0, meterRows, meterTotal };
    for index = 1, table.getn(fields) do
        if (type(fields[index]) == "number") then fields[index] = string.format("%.0f", number(fields[index])); end
    end
    SetCVar(cvar, table.concat(fields, "|")); ConsoleExec(cvar);
end
frame:RegisterEvent("PLAYER_ENTERING_WORLD");
frame:RegisterEvent("ADDON_LOADED");
frame:SetScript("OnEvent", install);
frame:SetScript("OnUpdate", function()
    increment("frames"); install();
    local now = number(safe(time));
    if (now >= 0) then now = math.floor(now); end
    if (now ~= S.lastWall) then S.lastWall = now; emit(now); end
end);

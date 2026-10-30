-- The native hint reflects the game's own language.txt at world entry.
-- GetLocale only describes the older client locale and is a weak fallback.
AZSSpeedGearI18n = AZSSpeedGearI18n or {};
local L = AZSSpeedGearI18n;
L.code = "en";
L.source = "fallback";
L.listeners = {};
local aliases = {
    enUS = "en", enGB = "en", plPL = "pl", csCZ = "cs", deDE = "de", ptBR = "pt",
    esES = "es", esMX = "es", frFR = "fr", roRO = "ro", trTR = "tr", ruRU = "ru",
    ukUA = "uk", zhCN = "zh", zhTW = "zh", jaJP = "ja", koKR = "ko"
};

local function supported(code)
    return type(code) == "string" and type(L.catalogs) == "table" and type(L.catalogs[code]) == "table";
end

function L.Text(key)
    local catalog = L.catalogs and (L.catalogs[L.code] or L.catalogs.en);
    return catalog and catalog[key] or key;
end

function L.Listen(callback)
    table.insert(L.listeners, callback);
end

function L.Select(code, source)
    if (not supported(code)) then return false; end
    local changed = L.code ~= code;
    L.code = code;
    L.source = source or "fallback";
    if (changed) then
        local i = 1;
        while (i <= table.getn(L.listeners)) do
            pcall(L.listeners[i]);
            i = i + 1;
        end
    end
    return true;
end

function L.Refresh()
    if (supported(AZSSpeedGearNativeLocale)) then
        return L.Select(AZSSpeedGearNativeLocale, "game-setting");
    end
    -- Optional coexistence fallback when the native backend has not yet been updated.
    -- No private texture or translation table from another addon is copied.
    if (type(DFRL) == "table" and type(DFRL.locale) == "table" and supported(DFRL.locale.code)) then
        return L.Select(DFRL.locale.code, "hud-language");
    end
    if (type(GetLocale) == "function") then
        local ok, code = pcall(GetLocale);
        if (ok) then
            code = aliases[code] or code;
            if (supported(code)) then return L.Select(code, "client-fallback"); end
        end
    end
    return false;
end

L.Refresh();

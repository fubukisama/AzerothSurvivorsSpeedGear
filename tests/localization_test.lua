dofile("AddOns/AZSSpeedGear/Localization.lua");
dofile("AddOns/AZSSpeedGear/LocaleDetection.lua");
local L = AZSSpeedGearI18n;
local checks = 0;
local function check(value, message)
    checks = checks + 1;
    if (not value) then error(message); end
end
local function placeholders(text)
    local values = {};
    for value in string.gfind(text, "%%[%d%.]*[sf]") do table.insert(values, value); end
    return table.concat(values, "|");
end
local languages = { "en", "zh", "ja", "pl", "cs", "de", "pt", "es", "fr", "ro", "tr", "ru", "uk", "ko" };
local index = 1;
GetLocale = function() return "enUS"; end;
while (index <= table.getn(languages)) do
    local code = languages[index];
    local catalog = L.catalogs[code];
    check(type(catalog) == "table", "catalog exists: " .. code);
    for key, source in pairs(L.catalogs.en) do
        check(type(catalog[key]) == "string" and catalog[key] ~= "", "translated caption exists: " .. code .. "/" .. key);
        check(placeholders(catalog[key]) == placeholders(source), "format placeholders match: " .. code .. "/" .. key);
    end
    for key, value in pairs(catalog) do check(L.catalogs.en[key] ~= nil, "no unknown caption key: " .. code .. "/" .. key); end
    AZSSpeedGearNativeLocale = code;
    L.Refresh();
    check(L.code == code and L.source == "game-setting", "native custom language beats classic GetLocale: " .. code);
    check(L.Text("launcher") == catalog.launcher, "lookup follows selected language: " .. code);
    check(type(string.format(L.Text("suspended"), "2")) == "string", "format speed: " .. code);
    check(type(string.format(L.Text("measured"), 2)) == "string", "format measurement: " .. code);
    index = index + 1;
end
local changes = 0;
L.Listen(function() changes = changes + 1; end);
AZSSpeedGearNativeLocale = "ja";
L.Refresh(); L.Refresh();
check(changes == 1, "caption listeners run once per actual change");
check(not L.Select("unsupported"), "unknown language does not select missing catalog");
check(L.code == "ja", "unknown language preserves last valid selection");
AZSSpeedGearNativeLocale = nil;
DFRL = { locale = { code = "pl" } };
L.Refresh();
check(L.code == "pl" and L.source == "hud-language", "optional HUD fallback supports custom languages");
DFRL = nil;
GetLocale = function() return "zhCN"; end;
L.Refresh();
check(L.code == "zh" and L.source == "client-fallback", "classic locale alias is a fallback");
GetLocale = function() error("not available"); end;
check(not L.Refresh() and L.code == "zh", "unavailable client API preserves language without propagating");
check(L.Text("unknown_key") == "unknown_key", "unknown captions are safe diagnostic keys");
print("AZSSpeedGear localization: " .. checks .. " checks passed");

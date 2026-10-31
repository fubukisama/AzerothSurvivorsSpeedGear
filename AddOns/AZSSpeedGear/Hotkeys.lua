-- Runtime-only bindings for WoW 1.12 / Lua 5.0. Never save the game's key map.
AZSSpeedGearHotkeys = {};
local Hotkeys = AZSSpeedGearHotkeys;
local COMMANDS = { down = "AZSG_SLOWER", up = "AZSG_FASTER" };
local FIELDS = { down = "hotkeyDown", up = "hotkeyUp" };
local SPEEDS = { 25, 50, 100, 200, 300, 500, 1000 };
local NAMES = {
    SPACE = true, TAB = true, ENTER = true, ESCAPE = true, BACKSPACE = true,
    LEFT = true, RIGHT = true, UP = true, DOWN = true, INSERT = true, DELETE = true,
    HOME = true, END = true, PAGEUP = true, PAGEDOWN = true, NUMLOCK = true,
    CAPSLOCK = true, PRINTSCREEN = true, NUMPADPLUS = true, NUMPADMINUS = true,
    NUMPADMULTIPLY = true, NUMPADDIVIDE = true, NUMPADDECIMAL = true,
    NUMPADEQUALS = true, MOUSEWHEELUP = true, MOUSEWHEELDOWN = true
};
local ALIASES = {
    LEFTBRACKET = "[", RIGHTBRACKET = "]", SLASH = "/", BACKSLASH = "\\",
    SEMICOLON = ";", APOSTROPHE = "'", COMMA = ",", PERIOD = ".",
    TILDE = "`", PLUS = "=", MINUS = "-"
};

local function oneCharacter(value)
    local length = string.len(value);
    if (length == 1) then
        local byte = string.byte(value);
        return byte > 32 and byte < 127;
    end
    -- The client also names keys from non-English layouts with one UTF-8 character.
    local first = string.byte(value, 1);
    local expected;
    if (first and first >= 194 and first <= 223) then expected = 2;
    elseif (first and first >= 224 and first <= 239) then expected = 3;
    elseif (first and first >= 240 and first <= 244) then expected = 4; end
    if (length ~= expected) then return false; end
    local i = 2;
    while (i <= length) do
        local byte = string.byte(value, i);
        if (byte < 128 or byte > 191) then return false; end
        i = i + 1;
    end
    local second = string.byte(value, 2);
    if ((first == 224 and second < 160) or (first == 237 and second > 159) or
        (first == 240 and second < 144) or (first == 244 and second > 143)) then return false; end
    return true;
end

function Hotkeys.Normalize(key)
    if (type(key) ~= "string") then return nil; end
    key = string.upper(string.gsub(string.gsub(key, "^%s+", ""), "%s+$", ""));
    if (key == "") then return ""; end
    local modifiers = {};
    local reading = true;
    while (reading) do
        reading = false;
        local name;
        for name in pairs({ ALT = true, CTRL = true, SHIFT = true }) do
            local prefix = name .. "-";
            if (string.sub(key, 1, string.len(prefix)) == prefix) then
                modifiers[name] = true;
                key = string.sub(key, string.len(prefix) + 1);
                reading = true;
                break;
            end
        end
    end
    key = ALIASES[key] or key;
    local valid = NAMES[key] or oneCharacter(key);
    local _, _, number = string.find(key, "^F(%d+)$");
    if (number) then valid = tonumber(number) >= 1 and tonumber(number) <= 24 and key == "F" .. tonumber(number); end
    _, _, number = string.find(key, "^NUMPAD(%d)$");
    if (number) then valid = true; end
    _, _, number = string.find(key, "^BUTTON(%d+)$");
    if (number) then valid = tonumber(number) >= 1 and tonumber(number) <= 20 and key == "BUTTON" .. tonumber(number); end
    if (not valid) then return nil; end
    local chord = "";
    if (modifiers.ALT) then chord = chord .. "ALT-"; end
    if (modifiers.CTRL) then chord = chord .. "CTRL-"; end
    if (modifiers.SHIFT) then chord = chord .. "SHIFT-"; end
    return chord .. key;
end

function Hotkeys.NextSpeed(speed100, direction)
    if (type(speed100) ~= "number" or speed100 ~= speed100) then speed100 = 100; end
    local i;
    if (type(direction) == "number" and direction < 0) then
        i = table.getn(SPEEDS);
        while (i >= 1) do
            if (SPEEDS[i] < speed100) then return SPEEDS[i]; end
            i = i - 1;
        end
        return SPEEDS[1];
    end
    i = 1;
    while (i <= table.getn(SPEEDS)) do
        if (SPEEDS[i] > speed100) then return SPEEDS[i]; end
        i = i + 1;
    end
    return SPEEDS[table.getn(SPEEDS)];
end

local function pack(...) return arg; end

-- Lua 5.0 unpack has no first/last arguments; use the saved count for nil holes.
local function expand(values, index, count)
    if (index > count) then return; end
    return values[index], expand(values, index + 1, count);
end

function Hotkeys.NewManager(api, db)
    api = type(api) == "table" and api or {};
    db = type(db) == "table" and db or {};
    local self = { active = false, busy = false, owned = {}, db = db };
    db.hotkeyDown = Hotkeys.Normalize(db.hotkeyDown) or "Q";
    db.hotkeyUp = Hotkeys.Normalize(db.hotkeyUp) or "E";
    if (db.hotkeyDown ~= "" and db.hotkeyDown == db.hotkeyUp) then
        db.hotkeyDown = "Q";
        db.hotkeyUp = "E";
    end

    function self:Available()
        return type(api.getBinding) == "function" and type(api.setBinding) == "function";
    end

    function self:GetKey(action)
        local field = FIELDS[action];
        return field and db[field] or nil;
    end

    local function read(key)
        local ok, value = pcall(api.getBinding, key);
        if (not ok or (value ~= nil and type(value) ~= "string")) then return false, nil; end
        return true, value or "";
    end

    local function write(key, value)
        if (value == "") then value = nil; end
        local ok, result = pcall(api.setBinding, key, value);
        return ok and (result == 1 or result == true);
    end

    local function commit(down, up, explicit)
        if (not self:Available()) then return false, "unavailable"; end
        local wanted, observed, goals, nextOwned = {}, {}, {}, {};
        if (down ~= "") then wanted[down] = COMMANDS.down; end
        if (up ~= "") then wanted[up] = COMMANDS.up; end
        local key, record, action;
        for key in pairs(self.owned) do observed[key] = false; end
        for key in pairs(wanted) do observed[key] = false; end
        for key in pairs(observed) do
            local ok, current = read(key);
            if (not ok) then return false, "set_failed"; end
            observed[key] = current;
        end
        for key, record in pairs(self.owned) do
            if (not wanted[key] and not record.lost and observed[key] == record.command) then
                goals[key] = record.base;
            end
        end
        local conflict = false;
        for key, action in pairs(wanted) do
            record = self.owned[key];
            if (record and not record.lost and observed[key] == record.command) then
                nextOwned[key] = { base = record.base, command = action };
                if (observed[key] ~= action) then goals[key] = action; end
            elseif (record and not (explicit and explicit[key])) then
                -- A later addon/user binding owns this key now. A refresh must not steal it.
                nextOwned[key] = { base = record.base, command = action, lost = true };
                conflict = true;
            else
                local base = observed[key];
                if (base == COMMANDS.down or base == COMMANDS.up) then base = ""; end
                nextOwned[key] = { base = base, command = action };
                goals[key] = action;
            end
        end
        local attempted = {};
        for key, action in pairs(goals) do
            table.insert(attempted, key);
            if (not write(key, action)) then
                -- Include the failed call: an external wrapper may mutate before failing.
                local i = table.getn(attempted);
                while (i >= 1) do
                    key = attempted[i];
                    write(key, observed[key]);
                    i = i - 1;
                end
                return false, "set_failed";
            end
        end
        self.owned = nextOwned;
        return true, conflict and "conflict" or nil;
    end

    function self:Apply()
        if (self.busy) then return true; end
        self.busy = true;
        local ok, reason = commit(db.hotkeyDown, db.hotkeyUp);
        self.busy = false;
        if (ok) then self.active = true; end
        if (reason == "conflict") then return false, reason; end
        return ok, reason;
    end

    function self:Release()
        if (self.busy) then return true; end
        self.active = false;
        if (not next(self.owned)) then return true; end
        if (not self:Available()) then return false, "unavailable"; end
        self.busy = true;
        local released = true;
        local key, record;
        for key, record in pairs(self.owned) do
            local ok, current = read(key);
            if (not ok) then
                released = false;
            elseif (record.lost or current ~= record.command) then
                self.owned[key] = nil;
            elseif (write(key, record.base)) then
                self.owned[key] = nil;
            else
                released = false;
            end
        end
        self.busy = false;
        if (not released) then return false, "set_failed"; end
        return true;
    end

    local function settings(down, up, explicit)
        if (self.busy) then return false, "busy"; end
        if (down ~= "" and down == up) then return false, "duplicate"; end
        if (self.active) then
            self.busy = true;
            local ok, reason = commit(down, up, explicit);
            self.busy = false;
            if (not ok) then return false, reason; end
        end
        db.hotkeyDown, db.hotkeyUp = down, up;
        return true;
    end

    function self:SetKey(action, key)
        if (not FIELDS[action]) then return false, "invalid"; end
        key = Hotkeys.Normalize(key);
        if (key == nil) then return false, "invalid"; end
        local down, up = db.hotkeyDown, db.hotkeyUp;
        if (action == "down") then down = key; else up = key; end
        local explicit = {};
        if (key ~= "") then explicit[key] = true; end
        return settings(down, up, explicit);
    end

    function self:Reset()
        return settings("Q", "E", { Q = true, E = true });
    end

    function self:WithBaseBindings(callback, ...)
        local arguments = arg;
        if (self.busy or not self.active or not self:Available()) then
            return callback(expand(arguments, 1, arguments.n));
        end
        self.busy = true;
        local restored = {};
        local key, record;
        local ready = true;
        for key, record in pairs(self.owned) do
            local ok, current = read(key);
            if (not ok) then ready = false; break; end
            if (not record.lost and current == record.command) then
                restored[key] = record;
                if (not write(key, record.base)) then ready = false; break; end
            elseif (current ~= record.command) then
                record.lost = true;
            end
        end
        local result;
        if (ready) then result = pack(pcall(callback, expand(arguments, 1, arguments.n))); end
        local reapplied = true;
        for key, record in pairs(restored) do
            local ok, current = read(key);
            if (ok and current == record.base) then
                if (not write(key, record.command)) then reapplied = false; end
            elseif (not ok) then
                reapplied = false;
            elseif (current ~= record.command) then
                record.lost = true;
            end
        end
        self.busy = false;
        if (not ready) then error("Could not restore base key bindings before saving", 0); end
        if (not result[1]) then error(result[2], 0); end
        if (not reapplied) then error("Could not restore speed hotkeys after saving", 0); end
        return expand(result, 2, result.n);
    end

    return self;
end

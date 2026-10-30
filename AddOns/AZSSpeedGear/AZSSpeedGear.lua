-- WoW 1.12 / Lua 5.0: no modern Lua operators or modern frame callbacks.
AZSSpeedGear = {};
local Gear = AZSSpeedGear;
local I18n = AZSSpeedGearI18n;
local function tr(key) return I18n.Text(key); end
local COMMAND_CVAR = "AZSSpeedGearCommand";
local MIN_SPEED = 25;
local MAX_SPEED = 1000;

local function finiteNumber(value)
    return type(value) == "number" and value == value and value > -1e100 and value < 1e100;
end

local function safeCall(fn)
    if (type(fn) ~= "function") then return nil; end
    local ok, value = pcall(fn);
    if (ok) then return value; end
    return nil;
end

local function integerText(value)
    return string.format("%.0f", value);
end

local function speedText(value)
    local text = string.format("%.2f", value / 100);
    text = string.gsub(text, "0+$", "");
    text = string.gsub(text, "%.$", "");
    return text;
end

-- Dependencies keep the protocol and state transitions testable without a client.
function Gear.NewController(api)
    local self = {};
    self.api = api;
    self.sequence = 0;
    self.speed100 = 100;
    self.desiredSpeed100 = 100;
    self.active = false;
    self.phase = nil;
    self.solo = nil;
    self.lastSent = nil;
    self.lastPulse = nil;
    self.measured = nil;
    self.confirmedSpeed100 = nil;
    self.measurePendingAt = nil;
    self.measureStart = nil;
    self.measureRun = nil;
    self.previousRun = nil;
    self.lastObservedRun = nil;
    self.bridgeReady = false;
    self.writeFailed = false;
    self.initialized = false;

    local now = safeCall(api.now);
    local random = safeCall(api.random);
    if (not finiteNumber(now) or now < 1) then now = 1; end
    if (not finiteNumber(random)) then random = 1; end
    random = math.floor(random);
    if (random < 1 or random > 999) then random = 1; end
    self.session = math.floor(now) * 1000 + random;
    if (type(api.register) == "function" and type(api.send) == "function") then
        local ok, result = pcall(api.register);
        self.bridgeReady = ok and result ~= false;
    end

    function self:RealTime()
        local value = safeCall(self.api.now);
        if (not finiteNumber(value) or value < 1) then return nil; end
        return math.floor(value);
    end

    function self:ResetMeasurement()
        self.measured = nil;
        self.confirmedSpeed100 = nil;
        self.measurePendingAt = nil;
        self.measureStart = nil;
        self.measureRun = nil;
        self.previousRun = nil;
    end

    function self:Emit(now)
        if (not self.bridgeReady or not now) then return false; end
        self.sequence = self.sequence + 1;
        local command = "SG1|" .. integerText(self.session) .. "|" .. integerText(self.sequence)
            .. "|" .. integerText(now) .. "|" .. integerText(self.speed100)
            .. "|" .. (self.active and "1" or "0");
        local ok, result = pcall(self.api.send, command);
        if (not ok or result == false) then
            self.bridgeReady = false;
            self.writeFailed = true;
            self.active = false;
            self.speed100 = 100;
            self:ResetMeasurement();
            return false;
        end
        self.lastSent = now;
        self:Pulse(now);
        return true;
    end

    function self:Pulse(now)
        if (type(self.api.pulse) == "function") then
            -- Querying the already-set CVar logs it synchronously without making
            -- the shared config dirty. Native receives this on its console pipe.
            pcall(self.api.pulse);
            self.lastPulse = now;
        end
    end

    function self:Measure(now, run, sampled)
        if (not sampled) then run = safeCall(self.api.runTime); end
        if (not now or not finiteNumber(run) or run < 0) then self:ResetMeasurement(); return; end
        if (self.previousRun and run < self.previousRun) then
            if (self.previousRun - run > 1) then
                self:ResetMeasurement();
            else
                -- Server clock corrections must not restart the real-time window.
                -- Retain its high-water mark without inventing any clock advance.
                run = self.previousRun;
            end
        end
        self.previousRun = run;
        if (not self.measurePendingAt or now < self.measurePendingAt or (self.measureStart and now < self.measureStart)) then
            self:ResetMeasurement();
            self.measurePendingAt = now;
            self.previousRun = run;
            return;
        end
        if (not self.measureStart) then
            -- The request can arrive anywhere inside time()'s integer second.
            -- Start only on a later observed boundary, never backdate its value.
            if (now <= self.measurePendingAt) then return; end
            self.measureStart = now;
            self.measureRun = run;
            return;
        end
        local elapsed = now - self.measureStart;
        if (elapsed >= 1) then
            local delta = run - self.measureRun;
            self.measured = nil;
            if (delta > 0) then self.measured = delta / elapsed; end
            local target = self.speed100 / 100;
            local tolerance = 0.10;
            if (self.confirmedSpeed100 == self.speed100) then tolerance = 0.20; end
            if (finiteNumber(self.measured) and self.measured > 0
                and math.abs(self.measured - target) <= target * tolerance) then
                self.confirmedSpeed100 = self.speed100;
            else self.confirmedSpeed100 = nil; end
            self.measureStart = now;
            self.measureRun = run;
        end
    end

    function self:Update()
        local now = self:RealTime();
        self.phase = safeCall(self.api.phase);
        self.solo = safeCall(self.api.isSolo);
        local newRun = self.phase == "ready" or self.phase == "dead" or self.phase == "victory";
        local run = safeCall(self.api.runTime);
        if (newRun) then
            self.lastObservedRun = nil;
        elseif (finiteNumber(run) and run >= 0 and (self.phase == "playing" or self.phase == "paused" or self.phase == "choosing")) then
            if (self.lastObservedRun and run + 1 < self.lastObservedRun) then newRun = true; end
            self.lastObservedRun = run;
        end
        if (newRun) then self.desiredSpeed100 = 100; end
        local allowed = self.bridgeReady and now ~= nil and self.phase == "playing" and self.solo == true;
        if (not self.initialized or allowed ~= self.active or (allowed and self.speed100 ~= self.desiredSpeed100)) then
            self.initialized = true;
            self.active = allowed;
            -- Choices and pause suspend the request while retaining this run's setting.
            -- A new run, explicit stop or world exit resets that setting to one.
            self.speed100 = allowed and self.desiredSpeed100 or 100;
            self:ResetMeasurement();
            self:Emit(now);
        elseif (self.bridgeReady and now and (not self.lastSent or now < self.lastSent or now - self.lastSent >= 5)) then
            self:Emit(now);
        elseif (self.bridgeReady and now and (not self.lastPulse or now < self.lastPulse or now - self.lastPulse >= 1)) then
            self:Pulse(now);
        end
        -- Reuse this update's native sample: two reads can straddle a correction.
        if (self.active) then self:Measure(now, run, true); else self:ResetMeasurement(); end
    end

    function self:RequestSpeed(value)
        self:Update();
        if (not finiteNumber(value) or value < MIN_SPEED or value > MAX_SPEED or not self.active) then return false; end
        self.speed100 = math.floor(value + 0.5);
        self.desiredSpeed100 = self.speed100;
        self:ResetMeasurement();
        local now = self:RealTime();
        local emitted = self:Emit(now);
        if (self.active) then self:Measure(now); end
        return emitted;
    end

    function self:EmergencyStop()
        self:Update();
        self.speed100 = 100;
        self.desiredSpeed100 = 100;
        self:ResetMeasurement();
        local now = self:RealTime();
        local emitted = self:Emit(now);
        if (self.active) then self:Measure(now); end
        return emitted;
    end

    function self:Shutdown()
        self.active = false;
        self.speed100 = 100;
        self.desiredSpeed100 = 100;
        self.lastObservedRun = nil;
        self:ResetMeasurement();
        return self:Emit(self:RealTime());
    end

    return self;
end

-- A test runner can load the state machine without creating native frames.
if (AZSSpeedGear_TEST) then return; end

local function partyNumber(fn)
    local count = safeCall(fn);
    if (finiteNumber(count) and count >= 0) then return count; end
    return nil;
end

local function isSolo()
    -- Use the native party API; an unavailable API cannot establish solo play.
    local count = partyNumber(GetNumPartyMembers);
    local raid = partyNumber(GetNumRaidMembers);
    if ((count and count > 0) or (raid and raid > 0)) then return false; end
    if (type(AZS_PARTY) == "table" and table.getn(AZS_PARTY) > 0) then return false; end
    if (count ~= nil) then return true; end
    if (type(AZS_PARTY) == "table") then return true; end
    return nil;
end

local function registerBridge()
    if (type(RegisterCVar) ~= "function" or type(SetCVar) ~= "function") then return false; end
    RegisterCVar(COMMAND_CVAR, "");
    return true;
end

local worldActive = false;
local controller = Gear.NewController({
    now = function() if (type(time) == "function") then return time(); end end,
    random = function() return math.random(1, 999); end,
    phase = function() if (worldActive and type(AZS_GetPhase) == "function") then return AZS_GetPhase(); end end,
    isSolo = isSolo,
    runTime = function() if (type(AZS_GetRunTime) == "function") then return AZS_GetRunTime(); end end,
    register = registerBridge,
    send = function(command) SetCVar(COMMAND_CVAR, command); return true; end,
    pulse = function() if (type(ConsoleExec) == "function") then ConsoleExec(COMMAND_CVAR); end end
});
Gear.controller = controller;

local panel = nil;
local launcher = nil;
local statusLabel = nil;
local measurementLabel = nil;
local customBox = nil;
local noticeLabel = nil;
local lastRendered = nil;
local dbReady = false;
local captions = {};
local noticeKey = "hint";
local lastLocaleSecond = nil;
local lastLauncherText = nil;

local function bindText(widget, key)
    table.insert(captions, { widget = widget, key = key });
    widget:SetText(tr(key));
    return widget;
end

local function sizeLauncher(text)
    if (not launcher) then return; end
    text = text or tr("launcher");
    local width = 0;
    if (type(launcher.GetFontString) == "function") then
        local ok, font = pcall(launcher.GetFontString, launcher);
        if (ok and font and type(font.GetStringWidth) == "function") then
            local measured, value = pcall(font.GetStringWidth, font);
            if (measured and finiteNumber(value)) then width = value; end
        end
    end
    if (width <= 0) then
        local index = 1;
        while (index <= string.len(text)) do
            local byte = string.byte(text, index);
            if (byte < 128) then width = width + 7;
            elseif (byte >= 192) then width = width + 12; end
            index = index + 1;
        end
    end
    launcher:SetWidth(math.max(64, math.min(160, math.ceil(width + 20))));
end

local function measurementMatchesTarget()
    if (not controller.active or not finiteNumber(controller.measured) or controller.measured <= 0) then return false; end
    return controller.confirmedSpeed100 == controller.speed100;
end

local function updateLauncher()
    if (not launcher) then return; end
    local text = tr("launcher");
    if (worldActive and controller.active) then
        if (measurementMatchesTarget()) then text = text .. " ×" .. speedText(controller.speed100);
        else text = text .. " …"; end
    end
    if (text ~= lastLauncherText) then
        launcher:SetText(text);
        lastLauncherText = text;
        -- Resizing during native dragging would move the pointer's grab point.
        if (not launcher.speedGearDragging) then sizeLauncher(text); end
    end
end

local function chat(message)
    if (DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function") then
        DEFAULT_CHAT_FRAME:AddMessage("|cff8ab4ff" .. tr("chat_prefix") .. "|r" .. message);
    end
end

local function savedDatabase()
    if (type(AZSSpeedGearDB) ~= "table") then AZSSpeedGearDB = {}; end
    if (AZSSpeedGearDB.show == nil) then AZSSpeedGearDB.show = false; end
    return AZSSpeedGearDB;
end

local function validPosition(point, relativePoint, x, y)
    local points = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true };
    return type(point) == "string" and type(relativePoint) == "string" and points[point] and points[relativePoint]
        and finiteNumber(x) and finiteNumber(y) and math.abs(x) < 10000 and math.abs(y) < 10000;
end

local function showLauncher()
    if (launcher) then
        if (worldActive) then launcher:Show(); else launcher:Hide(); end
    end
end

local function setShown(shown)
    local db = savedDatabase();
    db.show = shown and true or false;
    if (panel) then if (db.show) then panel:Show(); else panel:Hide(); end end
end

local function render()
    updateLauncher();
    if (measurementMatchesTarget() and (noticeKey == "switching" or noticeKey == "stop_sent")) then
        noticeKey = "hint";
        if (noticeLabel) then noticeLabel:SetText(tr(noticeKey)); end
    end
    if (not statusLabel) then return; end
    local status = "";
    if (not controller.bridgeReady) then
        status = tr("channel_unavailable");
    elseif (not controller:RealTime()) then
        status = tr("real_clock_unavailable");
    elseif (controller.phase == nil) then
        status = tr("phase_unavailable");
    elseif (controller.solo == false) then
        status = tr("coop_protection");
    elseif (controller.solo == nil) then
        status = tr("solo_unknown");
    elseif (not controller.active) then
        if (controller.desiredSpeed100 ~= 100) then
            status = string.format(tr("suspended"), speedText(controller.desiredSpeed100));
        else status = tr("inactive"); end
    else
        status = string.format(tr("target_wait"), speedText(controller.speed100));
        if (controller.measured) then
            if (not measurementMatchesTarget()) then
                status = tr("below_target");
            else status = string.format(tr("target_measured"), speedText(controller.speed100)); end
        end
    end
    local measurement = tr("measurement_wait");
    if (controller.measured) then
        measurement = string.format(tr("measured"), controller.measured);
    end
    local signature = status .. measurement;
    if (signature ~= lastRendered) then
        statusLabel:SetText(status);
        measurementLabel:SetText(measurement);
        lastRendered = signature;
    end
end

local function requestSpeed(value)
    if (controller:RequestSpeed(value)) then
        noticeKey = "switching";
        if (noticeLabel) then noticeLabel:SetText(tr(noticeKey)); end
    else
        noticeKey = "invalid_speed";
        if (noticeLabel) then noticeLabel:SetText(tr(noticeKey)); end
    end
    render();
end

local function emergencyStop()
    local sent = controller:EmergencyStop();
    if (noticeLabel) then
        if (sent) then noticeKey = "stop_sent";
        else noticeKey = "stop_failed"; end
        noticeLabel:SetText(tr(noticeKey));
    end
    render();
end

local function addText(parent, size, x, y, text)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    -- Inherit the client's localized font, including Chinese glyph coverage.
    -- Resolve a real native font path rather than hard-coding a Latin-only face.
    if (GameFontNormal and type(GameFontNormal.GetFont) == "function" and type(label.SetFont) == "function") then
        local ok, face, oldSize, flags = pcall(GameFontNormal.GetFont, GameFontNormal);
        if (ok and type(face) == "string" and face ~= "") then pcall(label.SetFont, label, face, size, flags or ""); end
    end
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    label:SetWidth(528);
    label:SetHeight(34);
    label:SetJustifyH("LEFT");
    bindText(label, text);
    return label;
end

local function addButton(parent, name, text, x, y, width, callback)
    local button = CreateFrame("Button", name, parent, "UIPanelButtonTemplate");
    button:SetWidth(width);
    button:SetHeight(26);
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    if (I18n.catalogs.en[text]) then bindText(button, text);
    else button:SetText(text); end
    button:SetScript("OnClick", callback);
    return button;
end

local function buildLauncher()
    if (launcher or type(CreateFrame) ~= "function" or not UIParent) then return; end
    launcher = CreateFrame("Button", "AZSSpeedGearLauncher", UIParent, "UIPanelButtonTemplate");
    launcher:SetWidth(64);
    launcher:SetHeight(30);
    launcher:SetPoint("RIGHT", UIParent, "RIGHT", -24, 80);
    launcher:SetFrameStrata("DIALOG");
    updateLauncher();
    launcher:SetMovable(true);
    launcher:EnableMouse(true);
    launcher:RegisterForDrag("LeftButton");
    if (type(launcher.SetClampedToScreen) == "function") then pcall(launcher.SetClampedToScreen, launcher, true); end
    launcher:SetScript("OnMouseDown", function()
        -- A fresh press clears a drag whose release emitted no OnClick.
        this.speedGearDragging = false;
        this.speedGearSuppressClick = false;
    end);
    launcher:SetScript("OnDragStart", function()
        this.speedGearDragging = true;
        this.speedGearSuppressClick = true;
        this:StartMoving();
    end);
    launcher:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        this.speedGearDragging = false;
        this.speedGearSuppressClick = true;
        local point, relative, relativePoint, x, y = this:GetPoint(1);
        if (validPosition(point, relativePoint, x, y)) then
            local db = savedDatabase();
            db.launcherPoint = point;
            db.launcherRelativePoint = relativePoint;
            db.launcherX = x;
            db.launcherY = y;
        end
        sizeLauncher(lastLauncherText);
    end);
    launcher:SetScript("OnClick", function()
        if (this.speedGearDragging or this.speedGearSuppressClick) then
            this.speedGearSuppressClick = false;
            return;
        end
        setShown(not savedDatabase().show);
    end);
    launcher:SetScript("OnEnter", function()
        if (GameTooltip and type(GameTooltip.SetOwner) == "function" and type(GameTooltip.SetText) == "function" and type(GameTooltip.Show) == "function") then
            GameTooltip:SetOwner(this, "ANCHOR_LEFT");
            GameTooltip:SetText(tr("launcher_hint"));
            GameTooltip:Show();
        end
    end);
    launcher:SetScript("OnLeave", function()
        if (GameTooltip and type(GameTooltip.Hide) == "function") then GameTooltip:Hide(); end
    end);
    launcher:Hide();
    Gear.launcher = launcher;
end

local function buildPanel()
    if (panel or type(CreateFrame) ~= "function" or not UIParent) then return; end
    panel = CreateFrame("Frame", "AZSSpeedGearPanel", UIParent);
    panel:SetWidth(560);
    panel:SetHeight(348);
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
    panel:SetFrameStrata("DIALOG");
    panel:SetMovable(true);
    panel:EnableMouse(true);
    panel:RegisterForDrag("LeftButton");
    if (type(panel.SetClampedToScreen) == "function") then pcall(panel.SetClampedToScreen, panel, true); end
    panel:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } });
    panel:SetBackdropColor(0.04, 0.06, 0.10, 0.96);
    panel:SetScript("OnDragStart", function() this:StartMoving(); end);
    panel:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        local point, relative, relativePoint, x, y = this:GetPoint(1);
        local db = savedDatabase();
        db.point = point;
        db.relativePoint = relativePoint;
        db.x = x;
        db.y = y;
    end);
    local title = addText(panel, 14, 16, -16, "title");
    title:SetWidth(410);
    addButton(panel, "AZSSpeedGearClose", "close", 440, -10, 104, function() setShown(false); end);
    statusLabel = addText(panel, 12, 16, -50, "inactive");
    measurementLabel = addText(panel, 11, 16, -86, "measurement_wait");
    local presets = { 50, 100, 200, 300, 500 };
    local i = 1;
    while (i <= table.getn(presets)) do
        local selected = presets[i];
        addButton(panel, "AZSSpeedGearPreset" .. i, "x" .. speedText(selected), 16 + (i - 1) * 104, -128, 96,
            function() requestSpeed(selected); end);
        i = i + 1;
    end
    local customLabel = addText(panel, 11, 16, -180, "custom");
    customLabel:SetWidth(270);
    customBox = CreateFrame("EditBox", "AZSSpeedGearCustom", panel, "InputBoxTemplate");
    customBox:SetWidth(70);
    customBox:SetHeight(26);
    customBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 300, -172);
    customBox:SetAutoFocus(false);
    customBox:SetMaxLetters(6);
    customBox:SetText("1");
    local function submitCustom()
        local number = tonumber(customBox:GetText());
        if (finiteNumber(number)) then requestSpeed(number * 100);
        else noticeKey = "invalid_speed"; noticeLabel:SetText(tr(noticeKey)); end
        customBox:ClearFocus();
    end
    customBox:SetScript("OnEnterPressed", submitCustom);
    customBox:SetScript("OnEscapePressed", function() this:ClearFocus(); end);
    addButton(panel, "AZSSpeedGearApply", "apply", 390, -172, 140, submitCustom);
    addButton(panel, "AZSSpeedGearStop", "stop", 16, -224, 528, emergencyStop);
    noticeLabel = addText(panel, 11, 16, -270, "hint");
    addText(panel, 10, 16, -312, "commands");
    Gear.panel = panel;
end

local function loadSettings()
    I18n.Refresh();
    local db = savedDatabase();
    dbReady = true;
    buildPanel();
    buildLauncher();
    if (panel and validPosition(db.point, db.relativePoint, db.x, db.y)) then
        panel:ClearAllPoints();
        panel:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y);
    end
    if (launcher and validPosition(db.launcherPoint, db.launcherRelativePoint, db.launcherX, db.launcherY)) then
        launcher:ClearAllPoints();
        launcher:SetPoint(db.launcherPoint, UIParent, db.launcherRelativePoint, db.launcherX, db.launcherY);
    end
    setShown(db.show);
    showLauncher();
    controller:Update();
    render();
end

local function slash(message)
    message = string.lower(message or "");
    message = string.gsub(message, "^%s+", "");
    message = string.gsub(message, "%s+$", "");
    if (not dbReady) then loadSettings(); end
    if (message == "show") then setShown(true);
    elseif (message == "hide") then setShown(false);
    elseif (message == "stop" or message == "reset" or message == "1") then emergencyStop();
    elseif (message == "" or message == "toggle") then setShown(not savedDatabase().show);
    elseif (tonumber(message)) then requestSpeed(tonumber(message) * 100);
    else chat(tr("help")); end
end

I18n.Listen(function()
    local index = 1;
    while (index <= table.getn(captions)) do
        local entry = captions[index];
        entry.widget:SetText(tr(entry.key));
        index = index + 1;
    end
    updateLauncher();
    if (noticeLabel) then noticeLabel:SetText(tr(noticeKey)); end
    lastRendered = nil;
    render();
end);

SLASH_AZSSPEEDGEAR1 = "/azsg";
SLASH_AZSSPEEDGEAR2 = "/speedgear";
if (type(SlashCmdList) == "table") then SlashCmdList["AZSSPEEDGEAR"] = slash; end

if (type(CreateFrame) == "function") then
    -- Separate always-visible driver: hiding the panel must not stop heartbeats.
    local driver = CreateFrame("Frame", "AZSSpeedGearDriver", UIParent);
    driver:RegisterEvent("ADDON_LOADED");
    driver:RegisterEvent("PLAYER_ENTERING_WORLD");
    driver:RegisterEvent("PLAYER_LEAVING_WORLD");
    driver:RegisterEvent("PLAYER_LOGOUT");
    driver:SetScript("OnEvent", function()
        if (event == "PLAYER_LOGOUT" or event == "PLAYER_LEAVING_WORLD") then
            worldActive = false;
            showLauncher();
            controller:Shutdown();
            updateLauncher();
        elseif (event == "ADDON_LOADED") then
            if (arg1 == "AZSSpeedGear") then loadSettings(); end
        elseif (event == "PLAYER_ENTERING_WORLD") then
            worldActive = true;
            I18n.Refresh();
            if (not dbReady) then loadSettings(); end
            showLauncher();
            controller:Update();
            render();
        end
    end);
    driver:SetScript("OnUpdate", function()
        if (dbReady) then
            local now = controller:RealTime();
            if (now ~= lastLocaleSecond) then I18n.Refresh(); lastLocaleSecond = now; end
            controller:Update(); render();
        end
    end);
    Gear.driver = driver;
end

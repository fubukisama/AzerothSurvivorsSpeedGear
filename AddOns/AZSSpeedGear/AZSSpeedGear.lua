-- WoW 1.12 / Lua 5.0: no modern Lua operators or modern frame callbacks.
AZSSpeedGear = {};
local Gear = AZSSpeedGear;
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
    self.measured = nil;
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
        return true;
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
        if (not self.measureStart or now < self.measureStart) then
            self.measureStart = now;
            self.measureRun = run;
            self.measured = nil;
            return;
        end
        local elapsed = now - self.measureStart;
        if (elapsed >= 3) then
            local delta = run - self.measureRun;
            self.measured = nil;
            if (delta > 0) then self.measured = delta / elapsed; end
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
        elseif (self.bridgeReady and now and (not self.lastSent or now < self.lastSent or now - self.lastSent >= 3)) then
            self:Emit(now);
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
    send = function(command) SetCVar(COMMAND_CVAR, command); return true; end
});
Gear.controller = controller;

local panel = nil;
local statusLabel = nil;
local measurementLabel = nil;
local customBox = nil;
local noticeLabel = nil;
local lastRendered = nil;
local dbReady = false;

local function chat(message)
    if (DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function") then
        DEFAULT_CHAT_FRAME:AddMessage("|cff8ab4ff变速齿轮：|r" .. message);
    end
end

local function savedDatabase()
    if (type(AZSSpeedGearDB) ~= "table") then AZSSpeedGearDB = {}; end
    if (AZSSpeedGearDB.show == nil) then AZSSpeedGearDB.show = true; end
    return AZSSpeedGearDB;
end

local function setShown(shown)
    local db = savedDatabase();
    db.show = shown and true or false;
    if (panel) then if (db.show) then panel:Show(); else panel:Hide(); end end
end

local function render()
    if (not statusLabel) then return; end
    local status = "";
    if (not controller.bridgeReady) then
        status = "当前游戏无法接收变速请求";
    elseif (not controller:RealTime()) then
        status = "真实计时 API 不可用；无法发送请求";
    elseif (controller.phase == nil) then
        status = "未找到游戏状态 API；已请求 1 倍";
    elseif (controller.solo == false) then
        status = "联机保护：已请求 1 倍";
    elseif (controller.solo == nil) then
        status = "无法确认单人模式；已请求 1 倍";
    elseif (not controller.active) then
        if (controller.desiredSpeed100 ~= 100) then
            status = "已请求暂停倍速；战斗时请求 x" .. speedText(controller.desiredSpeed100);
        else status = "当前未战斗；已请求 1 倍"; end
    else
        status = "目标 x" .. speedText(controller.speed100) .. " / 等待实测";
        if (controller.measured) then
            if (math.abs(controller.measured - controller.speed100 / 100) > math.max(0.3, controller.speed100 / 300)) then
                status = "未达到目标速度；请检查兼容日志";
            else status = "目标 x" .. speedText(controller.speed100) .. " / 已获得实测"; end
        end
    end
    local measurement = "实测：等待连续单人战斗 3 秒";
    if (controller.measured) then
        measurement = "实测约 x" .. string.format("%.2f", controller.measured) .. "（游戏计时 / 真实时间）";
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
        if (noticeLabel) then noticeLabel:SetText("正在切换，请以实测倍率为准"); end
    else
        if (noticeLabel) then noticeLabel:SetText("仅单人战斗可调速；请输入 0.25–10"); end
    end
    render();
end

local function emergencyStop()
    local sent = controller:EmergencyStop();
    if (noticeLabel) then
        if (sent) then noticeLabel:SetText("已发送 1 倍请求；等待实测确认");
        else noticeLabel:SetText("无法写入 1 倍请求；请退出游戏恢复"); end
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
    label:SetWidth(370);
    label:SetHeight(18);
    label:SetJustifyH("LEFT");
    label:SetText(text);
    return label;
end

local function addButton(parent, name, text, x, y, width, callback)
    local button = CreateFrame("Button", name, parent, "UIPanelButtonTemplate");
    button:SetWidth(width);
    button:SetHeight(26);
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    button:SetText(text);
    button:SetScript("OnClick", callback);
    return button;
end

local function buildPanel()
    if (panel or type(CreateFrame) ~= "function" or not UIParent) then return; end
    panel = CreateFrame("Frame", "AZSSpeedGearPanel", UIParent);
    panel:SetWidth(400);
    panel:SetHeight(276);
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
    panel:SetFrameStrata("DIALOG");
    panel:SetMovable(true);
    panel:EnableMouse(true);
    panel:RegisterForDrag("LeftButton");
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
    addText(panel, 14, 16, -16, "艾泽拉斯 · 变速齿轮");
    addButton(panel, "AZSSpeedGearClose", "关闭", 332, -10, 52, function() setShown(false); end);
    statusLabel = addText(panel, 12, 16, -48, "准备状态检测…");
    measurementLabel = addText(panel, 11, 16, -72, "实测：等待连续单人战斗 3 秒");
    local presets = { 50, 100, 200, 300, 500 };
    local i = 1;
    while (i <= table.getn(presets)) do
        local selected = presets[i];
        addButton(panel, "AZSSpeedGearPreset" .. i, "x" .. speedText(selected), 16 + (i - 1) * 74, -103, 66,
            function() requestSpeed(selected); end);
        i = i + 1;
    end
    addText(panel, 11, 16, -148, "自定义倍速（0.25–10）：");
    customBox = CreateFrame("EditBox", "AZSSpeedGearCustom", panel, "InputBoxTemplate");
    customBox:SetWidth(70);
    customBox:SetHeight(26);
    customBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 196, -138);
    customBox:SetAutoFocus(false);
    customBox:SetMaxLetters(6);
    customBox:SetText("1");
    local function submitCustom()
        local number = tonumber(customBox:GetText());
        if (finiteNumber(number)) then requestSpeed(number * 100);
        else noticeLabel:SetText("请输入 0.25–10 之间的数字"); end
        customBox:ClearFocus();
    end
    customBox:SetScript("OnEnterPressed", submitCustom);
    customBox:SetScript("OnEscapePressed", function() this:ClearFocus(); end);
    addButton(panel, "AZSSpeedGearApply", "请求", 284, -138, 84, submitCustom);
    addButton(panel, "AZSSpeedGearStop", "急停：恢复 1 倍", 16, -181, 352, emergencyStop);
    noticeLabel = addText(panel, 11, 16, -221, "需要原生后端；隐藏面板不会停止控制");
    addText(panel, 10, 16, -246, "/azsg 显示/隐藏 · /azsg stop 恢复 1 倍");
    Gear.panel = panel;
end

local function loadSettings()
    local db = savedDatabase();
    dbReady = true;
    buildPanel();
    if (panel and finiteNumber(db.x) and finiteNumber(db.y) and type(db.point) == "string" and type(db.relativePoint) == "string") then
        local points = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true };
        if (points[db.point] and points[db.relativePoint] and math.abs(db.x) < 10000 and math.abs(db.y) < 10000) then
            panel:ClearAllPoints();
            panel:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y);
        end
    end
    setShown(db.show);
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
    else chat("/azsg show | hide | stop | 0.25–10；暂停、选卡、离局及联机会请求恢复 1 倍。"); end
end

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
            controller:Shutdown();
        elseif (event == "ADDON_LOADED") then
            if (arg1 == "AZSSpeedGear") then loadSettings(); end
        elseif (event == "PLAYER_ENTERING_WORLD") then
            worldActive = true;
            if (not dbReady) then loadSettings(); end
            controller:Update();
            render();
        end
    end);
    driver:SetScript("OnUpdate", function()
        if (dbReady) then controller:Update(); render(); end
    end);
    Gear.driver = driver;
end

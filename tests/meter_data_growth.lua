-- Remote stock Lua 5.0 only. Supply the pinned/repaired actual SpellMeter
-- source. Count real production sorting work rather than guessing game FPS.
assert(arg and arg[1], "usage: lua50 tests/meter_data_growth.lua /pinned/meter.lua");
assert(debug and debug.getupvalue and debug.setupvalue, "remote debug seam required");

local frames, clock, lines, nativeTotal = {}, 1000, {}, 0;
local sortCalls, comparisons, sortedRows, observing = 0, 0, 0, false;
local originalSort = table.sort;
table.sort = function(list, less)
    if (not observing) then return originalSort(list, less); end
    sortCalls = sortCalls + 1; sortedRows = sortedRows + table.getn(list);
    if (less) then
        return originalSort(list, function(left, right)
            comparisons = comparisons + 1; return less(left, right);
        end);
    end
    return originalSort(list);
end;

local function widget(name)
    local value = { name=name, shown=true, scripts={}, width=394, height=241, text="" };
    function value:RegisterEvent() end
    function value:SetScript(key, callback) self.scripts[key] = callback; end
    function value:IsShown() return self.shown; end
    function value:Show() self.shown = true; end
    function value:Hide() self.shown = false; end
    function value:SetText(text) self.text = text; end
    function value:GetText() return self.text; end
    function value:GetWidth() return self.width; end
    function value:GetHeight() return self.height; end
    function value:SetWidth(width) self.width = width; end
    function value:SetHeight(height) self.height = height; end
    function value:GetStringWidth() return string.len(self.text or "") * 6; end
    local _, key;
    for _, key in ipairs({"ClearAllPoints","SetPoint","SetTextColor","SetTexture","SetTexCoord","SetVertexColor"}) do
        value[key] = function() end;
    end
    return value;
end
UIParent = widget("UIParent"); SlashCmdList = {};
CreateFrame = function(kind, name) local result = widget(name); if (name) then frames[name] = result; end; return result; end;
GetTime = function() return clock; end;
AZS_GetRunTime = function() return clock - 1000; end;
AZS_GetMeter = function() return lines, nativeTotal, 0; end;
UnitName = function() return "FixturePlayer"; end;
AZSSpellMeterDB = {mini=true, shown=true, view="damage", viewChosen=true, look={flat=true}};
dofile(arg[1]);

local function upvalue(callback, key, value, replace)
    local index = 1;
    while (true) do
        local found, current = debug.getupvalue(callback, index);
        if (not found) then error("production seam missing upvalue: " .. key); end
        if (found == key) then if (replace) then debug.setupvalue(callback,index,value); end; return current; end
        index = index + 1;
    end
end
local driver = assert(frames.AZSSpellMeterDriver);
local refresh = upvalue(driver.scripts.OnUpdate,"refresh");
local createUI = upvalue(driver.scripts.OnEvent,"createUI");
local buildList = upvalue(createUI,"buildMainList");
local bubbleUpdate = upvalue(buildList,"onBubbleUpdate");
local refreshWindow = upvalue(refresh,"refreshWindow");
local rebuild = upvalue(refreshWindow,"rebuild");
local recentRate = upvalue(rebuild,"recentRate");
local main = widget("main"); main.shown = false;
main.totalText,main.dpsText,main.countText,main.bubbleText = widget(),widget(),widget(),widget();
main.rows = {}; for index=1,25 do main.rows[index]=widget(); end
local bubble = widget("bubble"); bubble.parked=true; bubble.moving=false;
upvalue(refresh,"frame",main,true); upvalue(bubbleUpdate,"bubble",bubble,true);
upvalue(refresh,"state",{spells={},total=0,elapsed=0,kills=0},true);
upvalue(refresh,"watchRun",function() end,true);
upvalue(refresh,"noteDeath",function() end,true);
upvalue(refresh,"hideStockMeter",function() end,true);
local failures, checks = {},0;
local function check(condition,message)
    checks=checks+1; if(not condition) then table.insert(failures,message); print("FAIL: "..message); end
end
local function tick(count,rate)
    observing=true;
    for index=1,count do arg1=rate/60; clock=clock+arg1; bubbleUpdate(); end
    observing=false;
end
local measurements = {};
for _, count in ipairs({8,64,256}) do
    lines={}; nativeTotal=0;
    -- Deliberately scrambled distinct spell rows; no proc-folding assumption.
    for index=1,count do
        local damage=100+math.mod(index*73,count);
        lines[index]={name="FixtureSpell"..index,dmg=damage,dps=damage/10,proc=0,
            icon="Interface\\Icons\\Spell_Holy_Smite"};
        nativeTotal=nativeTotal+damage;
    end
    upvalue(recentRate,"rateHist",{},true);
    sortCalls,comparisons,sortedRows=0,0,0;
    tick(600,3); -- ten physical fixture seconds, thirty game seconds.
    measurements[table.getn(measurements)+1]={rows=count,sorts=sortCalls,comparisons=comparisons,sortedRows=sortedRows};
    print(string.format("MINI_DATA rows=%d sorts=%d comparisons=%d sorted_row_visits=%d",count,sortCalls,comparisons,sortedRows));
    check(sortCalls==0 and comparisons==0 and sortedRows==0,
        "collapsed statistics must not sort or rank hidden presentation rows at size "..count);
    local history=upvalue(recentRate,"rateHist").damage;
    local samples=history and table.getn(history) or 0;
    local last=history and history[samples];
    check(samples>=25 and samples<=42 and last and last.total==nativeTotal,
        "collapsed data-only work retains bounded native aggregate history at size "..count);
    check(last and last.spells.FixtureSpell1==lines[1].dmg
        and last.spells["FixtureSpell"..count]==lines[count].dmg,
        "collapsed sampling preserves per-spell history at size "..count);
    local formatted = nativeTotal>=10000 and string.format("%.1fk",nativeTotal/1000) or tostring(nativeTotal);
    check(main.bubbleText.text==formatted,"collapsed bubble keeps exact production aggregate formatting at size "..count);
end

-- A fresh aggregate must replace old data without retaining the previous row
-- population in the latest snapshot, while recent-window history stays bounded.
lines={{name="FreshSpell",dmg=777,dps=77.7,proc=0,icon="Interface\\Icons\\Spell_Holy_Smite"}}; nativeTotal=777;
tick(60,1);
local history=upvalue(recentRate,"rateHist").damage;
local latest=history[table.getn(history)];
check(latest.total==777 and latest.spells.FreshSpell==777 and latest.spells.FixtureSpell1==nil,
    "new snapshots contain current native rows without stale presentation data");

-- The same real closure must still produce ranks for a visible window.
lines={}; nativeTotal=0;
for index=1,8 do lines[index]={name="Visible"..index,dmg=index*100,dps=index*10,proc=0,icon="Interface\\Icons\\Spell_Holy_Smite"}; nativeTotal=nativeTotal+index*100; end
main.shown=true; sortCalls,comparisons,sortedRows=0,0,0;
observing=true; rebuild("damage"); observing=false;
local sorted=upvalue(rebuild,"sorted");
check(sortCalls>0 and comparisons>0 and table.getn(sorted)==8 and sorted[1].name=="Visible8" and sorted[1].rank==1,
    "visible presentation still sorts and ranks the current rows");
print("SEAM LIMIT: real Lua source closures with injected native meter rows; operation counts and history correctness, not whole-game FPS or a sole-cause verdict.");
print("Meter data-growth checks="..checks.." failures="..table.getn(failures));
assert(table.getn(failures)==0,table.concat(failures,"; "));

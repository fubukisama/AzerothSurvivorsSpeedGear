-- Remote Lua 5.0 operation regression using the complete pinned installed
-- DamageText.lua closures. Native widgets are stubs; this is not a game FPS test.
assert(os.getenv("GITHUB_ACTIONS") == "true", "remote CI fixture only");
assert(arg and arg[1], "usage: lua50 tests/keijin_width_cache.lua /pinned/DamageText.lua");
assert(debug and debug.getupvalue, "stock remote Lua debug API required");
local frames, checks, failures = {}, 0, {};
local widthCalls, textReads, fontReads, fontWrites = 0, 0, 0, 0;
local db = {combatTextMode="scroll",combatTextPosition="fixed",combatTextIcons=false};
local function nativeWidth(fs)
    return string.len(fs.text)*fs.fontSize*(fs.font=="AlternateFont" and .75 or .6);
end
local function widget(name)
    local self={name=name,scripts={},text="",font="FixtureFont",fontSize=12,width=200,height=120,left=300,bottom=200,scale=1,shown=true};
    function self:SetScript(event,fn) self.scripts[event]=fn; end
    function self:RegisterEvent() end
    function self:SetFrameStrata() end
    function self:EnableMouse() end
    function self:ClearAllPoints() end
    function self:SetPoint(...) self.point=arg; end
    function self:SetTextColor() end
    function self:SetTexture() end
    function self:SetTexCoord() end
    function self:SetAlpha(value) self.alpha=value; end
    function self:GetAlpha() return self.alpha or 1; end
    function self:SetWidth(value) self.width=value; end
    function self:SetHeight(value) self.height=value; end
    function self:GetWidth() return self.width; end
    function self:GetHeight() return self.height; end
    function self:GetLeft() return self.left; end
    function self:GetBottom() return self.bottom; end
    function self:GetRight() return self.left+self.width; end
    function self:GetTop() return self.bottom+self.height; end
    function self:GetEffectiveScale() return self.scale; end
    function self:IsShown() return self.shown; end
    function self:Show() self.shown=true; end
    function self:Hide() self.shown=false; end
    function self:SetText(text) self.text=text; end
    function self:GetText() textReads=textReads+1; return self.text; end
    function self:SetFont(face,size,flags) fontWrites=fontWrites+1; self.font=face;self.fontSize=size;self.flags=flags; end
    function self:GetFont() fontReads=fontReads+1; return self.font,self.fontSize,self.flags; end
    function self:GetStringWidth()
        widthCalls=widthCalls+1;
        if self.widthOverride~=nil then return self.widthOverride; end
        return nativeWidth(self);
    end
    function self:CreateFontString() return widget("font"); end
    function self:CreateTexture() return widget("texture"); end
    return self;
end
UIParent=widget("UIParent");
CreateFrame=function(kind,name) local f=widget(name); if name then frames[name]=f; end;return f; end;
getglobal=function(name) return frames[name]; end;
KeijinUI={font="FixtureFont",tools={CombatEvents={}},layout={}};
local K=KeijinUI;
K.DB=function() return db; end;
K.Number=function(n) return type(n)=="number" and n==n and n>-1e100 and n<1e100; end;
K.UIWidth=function() return 1920; end; K.UIHeight=function() return 1080; end;
K.CombatTextMode=function() return db.combatTextMode; end;
K.SpellIcon=function() return "FixtureIcon"; end;
K.T=function(text) return text; end;
K.On=function() end;
K.layout.Register=function(key,frame,title,init) init(frame); end;
K.layout.Place=function() end;
math.randomseed(7);
dofile(arg[1]);
local function upvalue(fn,wanted)
    local i=1;
    while true do
        local name,value=debug.getupvalue(fn,i);
        if not name then error("production seam missing: "..wanted); end;
        if name==wanted then return value; end;
        i=i+1;
    end
end
local Add=upvalue(K.damageText.Spawn,"Add");
local Place=upvalue(Add,"Place");
local Footprint=upvalue(Place,"Footprint");
local SetSize=upvalue(Add,"SetSize");
local driver=assert(frames.KeijinUIDamageText,"production animation host");
local function check(okay,description)
    checks=checks+1;
    if not okay then table.insert(failures,description);print("FAIL: "..description); end
end
local function close(a,b) return type(a)=="number" and a==a and math.abs(a-b)<.0001; end
local function tick(count,dt)
    for i=1,count do arg1=dt;driver.scripts.OnUpdate();end
end
local function one() return assert(K.damageText.active[1],"active production item"); end
local function stop() K.damageText.Stop();end
local function spawn(amount,crit,spell)
    K.damageText.Spawn(amount,crit,"Target","Fire",false,spell or "FixtureSpell");return one();
end

local item=spawn(100,false);
local initialHalf=item.halfWidth;
local beforeWidth,beforeText,beforeFont=widthCalls,textReads,fontReads;
tick(100,.001);
print(string.format("KEIJIN steady_frames=100 width_reads=%d text_reads=%d font_reads=%d",widthCalls-beforeWidth,textReads-beforeText,fontReads-beforeFont));
check(widthCalls==beforeWidth,"unchanged live label must not measure width every animation frame");
check(textReads==beforeText and fontReads==beforeFont,"cache hits must not substitute extra native text/font reads");
check(close(item.halfWidth,initialHalf),"steady animation retains original footprint geometry");
check(close(item.halfWidth,nativeWidth(item.fs)/2+4),"normal footprint reflects actual text and font");
beforeWidth=widthCalls;
spawn(200,false);
check(table.getn(K.damageText.active)==1 and item.amount==300 and item.hits==2,"production merge retains accumulated amount and item");
check(item.fs.text=="300 x2" and item.halfWidth>initialHalf,"merged text immediately grows its footprint");
check(widthCalls==beforeWidth+1,"merged text is measured once after it changes");
beforeWidth=widthCalls;tick(10,.001);
check(widthCalls==beforeWidth,"merged label returns to measurement-free animation");

stop();item=spawn(123,true);beforeWidth=widthCalls;local beforeWrites=fontWrites;
tick(300,.001);
check(fontWrites>beforeWrites,"production critical pop actually changes native integer font sizes");
check(widthCalls-beforeWidth<=fontWrites-beforeWrites,"critical pop measures no more than once per native font change");
local half=Footprint(item);
check(close(half,string.len(item.fs.text)*item.style.size*2*.6/2+4),"critical footprint reserves its largest pop size");
beforeWidth=widthCalls;tick(100,.001);
check(widthCalls==beforeWidth,"settled pop stops width measurement");

item.scale=1.5;SetSize(item,item.size);beforeWidth=widthCalls;Footprint(item);Footprint(item);
check(widthCalls==beforeWidth+1,"anchor scale change invalidates once");
K.damageText.SetTextSize(1.5);SetSize(item,item.size);beforeWidth=widthCalls;Footprint(item);Footprint(item);
check(widthCalls==beforeWidth+1,"text-size setting invalidates once");
local beforeFace=Footprint(item);
K.font="AlternateFont";SetSize(item,item.size);beforeWidth=widthCalls;local afterFace=Footprint(item);Footprint(item);
check(widthCalls==beforeWidth+1,"font face change invalidates once");
check(afterFace>beforeFace,"a different native font width changes the collision footprint");
stop();K.damageText.SetTextSize(1);item=spawn(7,false);
check(item.fs.text=="7" and close(item.halfWidth,nativeWidth(item.fs)/2+4),"pooled font string does not reuse the previous item's width");

local function invalidate() SetSize(item,item.size+1); end
item.fs.widthOverride=0;invalidate();beforeWidth=widthCalls;
local fallback=Footprint(item);Footprint(item);
check(K.Number(fallback) and fallback>0,"unavailable zero-width result uses a finite fallback");
check(widthCalls==beforeWidth+2,"unavailable measurements are retried rather than cached");
item.fs.widthOverride=nil;beforeWidth=widthCalls;Footprint(item);Footprint(item);
check(widthCalls==beforeWidth+1,"a later valid width recovers and is cached");
item.fs.widthOverride=0/0;invalidate();fallback=Footprint(item);
check(K.Number(fallback) and fallback>0,"NaN measurement uses a finite fallback");
item.fs.widthOverride=1/0;invalidate();fallback=Footprint(item);
check(K.Number(fallback) and fallback>0,"infinite measurement uses a finite fallback");
item.fs.widthOverride=nil;
local method=item.fs.GetStringWidth;item.fs.GetStringWidth=nil;invalidate();fallback=Footprint(item);
check(K.Number(fallback) and fallback>0,"a host without GetStringWidth retains a finite footprint");
item.fs.GetStringWidth=method;beforeWidth=widthCalls;Footprint(item);Footprint(item);
check(widthCalls==beforeWidth+1,"a restored width API recovers without another text mutation");
stop();check(table.getn(K.damageText.active)==0,"normal stop still clears all live labels");

-- Optional display-only reduction is owned by the enabled SpeedGear addon.
-- Native damage/statistics and the source's merge window are not changed.
AZSSpeedGear={lightweightCombatText=false};db.combatTextMerge=false;
for i=1,65 do spawn(100+i,true,"default-limit-"..i);end
check(table.getn(K.damageText.active)==60,"default mode retains the existing sixty-label bound");
item=K.damageText.active[table.getn(K.damageText.active)];
check(item.pop==true and item.size<item.style.size,"default critical labels retain the original pop");
AZSSpeedGear.lightweightCombatText=true;
spawn(999,true,"light-limit");
check(table.getn(K.damageText.active)==24,"enabling lightweight mode trims an existing larger pool on the next spawn");
item=K.damageText.active[table.getn(K.damageText.active)];
check(not item.pop and item.size==item.style.size,"new lightweight critical labels use the fixed original style size");
stop();AZSSpeedGear.lightweightCombatText=false;
local protected=spawn(123,true,"keep-critical");
for i=1,59 do spawn(i,false,"ordinary-"..i);end
AZSSpeedGear.lightweightCombatText=true;spawn(999,false,"new-ordinary");
local kept=false;
for _,live in ipairs(K.damageText.active) do if live==protected then kept=true;end;end
check(table.getn(K.damageText.active)==24 and kept,"lightweight trimming preserves fixed-mode critical-hit eviction priority");
stop();db.combatTextMerge=true;
item=spawn(100,true,"light-merge");spawn(200,true,"light-merge");
check(table.getn(K.damageText.active)==1 and item.amount==300 and item.hits==2,"lightweight mode preserves damage merging and accumulated amounts");
check(not item.pop and item.fs.text=="300 x2","lightweight merged critical label retains correct text without pop");
beforeWidth=widthCalls;tick(100,.001);
check(widthCalls==beforeWidth,"lightweight merged text also uses the width cache");
AZSSpeedGear.lightweightCombatText=false;
spawn(400,true,"restored-pop");
local restored=K.damageText.active[table.getn(K.damageText.active)];
check(restored.pop==true and not item.pop,"disabling lightweight mode restores new-label pop without changing existing labels");
stop();db.combatTextMerge=false;
for i=1,65 do spawn(i,true,"restored-limit-"..i);end
check(table.getn(K.damageText.active)==60,"disabling lightweight mode restores the original sixty-label limit");
stop();AZSSpeedGear=nil;
for i=1,65 do spawn(i,true,"no-speedgear-"..i);end
item=K.damageText.active[table.getn(K.damageText.active)];
check(table.getn(K.damageText.active)==60 and item.pop==true,"without SpeedGear the original visual behavior remains active");
stop();AZSSpeedGear={lightweightCombatText="true"};
for i=1,25 do spawn(i,true,"strict-bool-"..i);end
item=K.damageText.active[table.getn(K.damageText.active)];
check(table.getn(K.damageText.active)==25 and item.pop==true,"only an explicit boolean true enables lightweight mode");
stop();AZSSpeedGear=nil;

print(string.format("Keijin width cache: %d checks, %d failures",checks,table.getn(failures)));
if table.getn(failures)>0 then os.exit(1);end

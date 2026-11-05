-- Full pinned DamageText.lua closures, not a replacement implementation.
assert(os.getenv("GITHUB_ACTIONS") == "true", "remote CI only");
assert(arg and arg[1], "pinned source required");
local frames,callbacks={},{};
local writes,places,widths=0,0,0;
local function widget(name)
    local f={name=name,scripts={},shown=true,text="",size=12,scale=1,left=100,bottom=100,width=80,height=25};
    function f:SetScript(key,fn) self.scripts[key]=fn; end
    function f:RegisterEvent() end
    function f:SetFrameStrata() end
    function f:EnableMouse() end
    function f:ClearAllPoints() end
    function f:SetPoint(point,relative,relativePoint,x,y) self.x=x;self.y=y;if self.fontString then places=places+1 end end
    function f:SetText(v) self.text=v;writes=writes+1; end
    function f:GetText() return self.text; end
    function f:SetFont(face,size,flags) self.face=face;self.size=size;end
    function f:GetStringWidth() widths=widths+1;return string.len(self.text)*self.size*.6 end
    function f:SetTextColor() end
    function f:SetAlpha(v) self.alpha=v end
    function f:GetAlpha() return self.alpha or 1 end
    function f:Show() self.shown=true end
    function f:Hide() self.shown=false end
    function f:IsShown() return self.shown end
    function f:SetWidth(v) self.width=v end
    function f:SetHeight(v) self.height=v end
    function f:GetWidth() return self.width end
    function f:GetHeight() return self.height end
    function f:GetLeft() return self.left end
    function f:GetBottom() return self.bottom end
    function f:GetRight() return self.left+self.width end
    function f:GetTop() return self.bottom+self.height end
    function f:GetEffectiveScale() return self.scale end
    function f:SetTexture() end
    function f:SetTexCoord() end
    function f:CreateFontString() local child=widget("font");child.fontString=true;return child end
    function f:CreateTexture() return widget("icon") end
    return f
end
UIParent=widget("UIParent");
CreateFrame=function(kind,name) local f=widget(name);if name then frames[name]=f end;return f end;
getglobal=function(name) return frames[name] end;
local db={combatTextMode="scroll",combatTextPosition="fixed",combatTextMerge=true,combatTextIcons=false};
KeijinUI={font="Fixture",tools={CombatEvents={}},layout={},units={}};
local K=KeijinUI;
K.DB=function() return db end;
K.Number=function(x) return type(x)=="number" and x==x and x>-1e100 and x<1e100 end;
K.UIWidth=function() return 1920 end;K.UIHeight=function() return 1080 end;
K.CombatTextMode=function() return db.combatTextMode end;
K.SpellIcon=function() return "icon" end;K.T=function(s) return s end;
K.On=function(event,fn) callbacks[event]=fn end;
K.layout.Register=function(key,f,title,init) init(f) end;K.layout.Place=function() end;
local plateCalls=0;
K.PlateAnchor=function(name) plateCalls=plateCalls+1;return 700,500 end;
dofile(arg[1]);
local driver=frames.KeijinUIDamageText;
local function up(fn,key)
    local i=1;while true do local n,v=debug.getupvalue(fn,i);if not n then error("missing seam: "..key) end;if n==key then return v end;i=i+1 end
end
local Rectangles=up(K.damageText.KeepClear,"Rectangles");
local failures,checks={},0;
local function check(okay,why) checks=checks+1;if not okay then table.insert(failures,why);print("FAIL: "..why) end end
local function tick(dt) arg1=dt or 0;driver.scripts.OnUpdate() end
local function hit(n,target,spell,crit) K.damageText.Spawn(n,crit or false,target or "Target","Fire",false,spell or "Fire") end
K.units.player=widget("player");
local r1=Rectangles();local row=r1[1];local r2=Rectangles();
check(r1==r2 and row==r2[1], "rectangle list and rows are borrowed reusable buffers");
K.units.player.left=230;Rectangles();
check(r1[1][1]==230, "reused geometry reads current frame bounds");
K.units.player:Hide();local empty=Rectangles();
check(table.getn(empty)==0, "a hidden obstacle leaves no stale active rectangle");
K.units.player:Show();
-- Force actual nameplate-anchor work as well as all six protected rectangles.
K.units.target=widget("target");
for _,name in ipairs({"KeijinUISkills","KeijinUITally","KeijinUIResources","KeijinUIStoredLevels"}) do frames[name]=widget(name) end
db.combatTextPosition="plate";hit(100);for i=1,10 do tick(0) end
collectgarbage();collectgarbage(65536);
local before=gcinfo();
for i=1,2000 do tick(0) end
local growth=gcinfo()-before;collectgarbage();
print(string.format("KEIJIN_LAYOUT updates=2000 allocator_growth_kb=%.0f",growth));
check(growth<32, "steady animation does not allocate layout or anchor tables every update");
K.damageText.Stop();db.combatTextPosition="fixed";
writes,places,widths=0,0,0;
for i=1,100 do hit(1) end
local item=K.damageText.active[1];
check(item.amount==100 and item.hits==100, "all burst damage is accounted before painting");
check(writes==0 and places==0 and not item.fs.shown, "a burst queues its first presentation without native text or position writes");
tick(0);
print(string.format("KEIJIN_BURST hits=100 text_writes=%d position_writes=%d width_reads=%d",writes,places,widths));
check(writes==1 and places==1 and widths==1, "a burst commits one final text, position and width per label");
check(item.fs.text=="100 x100" and item.fs.shown, "the committed label displays the full burst");
writes,places,widths=0,0,0;
for i=1,40 do hit(2) end
check(item.amount==180 and item.hits==140 and writes==0, "later burst accounting remains immediate");
tick(.01);
check(writes==1 and places==1 and item.fs.text=="180 x140", "the next callback commits only the new aggregate");
writes=0;tick(.01);check(writes==0, "unchanged text is not rewritten on animation-only updates");
K.damageText.Stop();hit(7);item=K.damageText.active[1];tick(2);
check(item.fs.shown and table.getn(K.damageText.active)==1, "a new queued label gets its first presentation even after a long frame");
tick(2);check(table.getn(K.damageText.active)==0, "presented labels still expire normally");
hit(99);local cancelled=K.damageText.active[1];K.damageText.Stop();tick(0);
check(not cancelled.fs.shown and table.getn(K.damageText.active)==0, "stop cancels pending labels without ghost painting");
hit(3,"A");hit(4,"B","Other");tick(0);
check(table.getn(K.damageText.active)==2, "unrelated abilities keep separate labels");
K.damageText.Stop();
print(string.format("Keijin frame work: %d checks, %d failures",checks,table.getn(failures)));
if table.getn(failures)>0 then os.exit(1) end

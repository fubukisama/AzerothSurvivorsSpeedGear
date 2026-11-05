#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Game')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Game')][string]$GamePath,
    [Parameter(Mandatory=$true,ParameterSetName='Source')][string]$SourcePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$originalSHA='16d058315a36f1dd48be8240c5b776924a3901b0ab80ae62b39f697bedd3f141'
$previousSHA='c38f46e994a6d60632bedd3c29408d4f5d2bef423435c58f6800d793e7fd651b'
$repairedSHA='41205f0dc3deff529cd5571358a820152cc9ef6918ee93d0aefc69a7f2bc1456'
$sourceVersion='4.6.1-damageonly.1'
$utf8=New-Object Text.UTF8Encoding($false,$true)
function Get-SHA256([byte[]]$Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Assert-NoLinks([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrEmpty($cursor)) {
        if(Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked repair paths are refused.' }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent -eq $cursor) { break }
        $cursor=$parent
    }
}
function Assert-Within([string]$Path,[string]$Root) {
    if(-not $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Repair path is outside the selected directory.' }
}
function Write-NewFile([string]$Path,[byte[]]$Bytes) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true) }
    finally { $stream.Dispose() }
}
if($PSCmdlet.ParameterSetName -eq 'Source') {
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') { throw '-SourcePath is restricted to disposable Windows GitHub Actions fixtures.' }
    $target=[IO.Path]::GetFullPath($SourcePath)
    $inside=$false
    foreach($root in @($env:GITHUB_WORKSPACE,$env:RUNNER_TEMP)) {
        if(-not [string]::IsNullOrWhiteSpace($root) -and
           $target.StartsWith([IO.Path]::GetFullPath($root).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $inside=$true }
    }
    if(-not $inside) { throw 'CI fixture must be inside GITHUB_WORKSPACE or RUNNER_TEMP.' }
    $backupBase=Join-Path ([IO.Path]::GetDirectoryName($target)) 'AZSSpeedGearKeijinBackups'
} else {
    $gameExe=[IO.Path]::GetFullPath($GamePath)
    Assert-NoLinks $gameExe
    if([IO.Path]::GetFileName($gameExe) -ine 'AzerothSurvivors.exe' -or -not (Test-Path -LiteralPath $gameExe -PathType Leaf)) { throw '-GamePath must identify the installed AzerothSurvivors.exe.' }
    foreach($process in @(Get-CimInstance Win32_Process -Filter "Name = 'AzerothSurvivors.exe'")) {
        if([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or [IO.Path]::GetFullPath([string]$process.ExecutablePath) -ieq $gameExe) { throw 'Exit the selected game normally before repairing KeijinUI.' }
    }
    $gameRoot=[IO.Path]::GetDirectoryName($gameExe)
    $addonRoot=Join-Path $gameRoot 'benilla-config\AddOns\KeijinUI'
    $target=Join-Path $addonRoot 'DamageText.lua'
    $toc=Join-Path $addonRoot 'KeijinUI.toc'
    Assert-NoLinks $toc
    if(-not (Test-Path -LiteralPath $toc -PathType Leaf)) { throw 'KeijinUI TOC is missing.' }
    $versions=@([IO.File]::ReadAllLines($toc) | Where-Object { $_ -match '^##\s*Version\s*:' })
    if($versions.Count -ne 1 -or ($versions[0] -replace '^##\s*Version\s*:\s*','').Trim() -cne $sourceVersion) { throw 'Only the pinned KeijinUI damage-only 4.6.1 integration can be repaired.' }
    $backupBase=Join-Path $gameRoot 'benilla-config\AZSSpeedGear-backups'
    Assert-Within $target $gameRoot
    Assert-Within $backupBase $gameRoot
}
Assert-NoLinks $target
Assert-NoLinks $backupBase
if(-not (Test-Path -LiteralPath $target -PathType Leaf) -or [IO.Path]::GetExtension($target) -ine '.lua') { throw 'The selected KeijinUI source must be a regular Lua file.' }
if((Get-Item -LiteralPath $target).Length -gt 256KB) { throw 'KeijinUI source exceeds the supported size; no source was changed.' }
$originalBytes=[IO.File]::ReadAllBytes($target)
$actualSHA=Get-SHA256 $originalBytes
if($actualSHA -ceq $repairedSHA) {
    [pscustomobject]@{Changed=$false;SourcePath=$target;SourceVersion=$sourceVersion;RepairRevision=2;SHA256=$actualSHA;BackupDirectory=$null}
    return
}
if($actualSHA -cne $originalSHA -and $actualSHA -cne $previousSHA) { throw "Unsupported KeijinUI source SHA256 $actualSHA; no source was changed." }
$text=$utf8.GetString($originalBytes)

# Small source transformations only. Full third-party source and assets are not
# distributed by this project. Cache data belongs to each bounded live item.
$oldMarker='K.damageText={active=active}'
$newMarker=@'
K.damageText={active=active}
K.damageText.azsgPerformanceRevision=1
'@
$oldFont='    item.fs:SetFont(K.font,shown,"OUTLINE")'
$newFont=@'
    item.fs:SetFont(K.font,shown,"OUTLINE")
    item.azsgFontFace,item.azsgFontPixels=K.font,shown
'@
$oldGlobals='local tickRects'
$newGlobals='local tickRects,azsgUiScale'
$oldUiScale='    local ui=UIParent:GetEffectiveScale()'
$newUiScale=@'
    local ui=UIParent:GetEffectiveScale()
    azsgUiScale=ui
'@
$oldFootprint=@'
    local scale=item.scale or 1
    local size=item.style.size*scale*K.damageText.TextSize()*(item.pop and 2 or 1)
    local measured=item.fs.GetStringWidth and item.fs:GetStringWidth()
    local width=type(measured)=="number" and measured>0 and measured or string.len(item.fs:GetText() or "")*size*.65
    if type(measured)=="number" and measured>0 and item.size and item.size>0 then width=measured*size/(item.size*scale*K.damageText.TextSize()) end
'@
$newFootprint=@'
    local scale=item.scale or 1
    local textSize=K.damageText.TextSize()
    local size=item.style.size*scale*textSize*(item.pop and 2 or 1)
    local measured
    if item.azsgWidthText==item.azsgText and item.azsgWidthFont==item.azsgFontFace
        and item.azsgWidthPixels==item.azsgFontPixels and item.azsgWidthScale==scale
        and item.azsgWidthTextSize==textSize and item.azsgWidthUiScale==azsgUiScale then measured=item.azsgWidth end
    if not measured and type(item.fs.GetStringWidth)=="function" then
        local ok,value=pcall(item.fs.GetStringWidth,item.fs)
        if ok and type(value)=="number" and value==value and value>0 and value<1e100 then
            measured=value
            item.azsgWidth=value;item.azsgWidthText=item.azsgText
            item.azsgWidthFont=item.azsgFontFace;item.azsgWidthPixels=item.azsgFontPixels
            item.azsgWidthScale=scale;item.azsgWidthTextSize=textSize;item.azsgWidthUiScale=azsgUiScale
        end
    end
    local width=measured or string.len(item.azsgText or "")*size*.65
    if measured and item.size and item.size>0 then width=measured*size/(item.size*scale*textSize) end
'@
$oldAdd='local function Add(text,style,r,g,b,targetName,scroll,pop,icon)'
$newAdd=@'
local function Add(text,style,r,g,b,targetName,scroll,pop,icon)
    local lightweight=type(AZSSpeedGear)=="table" and AZSSpeedGear.lightweightCombatText==true
    local limit=lightweight and 24 or MAX
    if lightweight then pop=false end
'@
$oldLimit='    if table.getn(active)>=MAX then'
$newLimit='    while table.getn(active)>=limit do'
$oldItem='    local item={fs=fs,x=x,y=y,x0=x,y0=y,age=0,style=style,scroll=scroll,pop=pop,scale=scale,tn=targetName}'
$newItem='    local item={fs=fs,x=x,y=y,x0=x,y0=y,age=0,style=style,scroll=scroll,pop=pop,scale=scale,tn=targetName,azsgText=text}'
$oldMerge='                prior.fs:SetText(string.format("%.0f",prior.amount).." x"..prior.hits)'
$newMerge=@'
                local mergedText=string.format("%.0f",prior.amount).." x"..prior.hits
                prior.fs:SetText(mergedText);prior.azsgText=mergedText
'@
$updated=$text
if($actualSHA -ceq $originalSHA) {
foreach($pair in @(@($oldMarker,$newMarker),@($oldFont,$newFont),@($oldGlobals,$newGlobals),@($oldUiScale,$newUiScale),@($oldFootprint,$newFootprint),@($oldAdd,$newAdd),@($oldLimit,$newLimit),@($oldItem,$newItem),@($oldMerge,$newMerge))) {
    if(([regex]::Matches($updated,[regex]::Escape($pair[0]))).Count -ne 1) { throw 'Pinned source layout changed; no source was changed.' }
    $updated=$updated.Replace($pair[0],$pair[1])
}
    if((Get-SHA256 ($utf8.GetBytes($updated))) -cne $previousSHA) { throw 'First-stage Keijin identity mismatch.' }
}

# Revision 2: reuse borrowed frame buffers and coalesce presentation work.
$oldFrameWork0=@'
K.damageText={active=active}
K.damageText.azsgPerformanceRevision=1
local function Take()
    local fs=table.remove(pool)

'@
$newFrameWork0=@'
K.damageText={active=active}
K.damageText.azsgPerformanceRevision=1
K.damageText.azsgFrameWorkRevision=1
local function Take()
    local fs=table.remove(pool)

'@
$oldFrameWork1=@'
-- a frame (an enemy standing behind it) is moved up to just above its top edge, the numbers only rise.
local tickRects,azsgUiScale
local function Rectangles()
    local result={}
    local frames={K.units and K.units.player,K.units and K.units.target,
        getglobal("KeijinUISkills"),getglobal("KeijinUITally"),getglobal("KeijinUIResources"),getglobal("KeijinUIStoredLevels")}
    local ui=UIParent:GetEffectiveScale()
    azsgUiScale=ui
    for _,f in pairs(frames) do
        if f.IsShown and f:IsShown() and f.GetLeft and f:GetAlpha()>0 then
            local l,b,r,t=f:GetLeft(),f:GetBottom(),f:GetRight(),f:GetTop()
            local ratio=f:GetEffectiveScale()/ui
            if K.Number(l) and K.Number(b) and K.Number(r) and K.Number(t) then
                table.insert(result,{l*ratio,b*ratio,r*ratio,t*ratio})
            end
        end
    end
    return result
end
local function KeepClear(x,y,halfWidth,height)

'@
$newFrameWork1=@'
-- a frame (an enemy standing behind it) is moved up to just above its top edge, the numbers only rise.
local tickRects,azsgUiScale
local rectBuffer,rectPool,rectFrames={},{},{}
local rectCount=0
local anchorX,anchorY,anchorSeen={},{},{}
local function ClearAnchors()
    for name in pairs(anchorSeen) do
        anchorSeen[name]=nil;anchorX[name]=nil;anchorY[name]=nil
    end
end
local function Rectangles()
    rectFrames[1]=K.units and K.units.player;rectFrames[2]=K.units and K.units.target
    rectFrames[3]=getglobal("KeijinUISkills");rectFrames[4]=getglobal("KeijinUITally")
    rectFrames[5]=getglobal("KeijinUIResources");rectFrames[6]=getglobal("KeijinUIStoredLevels")
    local ui=UIParent:GetEffectiveScale()
    azsgUiScale=ui
    local count=0
    for index=1,6 do
        local f=rectFrames[index];rectFrames[index]=nil
        if f and f.IsShown and f:IsShown() and f.GetLeft and f:GetAlpha()>0 then
            local l,b,r,t=f:GetLeft(),f:GetBottom(),f:GetRight(),f:GetTop()
            local ratio=f:GetEffectiveScale()/ui
            if K.Number(l) and K.Number(b) and K.Number(r) and K.Number(t) then
                count=count+1
                local row=rectPool[count]
                if not row then row={};rectPool[count]=row end
                row[1],row[2],row[3],row[4]=l*ratio,b*ratio,r*ratio,t*ratio
                rectBuffer[count]=row
            end
        end
    end
    for index=count+1,rectCount do rectBuffer[index]=nil end
    rectCount=count
    return rectBuffer
end
local function KeepClear(x,y,halfWidth,height)

'@
$oldFrameWork2=@'
    if pop then size=math.floor(size*PopFactor(0)+0.5) end
    fs:SetTextColor(r,g,b)
    fs:SetText(text)
    fs:SetPoint("BOTTOM",UIParent,"BOTTOMLEFT",x,y)
    fs:SetAlpha(1); fs:Show()
    local item={fs=fs,x=x,y=y,x0=x,y0=y,age=0,style=style,scroll=scroll,pop=pop,scale=scale,tn=targetName,azsgText=text}
    if icon then
        local tex=table.remove(iconPool) or host:CreateTexture(nil,"OVERLAY")
        tex:SetTexture(icon); tex:SetTexCoord(0.08,0.92,0.08,0.92)
        tex:ClearAllPoints(); tex:SetPoint("RIGHT",fs,"LEFT",-ICON_GAP,0)
        tex:SetAlpha(1); tex:Show()
        item.icon=tex
    end

'@
$newFrameWork2=@'
    if pop then size=math.floor(size*PopFactor(0)+0.5) end
    fs:SetTextColor(r,g,b)
    fs:SetAlpha(1); fs:Hide()
    local item={fs=fs,x=x,y=y,x0=x,y0=y,age=0,style=style,scroll=scroll,pop=pop,scale=scale,tn=targetName,
        azsgText=text,azsgTextDirty=true,azsgPending=true}
    if icon then
        local tex=table.remove(iconPool) or host:CreateTexture(nil,"OVERLAY")
        tex:SetTexture(icon); tex:SetTexCoord(0.08,0.92,0.08,0.92)
        tex:ClearAllPoints(); tex:SetPoint("RIGHT",fs,"LEFT",-ICON_GAP,0)
        tex:SetAlpha(1); tex:Hide()
        item.icon=tex
    end

'@
$oldFrameWork3=@'
    end
    table.insert(active,item)
    fs:ClearAllPoints(); Place(item,x,y)
    return item
end

'@
$newFrameWork3=@'
    end
    table.insert(active,item)
    return item
end

'@
$oldFrameWork4=@'
    if mode=="off" or mode=="native" or not K.Number(amount) or amount<=0 then return end
    if K.damageText.list and K.damageText.list.On() then return K.damageText.list.PushDamage(amount,crit,targetName,school,periodic,spell) end
    local text=string.format("%.0f",amount)
    -- Merge a short burst of the same ability/kind, including area hits on
    -- several enemies. Critical and ordinary hits always stay separate.

'@
$newFrameWork4=@'
    if mode=="off" or mode=="native" or not K.Number(amount) or amount<=0 then return end
    if K.damageText.list and K.damageText.list.On() then return K.damageText.list.PushDamage(amount,crit,targetName,school,periodic,spell) end
    -- Merge a short burst of the same ability/kind, including area hits on
    -- several enemies. Critical and ordinary hits always stay separate.

'@
$oldFrameWork5=@'
        for i=table.getn(active),1,-1 do
            local prior=active[i]
            if prior.mergeKey==mergeKey and prior.age<=0.12 then
                prior.amount=prior.amount+amount; prior.hits=(prior.hits or 1)+1
                local mergedText=string.format("%.0f",prior.amount).." x"..prior.hits
                prior.fs:SetText(mergedText);prior.azsgText=mergedText
                if prior.targetName~=targetName then prior.name=nil end
                prior.fs:ClearAllPoints(); Place(prior,prior.screenX or prior.x,prior.screenY or prior.y)
                return
            end
        end
    end
    local small
    if (mode=="scroll" or mode=="rise") and not crit and not periodic then

'@
$newFrameWork5=@'
        for i=table.getn(active),1,-1 do
            local prior=active[i]
            if prior.mergeKey==mergeKey and prior.age<=0.12 and not prior.azsgRetire then
                prior.amount=prior.amount+amount; prior.hits=(prior.hits or 1)+1
                prior.azsgTextDirty=true
                if prior.targetName~=targetName then prior.name=nil end
                return
            end
        end
    end
    local text=string.format("%.0f",amount)
    local small
    if (mode=="scroll" or mode=="rise") and not crit and not periodic then

'@
$oldFrameWork6=@'
    local dt=tonumber(arg1) or 0
    tickRects=Rectangles()
    local anchors={}   -- plate anchor per name, asked once per tick
    local i=1
    while i<=table.getn(active) do
        local item=active[i]
        item.age=item.age+dt
        local s=item.style
        local life=s.life
        if item.age>=life then Give(table.remove(active,i))
        else
            local t=item.age/life
            item.fs:ClearAllPoints()
            if item.scroll then
                if item.name then
                    local a=anchors[item.name]
                    if a==nil then
                        local ax,ay=K.PlateAnchor(item.name)
                        a=ax and {ax,ay} or false; anchors[item.name]=a
                    end
                    if a then
                        local dx,dy=a[1]-item.ax,a[2]-item.ay
                        if dx*dx+dy*dy<=FOLLOW_JUMP*FOLLOW_JUMP then
                            item.ax,item.ay=a[1],a[2]
                            item.x0,item.y0=a[1]+item.ox,a[2]+item.oy
                        end
                    end

'@
$newFrameWork6=@'
    local dt=tonumber(arg1) or 0
    tickRects=Rectangles()
    ClearAnchors()
    local i=1
    while i<=table.getn(active) do
        local item=active[i]
        local previousAge=item.age
        if item.azsgPending then item.azsgPending=nil
        else item.age=item.age+dt end
        local s=item.style
        local life=s.life
        if item.azsgRetire or (item.age>=life and not item.azsgTextDirty) then Give(table.remove(active,i))
        else
            -- A hitch must not discard a fresh aggregate before its one final
            -- presentation. It is ineligible for further merging and retires
            -- on the next callback, so this does not grow the active pool.
            if item.age>=life then item.age=previousAge;item.azsgRetire=true end
            if item.azsgTextDirty then
                local text=item.azsgText
                if item.hits and item.hits>1 then text=string.format("%.0f",item.amount).." x"..item.hits end
                item.fs:SetText(text);item.azsgText=text;item.azsgTextDirty=nil
            end
            local t=item.age/life
            item.fs:ClearAllPoints()
            if item.scroll then
                if item.name then
                    if not anchorSeen[item.name] then
                        local ax,ay=K.PlateAnchor(item.name)
                        anchorSeen[item.name]=true;anchorX[item.name]=ax;anchorY[item.name]=ay
                    end
                    local ax,ay=anchorX[item.name],anchorY[item.name]
                    if ax then
                        local dx,dy=ax-item.ax,ay-item.ay
                        if dx*dx+dy*dy<=FOLLOW_JUMP*FOLLOW_JUMP then
                            item.ax,item.ay=ax,ay
                            item.x0,item.y0=ax+item.ox,ay+item.oy
                        end
                    end

'@
$oldFrameWork7=@'
                item.fs:SetAlpha(K.damageText.Opacity(s,t))
            end
            i=i+1
        end
    end
    tickRects=nil
end)
K.On("PLAYER_ENTERING_WORLD",function() average=nil end,"combatText")

'@
$newFrameWork7=@'
                item.fs:SetAlpha(K.damageText.Opacity(s,t))
            end
            if not item.azsgPresented then
                item.fs:Show();if item.icon then item.icon:Show() end
                item.azsgPresented=true
            end
            i=i+1
        end
    end
    tickRects=nil
    ClearAnchors()
end)
K.On("PLAYER_ENTERING_WORLD",function() average=nil end,"combatText")

'@
foreach($pair in @(@($oldFrameWork0,$newFrameWork0),@($oldFrameWork1,$newFrameWork1),@($oldFrameWork2,$newFrameWork2),@($oldFrameWork3,$newFrameWork3),@($oldFrameWork4,$newFrameWork4),@($oldFrameWork5,$newFrameWork5),@($oldFrameWork6,$newFrameWork6),@($oldFrameWork7,$newFrameWork7))) {
    if(([regex]::Matches($updated,[regex]::Escape($pair[0]))).Count -ne 1) { throw 'Pinned frame-work layout changed; no source was changed.' }
    $updated=$updated.Replace($pair[0],$pair[1])
}
$updatedBytes=$utf8.GetBytes($updated)
if((Get-SHA256 $updatedBytes) -cne $repairedSHA) { throw 'Repair output identity mismatch; no source was changed.' }
$suffix=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$backupRoot=Join-Path $backupBase ('keijin-repair-'+$suffix)
$temporary=$target+'.azsg-repair-'+[guid]::NewGuid().ToString('N')+'.tmp'
Assert-Within $backupRoot $backupBase
Assert-NoLinks $backupRoot
Assert-NoLinks $temporary
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$backup=Join-Path $backupRoot 'DamageText.lua'
Write-NewFile $backup $originalBytes
if((Get-SHA256 ([IO.File]::ReadAllBytes($backup))) -cne $actualSHA) { throw 'Repair backup identity mismatch.' }
try {
    Write-NewFile $temporary $updatedBytes
    Assert-NoLinks $target
    if((Get-SHA256 ([IO.File]::ReadAllBytes($target))) -cne $actualSHA) { throw 'KeijinUI changed during repair; replacement cancelled.' }
    [IO.File]::Replace($temporary,$target,[NullString]::Value)
    if((Get-SHA256 ([IO.File]::ReadAllBytes($target))) -cne $repairedSHA) { throw 'Written repair identity could not be confirmed.' }
} finally {
    if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
[pscustomobject]@{Changed=$true;SourcePath=$target;SourceVersion=$sourceVersion;RepairRevision=2;OriginalSHA256=$actualSHA;SHA256=$repairedSHA;BackupDirectory=$backupRoot}

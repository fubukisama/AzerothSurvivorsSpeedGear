#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Game')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Game')][string]$GamePath,
    [Parameter(Mandatory=$true,ParameterSetName='Source')][string]$SourcePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$originalSHA='16d058315a36f1dd48be8240c5b776924a3901b0ab80ae62b39f697bedd3f141'
$repairedSHA='c38f46e994a6d60632bedd3c29408d4f5d2bef423435c58f6800d793e7fd651b'
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
    [pscustomobject]@{Changed=$false;SourcePath=$target;SourceVersion=$sourceVersion;RepairRevision=1;SHA256=$actualSHA;BackupDirectory=$null}
    return
}
if($actualSHA -cne $originalSHA) { throw "Unsupported KeijinUI source SHA256 $actualSHA; no source was changed." }
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
foreach($pair in @(@($oldMarker,$newMarker),@($oldFont,$newFont),@($oldGlobals,$newGlobals),@($oldUiScale,$newUiScale),@($oldFootprint,$newFootprint),@($oldAdd,$newAdd),@($oldLimit,$newLimit),@($oldItem,$newItem),@($oldMerge,$newMerge))) {
    if(([regex]::Matches($updated,[regex]::Escape($pair[0]))).Count -ne 1) { throw 'Pinned source layout changed; no source was changed.' }
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
[pscustomobject]@{Changed=$true;SourcePath=$target;SourceVersion=$sourceVersion;RepairRevision=1;OriginalSHA256=$actualSHA;SHA256=$repairedSHA;BackupDirectory=$backupRoot}

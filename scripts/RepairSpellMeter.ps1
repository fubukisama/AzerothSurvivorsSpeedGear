#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Game')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Game')][string]$GamePath,
    [Parameter(Mandatory=$true,ParameterSetName='Source')][string]$SourcePath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$originalSHA='2265a223d9e2f01f82f45290d885b884e4dbe8026352f2815956608f837f0cb3'
$firstRepairSHA='a724462a9a14ce94017c0c2a4324416804e9be2369444aad422c386eba00d2a5'
$repairedSHA='9a2273e6d75998ae2a3fa75904212667d40952cf920728a56fd49b0483793aa6'
$sourceVersion='1.32'
$utf8=New-Object Text.UTF8Encoding($false,$true)

function Get-SHA256([byte[]]$Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Assert-NoLinks([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrEmpty($cursor)) {
        if(Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked paths are not repaired: $cursor" }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent -eq $cursor) { break }
        $cursor=$parent
    }
}
function Assert-Within([string]$Path,[string]$Root) {
    if(-not $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Repair path is outside the selected directory.'
    }
}
function Write-NewFile([string]$Path,[byte[]]$Bytes) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

if($PSCmdlet.ParameterSetName -eq 'Source') {
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') {
        throw '-SourcePath is restricted to disposable Windows GitHub Actions fixtures.'
    }
    $target=[IO.Path]::GetFullPath($SourcePath)
    $inside=$false
    foreach($root in @($env:GITHUB_WORKSPACE,$env:RUNNER_TEMP)) {
        if(-not [string]::IsNullOrWhiteSpace($root)) {
            $fullRoot=[IO.Path]::GetFullPath($root).TrimEnd('\')
            if($target.StartsWith($fullRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { $inside=$true }
        }
    }
    if(-not $inside) { throw 'CI fixture must be inside GITHUB_WORKSPACE or RUNNER_TEMP.' }
    $backupBase=Join-Path ([IO.Path]::GetDirectoryName($target)) 'AZSSpeedGearSpellMeterBackups'
} else {
    $gameExe=[IO.Path]::GetFullPath($GamePath)
    Assert-NoLinks $gameExe
    if([IO.Path]::GetFileName($gameExe) -ine 'AzerothSurvivors.exe' -or -not (Test-Path -LiteralPath $gameExe -PathType Leaf)) {
        throw '-GamePath must identify the installed AzerothSurvivors.exe.'
    }
    foreach($process in @(Get-CimInstance Win32_Process -Filter "Name = 'AzerothSurvivors.exe'")) {
        if([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
            [IO.Path]::GetFullPath([string]$process.ExecutablePath) -ieq $gameExe) {
            throw 'Exit the selected game normally before repairing SpellMeter.'
        }
    }
    $gameRoot=[IO.Path]::GetDirectoryName($gameExe)
    $addonRoot=Join-Path $gameRoot 'benilla-config\AddOns\AZSSpellMeter'
    $target=Join-Path $addonRoot 'AZSSpellMeter.lua'
    $toc=Join-Path $addonRoot 'AZSSpellMeter.toc'
    Assert-NoLinks $toc
    if(-not (Test-Path -LiteralPath $toc -PathType Leaf)) { throw 'AZSSpellMeter TOC is missing.' }
    $versions=@([IO.File]::ReadAllLines($toc) | Where-Object { $_ -match '^##\s*Version\s*:' })
    if($versions.Count -ne 1 -or ($versions[0] -replace '^##\s*Version\s*:\s*','').Trim() -cne $sourceVersion) {
        throw 'Only the pinned AZSSpellMeter 1.32 source can be repaired.'
    }
    $backupBase=Join-Path $gameRoot 'benilla-config\AZSSpeedGear-backups'
    Assert-Within $target $gameRoot
    Assert-Within $backupBase $gameRoot
}
Assert-NoLinks $target
Assert-NoLinks $backupBase
if(-not (Test-Path -LiteralPath $target -PathType Leaf) -or [IO.Path]::GetExtension($target) -ine '.lua') {
    throw 'The selected SpellMeter source must be a regular Lua file.'
}
$originalBytes=[IO.File]::ReadAllBytes($target)
$actualSHA=Get-SHA256 $originalBytes
if($actualSHA -ceq $repairedSHA) {
    [pscustomobject]@{Changed=$false;SourcePath=$target;SourceVersion=$sourceVersion;RepairRevision=2;SHA256=$actualSHA;BackupDirectory=$null}
    return
}
if($actualSHA -cne $originalSHA -and $actualSHA -cne $firstRepairSHA) { throw "Unsupported SpellMeter source SHA256 $actualSHA; no source was changed." }
$text=$utf8.GetString($originalBytes)
$eol=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
$oldWindow=@(
    "`tlocal n = rebuild(win.fixed)",
    "`tlocal viewH = viewHeight(win)"
) -join $eol
$newWindow=@(
    "`tlocal n = rebuild(win.fixed)",
    "`t-- AZSSpeedGear performance repair: keep the collapsed total live without laying out hidden rows.",
    "`tif win == frame and not frame:IsShown() then",
    "`t`tif win.bubbleText then",
    "`t`t`twin.bubbleText:SetText(comma(meterTotal))",
    "`t`t`tlocal bw = 36",
    "`t`t`tif win.bubbleText.GetStringWidth then",
    "`t`t`t`tbw = (win.bubbleText:GetStringWidth() or 24) + 16",
    "`t`t`tend",
    "`t`t`tbubble:SetWidth(math.max(36, bw))",
    "`t`tend",
    "`t`treturn",
    "`tend",
    "`tlocal viewH = viewHeight(win)"
) -join $eol
$oldDeath=@("`t`tnoteKill(name)","`t`trefresh()") -join $eol
$newDeath=@(
    "`t`tnoteKill(name)",
    "`t`t-- AZSSpeedGear performance repair: the existing periodic updater redraws the credited total."
) -join $eol
$updated=$text
if($actualSHA -ceq $originalSHA) {
    foreach($anchor in @($oldWindow,$oldDeath)) {
        if(([regex]::Matches($updated,[regex]::Escape($anchor))).Count -ne 1) { throw 'Pinned source layout changed; no source was changed.' }
    }
    $updated=$updated.Replace($oldWindow,$newWindow).Replace($oldDeath,$newDeath)
    if((Get-SHA256 ($utf8.GetBytes($updated))) -cne $firstRepairSHA) { throw 'First-stage repair identity mismatch; no source was changed.' }
}
$oldRebuild='local function rebuild(mode)'
$newRebuild='local function rebuild(mode, dataOnly)'
$oldSample=@(
    "`tlocal windowRate = recentRate(mode, runNow(), meterTotal, bucket)",
    "`tif windowRate then",
    "`t`tmeterDps = windowRate",
    "`tend"
) -join $eol
$newSample=@(
    $oldSample,
    "`t-- AZSSpeedGear performance repair v2: preserve history; defer hidden presentation work.",
    "`tif dataOnly then return 0 end"
) -join $eol
$oldCall="`tlocal n = rebuild(win.fixed)"
$newCall="`tlocal n = rebuild(win.fixed, win == frame and not frame:IsShown())"
foreach($anchor in @($oldRebuild,$oldSample,$oldCall)) {
    if(([regex]::Matches($updated,[regex]::Escape($anchor))).Count -ne 1) { throw 'Pinned data-path layout changed; no source was changed.' }
}
$updated=$updated.Replace($oldRebuild,$newRebuild).Replace($oldSample,$newSample).Replace($oldCall,$newCall)
$updatedBytes=$utf8.GetBytes($updated)
if((Get-SHA256 $updatedBytes) -cne $repairedSHA) { throw 'Repair output identity mismatch; no source was changed.' }

$suffix=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$backupRoot=Join-Path $backupBase ('spellmeter-repair-'+$suffix)
$temporary=$target+'.azsg-repair-'+[guid]::NewGuid().ToString('N')+'.tmp'
Assert-Within $backupRoot $backupBase
Assert-NoLinks $backupRoot
Assert-NoLinks $temporary
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$backup=Join-Path $backupRoot 'AZSSpellMeter.lua'
Write-NewFile $backup $originalBytes
if((Get-SHA256 ([IO.File]::ReadAllBytes($backup))) -cne $actualSHA) { throw 'Repair backup identity mismatch.' }
try {
    Write-NewFile $temporary $updatedBytes
    Assert-NoLinks $target
    if((Get-SHA256 ([IO.File]::ReadAllBytes($target))) -cne $actualSHA) { throw 'SpellMeter changed during repair; source replacement cancelled.' }
    [IO.File]::Replace($temporary,$target,[NullString]::Value)
    if((Get-SHA256 ([IO.File]::ReadAllBytes($target))) -cne $repairedSHA) { throw 'Written repair identity could not be confirmed.' }
} finally {
    if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
[pscustomobject]@{Changed=$true;SourcePath=$target;SourceVersion=$sourceVersion;RepairRevision=2;OriginalSHA256=$actualSHA;SHA256=$repairedSHA;BackupDirectory=$backupRoot}

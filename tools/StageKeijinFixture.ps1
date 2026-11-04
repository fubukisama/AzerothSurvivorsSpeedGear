#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') {
    throw 'This source fixture may be staged only on disposable Windows GitHub Actions runners.'
}
$upstreamSHA='bd5439e11d01eefc22bb2e2f6779cc1fa5d616be8d99280cad378db592219749'
$installedSHA='16d058315a36f1dd48be8240c5b776924a3901b0ab80ae62b39f697bedd3f141'
$sourceUrl='https://raw.githubusercontent.com/KeijinDE/KeijinUI_modern-as-ui/df61ac35119f099786676774a4075f80f5ea8f03/KeijinUI/DamageText.lua'
$utf8=New-Object Text.UTF8Encoding($false,$true)
function Hash([byte[]]$Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Assert-NoLinks([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrEmpty($cursor)) {
        if(Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked fixture paths are refused.' }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent -eq $cursor) { break }
        $cursor=$parent
    }
}
$target=[IO.Path]::GetFullPath($OutputPath)
$inside=$false
foreach($root in @($env:GITHUB_WORKSPACE,$env:RUNNER_TEMP)) {
    if(-not [string]::IsNullOrWhiteSpace($root) -and
       $target.StartsWith([IO.Path]::GetFullPath($root).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $inside=$true }
}
if(-not $inside -or [IO.Path]::GetExtension($target) -ine '.lua') { throw 'Fixture output must be a Lua file inside the runner workspace or temporary directory.' }
Assert-NoLinks $target
if(Test-Path -LiteralPath $target) { throw 'Fixture output already exists.' }
$parent=[IO.Path]::GetDirectoryName($target)
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temporary=$target+'.upstream-'+[guid]::NewGuid().ToString('N')+'.tmp'
try {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $temporary -TimeoutSec 45
    if((Get-Item -LiteralPath $temporary).Length -gt 256KB) { throw 'Unexpected source size.' }
    $bytes=[IO.File]::ReadAllBytes($temporary)
    if((Hash $bytes) -cne $upstreamSHA) { throw 'Pinned upstream source SHA256 mismatch.' }
    $text=$utf8.GetString($bytes)
    # Reproduce the existing private damage-only integration from its pinned
    # public source. No whole third-party source is checked into this repository.
    $oldSetter='function K.damageText.SetPosition(value) K.DB().combatTextPosition=value=="fixed" and "fixed" or nil end'
    $newSetter='function K.damageText.SetPosition(value) K.DB().combatTextPosition=value=="fixed" and "fixed" or "plate" end'
    $oldTail=@(
        '    if K.resourceText then K.resourceText.Clear() end',
        '    local db=K.DB()',
        '    if db.originalCombatDamage~=nil then SetCVar("CombatDamage",db.originalCombatDamage) end',
        '    if db.originalShowCombatText~=nil then SHOW_COMBAT_TEXT=db.originalShowCombatText end',
        '    if CombatText_UpdateDisplayedMessages then CombatText_UpdateDisplayedMessages() end'
    ) -join "`n"
    $oldTail+="`n"
    foreach($anchor in @($oldSetter,$oldTail)) {
        if(([regex]::Matches($text,[regex]::Escape($anchor))).Count -ne 1) { throw 'Pinned integration layout changed.' }
    }
    $derived=$text.Replace($oldSetter,$newSetter).Replace($oldTail,'')
    $result=$utf8.GetBytes($derived)
    if((Hash $result) -cne $installedSHA) { throw 'Derived installed source identity mismatch.' }
    Assert-NoLinks $target
    $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($result,0,$result.Length);$stream.Flush($true) } finally { $stream.Dispose() }
} finally {
    if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
[pscustomobject]@{SourcePath=$target;UpstreamSHA256=$upstreamSHA;SHA256=$installedSHA;Version='4.6.1-damageonly.1'}

#requires -Version 5.1
[CmdletBinding()]
param()

# Remote Windows CI only. These are inert files; no EXE or DLL is executed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'This suite requires the remote CI RUNNER_TEMP directory.' }
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP ('AZSSpeedGear-toc-notes-' + [guid]::NewGuid().ToString('N'))))
$temporaryRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([char[]]@('\', '/'))
if (-not $fixtureRoot.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $fixtureRoot)) { throw 'Unsafe fixture path.' }
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:checks = 0
$codes = @('en', 'zh', 'ja', 'pl', 'cs', 'de', 'pt', 'es', 'fr', 'ro', 'tr', 'ru', 'uk', 'ko')
$values = @{}
foreach ($code in $codes) { $values[$code] = 'Fixed fixture description ' + $code }
$values['zh'] = ([string][char]0x4e2d) + [char]0x6587 + ' fixture description'
$values['ja'] = ([string][char]0x65e5) + [char]0x672c + [char]0x8a9e + ' fixture description'
$tocRelative = 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc'
$libraryRelative = 'benilla-config\AddOns\AZSSpeedGear\Updater\TocNotes.ps1'
$installer = Join-Path $projectRoot 'scripts\Install.ps1'
$uninstaller = Join-Path $projectRoot 'scripts\Uninstall.ps1'
. (Join-Path $projectRoot 'scripts\TocNotes.ps1')
. (Join-Path $projectRoot 'scripts\Update.ps1') -LibraryOnly

function Check([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:checks++
}

function Reject([scriptblock]$Action, [string]$Label) {
    $refused = $false
    try { & $Action | Out-Null } catch { $refused = $true }
    Check $refused $Label
}

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:utf8)
}

function Hash-Bytes([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function New-Toc([string]$Newline = "`n", [switch]$Bom) {
    $lines = @('## Interface: 11200', '## Title: AzerothSurvivorsSpeedGear',
        ('## Notes: ' + $script:values['en']), '## Version: 0.6.1', '## SavedVariables: AZSSpeedGearDB')
    foreach ($code in $script:codes) { $lines += '## X-AZSG-Notes-' + $code + ': ' + $script:values[$code] }
    $lines += @('', 'NativeLocale.lua', 'AZSSpeedGear.lua', '')
    $text = $lines -join $Newline
    if ($Bom) { $text = ([string][char]0xfeff) + $text }
    return $text
}

function With-Notes([string]$Text, [string]$Value) {
    $match = [regex]::Match($Text, '(?m)^## Notes: ([^\r\n]*)(?=\r?$)').Groups[1]
    return $Text.Substring(0, $match.Index) + $Value + $Text.Substring($match.Index + $match.Length)
}

# Keep the shipped template in the same exact English-baseline contract as the
# native writer and this verifier, using the actual fourteen translated values.
$shippedBytes = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'AddOns\AZSSpeedGear\AZSSpeedGear.toc'))
$shippedHash = Hash-Bytes $shippedBytes
$shippedCanonical = Get-AZSGTocNotesCanonicalBytes $shippedBytes
Check ((Hash-Bytes $shippedCanonical) -ceq $shippedHash) 'shipped TOC has the exact static English Notes baseline'
$shippedText = $utf8.GetString($shippedBytes)
foreach ($translation in [regex]::Matches($shippedText, '(?m)^## X-AZSG-Notes-([a-z]{2}): ([^\r\n]*)(?=\r?$)')) {
    Check (Test-AZSGTocNotesReceiptHash ($utf8.GetBytes((With-Notes $shippedText $translation.Groups[2].Value))) $shippedHash) ('shipped localized Notes ' + $translation.Groups[1].Value)
}

# The pure library preserves every byte except the selected value, including
# UTF-8 Unicode, BOM and LF/CRLF. A changed newline is not canonicalized away.
foreach ($newline in @("`n", "`r`n")) {
    foreach ($bom in @($false, $true)) {
        $baseline = New-Toc -Newline $newline -Bom:$bom
        $expected = Hash-Bytes ($utf8.GetBytes($baseline))
        foreach ($code in $codes) {
            $bytes = $utf8.GetBytes((With-Notes $baseline $values[$code]))
            Check (Test-AZSGTocNotesReceiptHash $bytes $expected) ('pure known translation ' + $code)
        }
    }
}
$baseline = New-Toc
$baselineBytes = $utf8.GetBytes($baseline)
$baselineHash = Hash-Bytes $baselineBytes
$invalidTexts = @(
    (With-Notes $baseline 'not a known translation'),
    ($baseline.Replace('## Title: AzerothSurvivorsSpeedGear', '## Title: OtherProduct')),
    ($baseline.Replace('## Version: 0.6.1', '## Version: 0.6.2')),
    ($baseline.Replace('AZSSpeedGear.lua', 'Injected.lua')),
    ($baseline.Replace('## X-AZSG-Notes-pl:', '## X-AZSG-Notes-en:')),
    ($baseline.Replace('## X-AZSG-Notes-pl:', '## X-AZSG-Notes-xx:')),
    ($baseline.Replace(('## X-AZSG-Notes-pl: ' + $values['pl'] + "`n"), '')),
    ($baseline.Replace(('## X-AZSG-Notes-fr: ' + $values['fr']), '## X-AZSG-Notes-fr: altered translation')),
    ($baseline + '## Notes: ' + $values['en'] + "`n"),
    ($baseline + '## notes : ' + $values['en'] + "`n"),
    ($baseline.Replace('## Notes: ', '## Notes : ')),
    (With-Notes $baseline ($values['zh'] + "`nInjected.lua")),
    ($baseline.Replace("`n", "`r`n"))
)
foreach ($text in $invalidTexts) { Check (-not (Test-AZSGTocNotesReceiptHash ($utf8.GetBytes($text)) $baselineHash)) 'pure rejects non-Notes change or invalid metadata' }
$badUtf8 = [byte[]]@($baselineBytes + [byte]0xff)
Check (-not (Test-AZSGTocNotesReceiptHash $badUtf8 $baselineHash)) 'strict UTF-8 rejects invalid byte sequence'
Check (-not (Test-AZSGTocNotesReceiptHash ($utf8.GetBytes($baseline + ('x' * 16385))) $baselineHash)) 'TOC size is bounded'

# All process discovery is mocked: this suite never inspects or starts a game.
function Get-CimInstance { param([string]$ClassName, [string]$Filter) }
$packageRoot = Join-Path $fixtureRoot 'package'
$sourceAddon = Join-Path $packageRoot 'AddOns\AZSSpeedGear'
$gameRoot = Join-Path $fixtureRoot 'game'
$gameExe = Join-Path $gameRoot 'AzerothSurvivors.exe'
$targetAddon = Join-Path $gameRoot 'benilla-config\AddOns\AZSSpeedGear'
$targetToc = Join-Path $gameRoot $tocRelative
$targetLibrary = Join-Path $gameRoot $libraryRelative
$receiptPath = Join-Path $gameRoot 'benilla-config\AZSSpeedGear-install.json'
$localeTemplate = "-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = nil;`n"
Write-Text (Join-Path $sourceAddon 'AZSSpeedGear.toc') $baseline
Write-Text (Join-Path $sourceAddon 'AZSSpeedGear.lua') '-- inert fixture Lua'
Write-Text (Join-Path $sourceAddon 'NativeLocale.lua') $localeTemplate
Write-Text (Join-Path $packageRoot 'Native\dwmapi.dll') 'inert fixture DLL bytes'
New-Item -ItemType Directory -Path (Join-Path $sourceAddon 'Updater') -Force | Out-Null
foreach ($name in @('Install.ps1', 'Update.ps1', 'TocNotes.ps1')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('scripts\' + $name)) -Destination (Join-Path $sourceAddon ('Updater\' + $name))
}

# Minimal inert PE32+ fixture with one dwmapi import. It is only read as bytes.
$bytes = New-Object byte[] 1536
function Put-U16([int]$Offset, [uint16]$Value) { [BitConverter]::GetBytes($Value).CopyTo($script:bytes, $Offset) }
function Put-U32([int]$Offset, [uint32]$Value) { [BitConverter]::GetBytes($Value).CopyTo($script:bytes, $Offset) }
Put-U16 0 0x5a4d; Put-U32 0x3c 0x80; Put-U32 0x80 0x4550
Put-U16 0x84 0x8664; Put-U16 0x86 1; Put-U16 0x94 240
$optional = 0x98
Put-U16 $optional 0x20b; Put-U32 ($optional + 60) 512; Put-U32 ($optional + 108) 16
Put-U32 ($optional + 120) 0x1000; Put-U32 ($optional + 124) 40
$section = $optional + 240
Put-U32 ($section + 8) 512; Put-U32 ($section + 12) 0x1000
Put-U32 ($section + 16) 512; Put-U32 ($section + 20) 512; Put-U32 (512 + 12) 0x1050
[Text.Encoding]::ASCII.GetBytes('dwmapi.dll').CopyTo($bytes, 592)
New-Item -ItemType Directory -Path $targetAddon -Force | Out-Null
[IO.File]::WriteAllBytes($gameExe, $bytes)
Write-Text (Join-Path $gameRoot 'dwmapi.dll') 'inert legacy DLL bytes'
Write-Text $targetToc "## Title: AzerothSurvivorsSpeedGear`n## Notes: Legacy static notes`n## Version: 0.6.0`nAZSSpeedGear.lua`n"
Write-Text (Join-Path $targetAddon 'AZSSpeedGear.lua') '-- inert legacy Lua'
$legacyManaged = foreach ($relative in @('dwmapi.dll', $tocRelative, 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.lua')) {
    $path = Join-Path $gameRoot $relative
    [pscustomobject]@{ RelativePath = $relative; SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; Bytes = (Get-Item -LiteralPath $path).Length }
}
$legacyReceipt = [ordered]@{ Product = 'AZSSpeedGear'; SchemaVersion = 1; Version = '0.6.0'; GameExecutable = $gameExe
    GameExeSHA256 = (Get-FileHash -LiteralPath $gameExe -Algorithm SHA256).Hash; ManagedFiles = @($legacyManaged) }
Write-Text $receiptPath ($legacyReceipt | ConvertTo-Json -Depth 8)
$protected = @('avrt.dll', 'benilla-config\config.toml', 'benilla-config\saved-variables.lua')
$protectedHashes = @{}
foreach ($relative in $protected) {
    $path = Join-Path $gameRoot $relative
    Write-Text $path ('protected fixture ' + $relative)
    $protectedHashes[$relative] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$installed = & $installer -GamePath $gameExe -PackagePath $packageRoot | ConvertFrom-Json
Check $installed.Installed 'legacy schema-one static installation upgrades normally'
$receiptText = [IO.File]::ReadAllText($receiptPath)
$receipt = $receiptText | ConvertFrom-Json
$tocEntry = @($receipt.ManagedFiles | Where-Object { $_.RelativePath -ceq $tocRelative })
Check ($receipt.SchemaVersion -eq 1 -and $tocEntry.Count -eq 1 -and $tocEntry[0].SHA256 -ieq $baselineHash) 'receipt retains exact static English baseline hash and schema one'
Check (@($receipt.ManagedFiles | Where-Object { $_.RelativePath -ceq $libraryRelative }).Count -eq 1) 'normal installer records the library as a static managed file'

function Accept-All([string]$Label) {
    $preflight = & $script:installer -GamePath $script:gameExe -PackagePath $script:packageRoot -CheckOnly | ConvertFrom-Json
    Check $preflight.ExistingInstallationVerified ($Label + ': Install')
    $preflight = & $script:uninstaller -GamePath $script:gameExe -CheckOnly | ConvertFrom-Json
    Check $preflight.OwnershipVerified ($Label + ': Uninstall')
    $owned = Get-AZSGInstalledReceipt (Get-AZSGGame $script:gameExe)
    Check ($owned.Owned.ContainsKey($script:targetToc)) ($Label + ': Update')
}

function Reject-All([string]$Label) {
    Reject { & $script:installer -GamePath $script:gameExe -PackagePath $script:packageRoot -CheckOnly } ($Label + ': Install')
    Reject { & $script:uninstaller -GamePath $script:gameExe -CheckOnly } ($Label + ': Uninstall')
    Reject { Get-AZSGInstalledReceipt (Get-AZSGGame $script:gameExe) } ($Label + ': Update')
}

foreach ($code in $codes) {
    Write-Text $targetToc (With-Notes $baseline $values[$code])
    Accept-All ('known localized Notes ' + $code)
}
foreach ($text in $invalidTexts) {
    Write-Text $targetToc $text
    Reject-All 'non-Notes bytes or metadata tampered'
}
[IO.File]::WriteAllBytes($targetToc, $badUtf8)
Reject-All 'invalid UTF-8'
Write-Text $targetToc ($baseline + ('x' * 16385))
Reject-All 'oversized TOC'
Write-Text $targetToc (With-Notes $baseline $values['zh'])

# No unverified library is executed, even while the root TOC needs fallback.
$libraryBytes = [IO.File]::ReadAllBytes($targetLibrary)
$executionMarker = Join-Path $fixtureRoot 'untrusted-library-executed.txt'
$injectedLibrary = [Text.Encoding]::UTF8.GetString($libraryBytes) + "`n[IO.File]::WriteAllText('" + $executionMarker.Replace("'", "''") + "', 'bad')`n"
Write-Text $targetLibrary $injectedLibrary
Reject-All 'library bytes fail their receipt hash'
Check (-not (Test-Path -LiteralPath $executionMarker)) 'changed library never executes'
[IO.File]::WriteAllBytes($targetLibrary, $libraryBytes)
$noLibrary = $receiptText | ConvertFrom-Json
$noLibrary.ManagedFiles = @($noLibrary.ManagedFiles | Where-Object { $_.RelativePath -cne $libraryRelative })
Write-Text $receiptPath ($noLibrary | ConvertTo-Json -Depth 8)
Reject-All 'old receipt without a library cannot authorize changed Notes'
Write-Text $receiptPath $receiptText

# The fallback never applies to another managed path, even if its bytes are a
# valid translated TOC whose canonical bytes match that path's receipt hash.
$otherPath = Join-Path $targetAddon 'AZSSpeedGear.lua'
$otherOriginal = [IO.File]::ReadAllBytes($otherPath)
$otherReceipt = $receiptText | ConvertFrom-Json
foreach ($entry in $otherReceipt.ManagedFiles) {
    if ($entry.RelativePath -ceq 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.lua') { $entry.SHA256 = $baselineHash }
}
Write-Text $receiptPath ($otherReceipt | ConvertTo-Json -Depth 8)
Write-Text $otherPath (With-Notes $baseline $values['zh'])
Reject-All 'normalization is restricted to the exact root TOC path'
[IO.File]::WriteAllBytes($otherPath, $otherOriginal)
Write-Text $receiptPath $receiptText

# Downloaded package validation is always an exact SHA check; translated Notes
# are allowed only for an already installed receipt-owned TOC.
1..14 | ForEach-Object { Write-Text (Join-Path $packageRoot ('docs\fixture-' + $_ + '.txt')) ('inert document ' + $_) }
$manifest = foreach ($file in @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse)) {
    [pscustomobject]@{ Path = $file.FullName.Substring($packageRoot.Length + 1).Replace('\', '/'); Bytes = $file.Length
        SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$manifestPath = Join-Path $packageRoot 'files.json'
Write-Text $manifestPath ($manifest | ConvertTo-Json -Depth 5)
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
Assert-AZSGPackage $packageRoot '0.6.1' $manifestHash
Check $true 'static English package passes exact release manifest'
Write-Text (Join-Path $sourceAddon 'AZSSpeedGear.toc') (With-Notes $baseline $values['zh'])
Reject { Assert-AZSGPackage $packageRoot '0.6.1' $manifestHash } 'downloaded translated TOC fails exact package SHA'
Write-Text (Join-Path $sourceAddon 'AZSSpeedGear.toc') $baseline

# Exercise real, reversible installer transactions after locale generation.
$updated = & $installer -GamePath $gameExe -PackagePath $packageRoot | ConvertFrom-Json
Check $updated.Installed 'translated installed TOC permits actual update'
$backedUp = Join-Path $updated.BackupDirectory 'previous\AZSSpeedGear\AZSSpeedGear.toc'
Check ([IO.File]::ReadAllText($backedUp) -ceq (With-Notes $baseline $values['zh'])) 'update backup retains translated TOC bytes'
Check ([IO.File]::ReadAllText($targetToc) -ceq $baseline) 'update installs static English baseline bytes'
Write-Text $targetToc (With-Notes $baseline $values['ja'])
$removed = & $uninstaller -GamePath $gameExe | ConvertFrom-Json
Check $removed.Uninstalled 'translated installed TOC permits actual uninstall'
Check ([IO.File]::ReadAllText((Join-Path $removed.BackupDirectory 'AZSSpeedGear\AZSSpeedGear.toc')) -ceq (With-Notes $baseline $values['ja'])) 'uninstall backup retains translated TOC bytes'
foreach ($relative in $protected) {
    Check ((Get-FileHash -LiteralPath (Join-Path $gameRoot $relative) -Algorithm SHA256).Hash -ieq $protectedHashes[$relative]) ('preserved ' + $relative)
}
Check ((Get-FileHash -LiteralPath $gameExe -Algorithm SHA256).Hash -ieq $legacyReceipt.GameExeSHA256) 'inert game EXE remains unchanged'
[pscustomobject]@{ Passed = $true; Checks = $checks; RealGameTouched = $false; FixtureDirectory = $fixtureRoot } | ConvertTo-Json

#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot ('artifacts\installer-tests-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith($projectRoot + '\artifacts\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $fixtureRoot)) {
    throw 'Test fixture must be a new child of this project artifacts directory.'
}
$packageRoot = Join-Path $fixtureRoot 'package'
$gameRoot = Join-Path $fixtureRoot 'game'
$sourceAddon = Join-Path $packageRoot 'AddOns\AZSSpeedGear'
$targetAddon = Join-Path $gameRoot 'benilla-config\AddOns\AZSSpeedGear'
$sourceLocale = Join-Path $sourceAddon 'NativeLocale.lua'
$targetLocale = Join-Path $targetAddon 'NativeLocale.lua'
$gameExe = Join-Path $gameRoot 'AZSSpeedGearInstallerFixture.exe'
$receiptPath = Join-Path $gameRoot 'benilla-config\AZSSpeedGear-install.json'
$installer = Join-Path $projectRoot 'scripts\Install.ps1'
$uninstaller = Join-Path $projectRoot 'scripts\Uninstall.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)
$template = "-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = nil;`n"
$generated = "-- AZSSpeedGear runtime locale hint`r`nAZSSpeedGearNativeLocale = `"zh`";`r`n"
$runtimeRelative = 'benilla-config\AddOns\AZSSpeedGear\NativeLocale.lua'
$script:checks = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:utf8)
}

function Assert-Refused([scriptblock]$Action, [string]$ExpectedMessage, [string]$Label) {
    $refused = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            throw "Unexpected failure during ${Label}: $($_.Exception.Message)"
        }
        $refused = $true
    }
    Assert-True $refused $Label
}

function Assert-BothRefuse([string]$ExpectedMessage, [string]$Label) {
    Assert-Refused { & $installer -GamePath $gameExe -PackagePath $packageRoot -CheckOnly } $ExpectedMessage ($Label + ': install')
    Assert-Refused { & $uninstaller -GamePath $gameExe -CheckOnly } $ExpectedMessage ($Label + ': uninstall')
}

# This is an inert PE fixture, never launched or loaded. It has an AMD64 PE32+
# header, one section and an ordinary dwmapi.dll import for installer preflight.
New-Item -ItemType Directory -Path $sourceAddon, (Join-Path $packageRoot 'Native'), $targetAddon -Force | Out-Null
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
[IO.File]::WriteAllBytes($gameExe, $bytes)
Write-Text (Join-Path $packageRoot 'Native\dwmapi.dll') 'inert test-owned proxy'
Write-Text (Join-Path $sourceAddon 'AZSSpeedGear.toc') "## Interface: 11200`n## Version: fixture-new`nNativeLocale.lua`nAZSSpeedGear.lua`n"
Write-Text (Join-Path $sourceAddon 'AZSSpeedGear.lua') '-- inert new fixture'
Write-Text $sourceLocale $template

# A genuine old-schema installation has no RuntimeFiles property or locale file.
Write-Text (Join-Path $targetAddon 'AZSSpeedGear.toc') "## Interface: 11200`n## Version: fixture-old`nAZSSpeedGear.lua`n"
Write-Text (Join-Path $targetAddon 'AZSSpeedGear.lua') '-- inert old fixture'
Copy-Item -LiteralPath (Join-Path $packageRoot 'Native\dwmapi.dll') -Destination (Join-Path $gameRoot 'dwmapi.dll')
$legacyFiles = foreach ($relative in @('dwmapi.dll', 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc', 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.lua')) {
    $filePath = Join-Path $gameRoot $relative
    [pscustomobject]@{ RelativePath = $relative; SHA256 = (Get-FileHash -LiteralPath $filePath).Hash; Bytes = (Get-Item -LiteralPath $filePath).Length }
}
$legacyReceipt = [ordered]@{
    Product = 'AZSSpeedGear'; SchemaVersion = 1; GameExecutable = $gameExe; ManagedFiles = @($legacyFiles)
}
Write-Text $receiptPath ($legacyReceipt | ConvertTo-Json -Depth 8)
$legacyCheck = & $uninstaller -GamePath $gameExe -CheckOnly | ConvertFrom-Json
Assert-True $legacyCheck.OwnershipVerified 'old receipt without RuntimeFiles remains supported'
$installCheck = & $installer -GamePath $gameExe -PackagePath $packageRoot -CheckOnly | ConvertFrom-Json
Assert-True $installCheck.ExistingInstallationVerified 'old receipt passes upgrade ownership checks'
Assert-True ($installCheck.RuntimeFileCount -eq 1) 'new source template is a runtime entry'
Assert-True (-not (Test-Path -LiteralPath $targetLocale)) 'preflight does not copy the locale template'

# Source packages must provide a restricted template before any file mutation.
$heldTemplate = Join-Path $fixtureRoot 'held-template.lua'
Move-Item -LiteralPath $sourceLocale -Destination $heldTemplate
Assert-Refused { & $installer -GamePath $gameExe -PackagePath $packageRoot -CheckOnly } 'locale hint is missing' 'source template is required'
Move-Item -LiteralPath $heldTemplate -Destination $sourceLocale
Write-Text $sourceLocale ($template + 'error("unexpected code");')
Assert-Refused { & $installer -GamePath $gameExe -PackagePath $packageRoot -CheckOnly } 'locale hint contains' 'malicious source template is refused'
Write-Text $sourceLocale $template

$protected = @('avrt.dll', 'benilla-config\config.toml', 'benilla-config\saved-variables.lua')
$protectedHashes = @{}
foreach ($relative in $protected) {
    $path = Join-Path $gameRoot $relative
    Write-Text $path ('untouched fixture: ' + $relative)
    $protectedHashes[$relative] = (Get-FileHash -LiteralPath $path).Hash
}
$installed = & $installer -GamePath $gameExe -PackagePath $packageRoot | ConvertFrom-Json
Assert-True $installed.Installed 'old installation upgrades to runtime-file version'
Assert-True (Test-Path -LiteralPath (Join-Path $installed.BackupDirectory 'previous\AZSSpeedGear-install.json')) 'old installation receipt is backed up'
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($receipt.SchemaVersion -eq 1) 'receipt schema remains one'
Assert-True (@($receipt.RuntimeFiles).Count -eq 1) 'receipt has exactly one runtime file'
Assert-True ($receipt.RuntimeFiles[0].RelativePath -ceq $runtimeRelative -and $receipt.RuntimeFiles[0].Kind -ceq 'LocaleHint') 'runtime path and kind are exact'
Assert-True (@($receipt.ManagedFiles | Where-Object { $_.RelativePath -ieq $runtimeRelative }).Count -eq 0) 'runtime file is excluded from static hashes'

Write-Text $targetLocale $generated
$zhCheck = & $installer -GamePath $gameExe -PackagePath $packageRoot -CheckOnly | ConvertFrom-Json
Assert-True $zhCheck.ExistingInstallationVerified 'generated zh with CRLF is accepted for update'
$zhUninstallCheck = & $uninstaller -GamePath $gameExe -CheckOnly | ConvertFrom-Json
Assert-True $zhUninstallCheck.OwnershipVerified 'generated zh with CRLF is accepted for uninstall'

foreach ($code in @('en', 'pl', 'cs', 'de', 'pt', 'es', 'fr', 'ro', 'tr', 'ru', 'uk', 'zh', 'ja', 'ko')) {
    Write-Text $targetLocale ("-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = `"" + $code + "`";`n")
    $languageCheck = & $installer -GamePath $gameExe -PackagePath $packageRoot -CheckOnly | ConvertFrom-Json
    Assert-True $languageCheck.ExistingInstallationVerified ('allowed language: ' + $code)
}

$invalidContents = @(
    "-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = `"xx`";`n",
    ($generated + "error(`"unexpected code`");`n"),
    "-- changed header`nAZSSpeedGearNativeLocale = `"zh`";`n",
    "-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = 'zh';`n",
    "-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = `"ZH`";`n",
    "-- AZSSpeedGear runtime locale hint`nAZSSpeedGearNativeLocale = `"zh`"; AZSSpeedGearNativeLocale = nil;`n"
)
for ($index = 0; $index -lt $invalidContents.Count; $index++) {
    Write-Text $targetLocale $invalidContents[$index]
    Assert-BothRefuse 'locale hint contains' ('invalid runtime Lua ' + $index)
}
Write-Text $targetLocale $generated

$validReceiptText = [IO.File]::ReadAllText($receiptPath)
$changed = $validReceiptText | ConvertFrom-Json
$changed.RuntimeFiles += [pscustomobject]@{ RelativePath = 'benilla-config\AddOns\AZSSpeedGear\Other.lua'; Kind = 'LocaleHint' }
Write-Text $receiptPath ($changed | ConvertTo-Json -Depth 8)
Assert-BothRefuse 'unsupported runtime file' 'unlisted runtime path'
$changed = $validReceiptText | ConvertFrom-Json
$changed.RuntimeFiles[0].Kind = 'ArbitraryLua'
Write-Text $receiptPath ($changed | ConvertTo-Json -Depth 8)
Assert-BothRefuse 'unsupported runtime file' 'unknown runtime kind'
$changed = $validReceiptText | ConvertFrom-Json
$changed.RuntimeFiles += $changed.RuntimeFiles[0]
Write-Text $receiptPath ($changed | ConvertTo-Json -Depth 8)
Assert-BothRefuse 'Duplicate managed/runtime' 'duplicate runtime entry'
$changed = $validReceiptText | ConvertFrom-Json
$changed.ManagedFiles += [pscustomobject]@{ RelativePath = $runtimeRelative; SHA256 = (Get-FileHash -LiteralPath $targetLocale).Hash; Bytes = (Get-Item -LiteralPath $targetLocale).Length }
$changed.RuntimeFiles = @()
Write-Text $receiptPath ($changed | ConvertTo-Json -Depth 8)
Assert-BothRefuse 'not a static hash entry' 'runtime content cannot bypass validation through ManagedFiles'
Write-Text $receiptPath $validReceiptText

$extraFile = Join-Path $targetAddon 'unowned.lua'
Write-Text $extraFile '-- not owned'
Assert-BothRefuse 'Additional addon file' 'extra unowned addon file'
Move-Item -LiteralPath $extraFile -Destination (Join-Path $fixtureRoot 'retained-unowned.lua')

$updated = & $installer -GamePath $gameExe -PackagePath $packageRoot | ConvertFrom-Json
Assert-True $updated.Installed 'generated hint can undergo a real update'
$backedUpHint = Join-Path $updated.BackupDirectory 'previous\AZSSpeedGear\NativeLocale.lua'
Assert-True ([IO.File]::ReadAllText($backedUpHint) -ceq $generated) 'generated hint is retained in update backup'
Assert-True ([IO.File]::ReadAllText($targetLocale) -ceq $template) 'update copies the new default template'
Write-Text $targetLocale $generated
$uninstalled = & $uninstaller -GamePath $gameExe | ConvertFrom-Json
Assert-True $uninstalled.Uninstalled 'generated hint permits reversible uninstall'
Assert-True (-not (Test-Path -LiteralPath $targetAddon)) 'uninstall moves the complete addon directory'
Assert-True ([IO.File]::ReadAllText((Join-Path $uninstalled.BackupDirectory 'AZSSpeedGear\NativeLocale.lua')) -ceq $generated) 'uninstall backup retains generated hint'
foreach ($relative in $protected) {
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $gameRoot $relative)).Hash -eq $protectedHashes[$relative]) ('protected fixture preserved: ' + $relative)
}
[pscustomobject]@{ Passed = $true; Checks = $checks; FixtureDirectory = $fixtureRoot; RealGameTouched = $false } | ConvertTo-Json

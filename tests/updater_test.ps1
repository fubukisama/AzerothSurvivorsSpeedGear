# Run only in remote Windows CI. No game, user APPDATA, or installed DLL is used.
# Network commands are mocked; production Update.ps1 exposes no URL override.
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Update.ps1') -LibraryOnly

$script:checks = 0; $script:failures = 0
function Check([bool]$Value, [string]$Message) {
    $script:checks++
    if (-not $Value) { $script:failures++; Write-Host "FAIL: $Message" }
}
function Reject([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Check $thrown $Message
}

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'This suite requires the remote CI RUNNER_TEMP directory.' }
$root = Join-Path $env:RUNNER_TEMP ('AZSSpeedGear-updater-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$script:networkCalls = [Collections.Generic.List[string]]::new()
$script:downloads = 0; $script:gameRunning = $false; $script:waitPolls = 0; $script:waitMode = $false
$script:fixtureArchive = $null
$script:release = $null
$script:compatibility = $null

function Invoke-RestMethod {
    param([string]$Uri, $Headers, [int]$TimeoutSec)
    if ($script:waitMode -and $script:waitPolls -lt 3) { throw 'Network lookup occurred before all game instances exited.' }
    $script:networkCalls.Add($Uri)
    if ($Uri -ceq $script:AzsgReleaseApi) { return $script:release }
    if ($Uri -ceq $script:AzsgCompatibilityUrl) { return $script:compatibility }
    throw 'Production attempted an unexpected URL.'
}
function Invoke-WebRequest {
    param([string]$Uri, $Headers, [switch]$UseBasicParsing, [string]$OutFile, [int]$TimeoutSec)
    $script:downloads++
    if ($Uri -cne $script:release.assets[0].browser_download_url) { throw 'Unexpected download URL.' }
    Copy-Item -LiteralPath $script:fixtureArchive -Destination $OutFile
}
function Get-AZSGGameProcesses {
    param([string]$Executable)
    $script:waitPolls++
    if ($script:waitMode) {
        if ($script:waitPolls -le 2) { [pscustomobject]@{ ExecutablePath = $Executable } }
    } elseif ($script:gameRunning) { [pscustomobject]@{ ExecutablePath = $Executable } }
}
function Start-Sleep { param([int]$Milliseconds) }

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function New-Game([string]$Name, [switch]$WithoutScanner) {
    $gameRoot = Join-Path $root $Name
    $exe = Join-Path $gameRoot 'AzerothSurvivors.exe'
    Write-Text $exe 'synthetic-game-v1'
    Write-Text (Join-Path $gameRoot 'dwmapi.dll') 'synthetic-old-dll'
    $addon = Join-Path $gameRoot 'benilla-config\AddOns\AZSSpeedGear'
    Write-Text (Join-Path $addon 'AZSSpeedGear.toc') "## Title: AzerothSurvivorsSpeedGear`n## Version: 0.5.0`n"
    $installer = @'
param([string]$GamePath,[string]$PackagePath)
$root=Split-Path -Parent $GamePath
$receiptPath=Join-Path $root 'benilla-config\AZSSpeedGear-install.json'
$receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
$toc=Join-Path $root 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc'
$source=Join-Path $PackagePath 'AddOns\AZSSpeedGear\AZSSpeedGear.toc'
Copy-Item -LiteralPath $source -Destination $toc -Force
$scanner=Join-Path $root 'benilla-config\AddOns\AZSSpeedGear\Updater\Scanner.json'
$scannerSource=Join-Path $PackagePath 'AddOns\AZSSpeedGear\Updater\Scanner.json'
Copy-Item -LiteralPath $scannerSource -Destination $scanner -Force
$receipt.Version=((Get-Content -LiteralPath $toc | Where-Object {$_ -match '^## Version:'}) -replace '^## Version:\s*','').Trim()
foreach($file in $receipt.ManagedFiles){if($file.RelativePath -eq 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc'){$file.SHA256=(Get-FileHash -LiteralPath $toc -Algorithm SHA256).Hash};if($file.RelativePath -eq 'benilla-config\AddOns\AZSSpeedGear\Updater\Scanner.json'){$file.SHA256=(Get-FileHash -LiteralPath $scanner -Algorithm SHA256).Hash}}
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Set-Content -LiteralPath (Join-Path $root 'trusted-installer-used.txt') -Value $PackagePath
'@
    Write-Text (Join-Path $addon 'Updater\Install.ps1') $installer
    $relativeFiles = @('dwmapi.dll','benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc','benilla-config\AddOns\AZSSpeedGear\Updater\Install.ps1')
    if (-not $WithoutScanner) {
        $metadata = [pscustomobject]@{ schema = 1; product = 'AzerothSurvivorsSpeedGear'; scannerContract = 'rust-duration25ms-waitable-timer-v1'; engineFingerprint = ('1' * 64) }
        Write-Text (Join-Path $addon 'Updater\Scanner.json') ($metadata | ConvertTo-Json)
        $relativeFiles += 'benilla-config\AddOns\AZSSpeedGear\Updater\Scanner.json'
    }
    $managed = foreach ($relative in $relativeFiles) {
        [pscustomobject]@{ RelativePath = $relative; SHA256 = (Get-FileHash -LiteralPath (Join-Path $gameRoot $relative) -Algorithm SHA256).Hash }
    }
    $receipt = [pscustomobject]@{ Product = 'AZSSpeedGear'; SchemaVersion = 1; Version = '0.5.0'; GameExecutable = $exe; GameExeSHA256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash; ManagedFiles = @($managed) }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $gameRoot 'benilla-config\AZSSpeedGear-install.json') -Encoding UTF8
    return $exe
}
function New-Package([string]$Version, [string]$Title = 'AzerothSurvivorsSpeedGear') {
    $name = 'AZSSpeedGear-' + $Version + '-Windows-x64'
    $package = Join-Path $root $name
    Write-Text (Join-Path $package 'AddOns\AZSSpeedGear\AZSSpeedGear.toc') "## Title: $Title`n## Version: $Version`n"
    Write-Text (Join-Path $package 'Native\dwmapi.dll') 'synthetic-new-dll'
    Write-Text (Join-Path $package 'scripts\Install.ps1') "throw 'Downloaded installer must never execute.'"
    $metadata = [pscustomobject]@{ schema = 1; product = 'AzerothSurvivorsSpeedGear'; scannerContract = 'rust-duration25ms-waitable-timer-v1'; engineFingerprint = ('2' * 64) }
    Write-Text (Join-Path $package 'AddOns\AZSSpeedGear\Updater\Scanner.json') ($metadata | ConvertTo-Json)
    1..14 | ForEach-Object { Write-Text (Join-Path $package ("docs\fixture$_.txt")) "fixture $_" }
    $manifest = foreach ($file in Get-ChildItem -LiteralPath $package -File -Recurse) {
        [pscustomobject]@{ Path = $file.FullName.Substring($package.Length + 1).Replace('\','/'); Bytes = $file.Length; SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $package 'files.json') -Encoding UTF8
    $archive = $package + '.zip'
    Compress-Archive -LiteralPath $package -DestinationPath $archive
    return $archive
}
function Set-Release([string]$Version, [string]$Archive) {
    $name = 'AZSSpeedGear-' + $Version + '-Windows-x64.zip'
    $script:release = [pscustomobject]@{
        tag_name = 'v' + $Version; published_at = '2026-01-01T00:00:00Z'; draft = $false; prerelease = $false
        assets = @([pscustomobject]@{ name = $name; size = (Get-Item -LiteralPath $Archive).Length; digest = 'sha256:' + (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant(); browser_download_url = "https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases/download/v$Version/$name" })
    }
    $script:fixtureArchive = $Archive
}
function New-ZipFixture([string]$Name, [string[]]$Names, [int]$SpecialIndex = -1,
                        [int]$SpecialAttributes = 0, [int]$SpecialBytes = 1) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archivePath = Join-Path $root ($Name + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $buffer = New-Object byte[] 1MB
        for ($index = 0; $index -lt $Names.Count; $index++) {
            $entry = $zip.CreateEntry($Names[$index])
            if ($index -eq $SpecialIndex) { $entry.ExternalAttributes = $SpecialAttributes }
            $stream = $entry.Open()
            try {
                $remaining = if ($index -eq $SpecialIndex) { $SpecialBytes } else { 1 }
                while ($remaining -gt 0) {
                    $count = [Math]::Min($buffer.Length, $remaining)
                    $stream.Write($buffer, 0, $count); $remaining -= $count
                }
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $archivePath
}

$game = New-Game 'check-only'
$archive = New-Package '0.6.0'
Set-Release '0.6.0' $archive
$gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash
$script:compatibility = [pscustomobject]@{ schema = 1; product = 'AzerothSurvivorsSpeedGear'; scannerContract = 'rust-duration25ms-waitable-timer-v1'; gameSha256 = $gameHash; gameBytes = (Get-Item -LiteralPath $game).Length; gameVersion = 'synthetic'; status = 'structural_only'; reason = 'fixture'; engineFingerprint = ('1' * 64) }
$result = Invoke-AZSGUpdate -GamePath $game -CheckOnly
Check ($result.status -eq 'update_available') 'CheckOnly reports a newer stable version'
Check ($result.compatibility.status -eq 'structural_only') 'exact fingerprint receives structural report'
Check ($script:downloads -eq 0) 'CheckOnly never downloads an archive'
Check (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $game) 'benilla-config\AZSSpeedGear-updates'))) 'CheckOnly never creates updater state'
$mutexName = Get-AZSGUpdateMutexName $game
Check ($mutexName -ceq (Get-AZSGUpdateMutexName ($game.ToUpperInvariant()))) 'launcher mutex identity ignores path case'
Check ($mutexName -cmatch '^Local\\AZSSpeedGearLauncher_[A-F0-9]{64}$') 'launcher mutex uses the shared uppercase SHA-256 identity'
$parentMutex = [Threading.Mutex]::new($false, $mutexName)
$parentHeld = $parentMutex.WaitOne(0)
try {
    Check $parentHeld 'simulated Start holds the launcher mutex'
    $nested = Invoke-AZSGUpdate -GamePath $game -CheckOnly
    Check ($nested.status -eq 'update_available') 'same-thread updater acquisition is reentrant'
    $extra = $parentMutex.WaitOne(0)
    Check $extra 'updater preserves caller mutex ownership'
    if ($extra) { $parentMutex.ReleaseMutex() }
} finally { if ($parentHeld) { $parentMutex.ReleaseMutex() }; $parentMutex.Dispose() }
$wrongEngine = Get-AZSGCompatibility $gameHash (Get-Item -LiteralPath $game).Length ('2' * 64)
Check ($wrongEngine.status -eq 'unknown' -and $wrongEngine.reason -eq 'different_scanner_fingerprint') 'same game hash cannot authenticate a different installed scanner'
$legacyGame = New-Game 'legacy-no-scanner' -WithoutScanner
$legacy = Invoke-AZSGUpdate -GamePath $legacyGame -CheckOnly
Check ($legacy.status -eq 'update_available' -and $legacy.compatibility.status -eq 'unknown') 'legacy missing scanner metadata stays unknown without blocking update'

$original = $script:release.assets[0].browser_download_url
$script:release.assets[0].browser_download_url = 'https://example.invalid/payload.zip'
Reject { Get-AZSGRelease } 'foreign package URL rejected'
$script:release.assets[0].browser_download_url = $original
$digest = $script:release.assets[0].digest
$script:release.assets[0].digest = $null
Reject { Get-AZSGRelease } 'missing GitHub digest rejected'
$script:release.assets[0].digest = $digest
$size = $script:release.assets[0].size
$script:release.assets[0].size = 64MB + 1
Reject { Get-AZSGRelease } 'oversized archive rejected before download'
$script:release.assets[0].size = $size
$script:release.prerelease = $true
Reject { Get-AZSGRelease } 'prerelease rejected'
$script:release.prerelease = $false
$script:release.draft = $true
Reject { Get-AZSGRelease } 'draft rejected'
$script:release.draft = $false

Write-Text $game 'synthetic-game-v2'
$result = Invoke-AZSGUpdate -GamePath $game -CheckOnly
Check $result.gameChanged 'game fingerprint change detected'
Check ($result.compatibility.status -eq 'unknown') 'different fingerprint never inherits compatibility claim'

$script:gameRunning = $true
$pending = Invoke-AZSGUpdate -GamePath $game
Check ($pending.status -eq 'pending') 'running game stages but does not install'
Check (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $game) 'trusted-installer-used.txt'))) 'running game never invokes installer'
$script:gameRunning = $false
$before = $script:downloads
$installed = Invoke-AZSGUpdate -GamePath $game
Check ($installed.status -eq 'installed' -and $installed.installedVersion -eq '0.6.0') 'staged update installs after exit'
Check ($installed.compatibility.status -eq 'unknown') 'installation recomputes compatibility for new scanner instead of reusing old claim'
Check ($script:downloads -eq $before) 'verified pending package is reused'
Check (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $game) 'trusted-installer-used.txt')) 'receipt-owned old installer executed'

$same = Invoke-AZSGUpdate -GamePath $game -CheckOnly
Check ($same.status -eq 'up_to_date' -and $script:downloads -eq $before) 'same version never downloads or swaps package'
$script:release.assets[0].digest = 'sha256:' + ('0' * 64)
$changedSame = Invoke-AZSGUpdate -GamePath $game -CheckOnly
Check ($changedSame.status -eq 'up_to_date' -and $script:downloads -eq $before) 'changed digest cannot swap an installed same version'
Set-Release '0.6.0' $archive
$script:release.tag_name = 'v0.4.0'
$script:release.assets[0].name = 'AZSSpeedGear-0.4.0-Windows-x64.zip'
$script:release.assets[0].browser_download_url = 'https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases/download/v0.4.0/AZSSpeedGear-0.4.0-Windows-x64.zip'
$older = Invoke-AZSGUpdate -GamePath $game -CheckOnly
Check ($older.status -eq 'up_to_date' -and $script:downloads -eq $before) 'older release never causes downgrade'
Set-Release '0.6.0' $archive

$foreignStateGame = New-Game 'foreign-updater-state'
$foreignStateRoot = Join-Path (Split-Path -Parent $foreignStateGame) 'benilla-config\AZSSpeedGear-updates'
Write-Text (Join-Path $foreignStateRoot 'update-state.json') '{"schema":1,"product":"OtherProduct"}'
$downloadsBeforeForeignState = $script:downloads
Reject { Invoke-AZSGUpdate -GamePath $foreignStateGame } 'foreign updater state rejected before installation'
Check ($script:downloads -eq $downloadsBeforeForeignState) 'foreign updater state prevents payload download'
Check (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $foreignStateGame) 'trusted-installer-used.txt'))) 'foreign updater state cannot cause a partial installation'

$corruptGame = New-Game 'corrupt-download'
$script:release.assets[0].digest = 'sha256:' + ('0' * 64)
$dllBefore = (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $corruptGame) 'dwmapi.dll') -Algorithm SHA256).Hash
Reject { Invoke-AZSGUpdate -GamePath $corruptGame } 'downloaded bytes must match GitHub digest'
Check ((Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $corruptGame) 'dwmapi.dll') -Algorithm SHA256).Hash -eq $dllBefore) 'bad download leaves old DLL intact'
Check (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $corruptGame) 'trusted-installer-used.txt'))) 'bad download never invokes any installer'
Set-Release '0.6.0' $archive

$waitGame = New-Game 'wait-first'
$script:waitMode = $true; $script:waitPolls = 0
$script:networkCalls.Clear()
$waitResult = Invoke-AZSGUpdate -GamePath $waitGame -WaitForExit -CheckOnly
Check ($script:waitPolls -ge 3) 'WaitForExit waits through running instances before returning'
Check ($script:networkCalls.Count -eq 2) 'release and fingerprint compatibility are rechecked after exit'
$script:waitMode = $false
Set-Release '0.5.0' $archive
$script:waitMode = $true; $script:waitPolls = 0
$currentWait = Invoke-AZSGUpdate -GamePath $waitGame -WaitForExit -CheckOnly
Check ($currentWait.status -eq 'up_to_date' -and $script:waitPolls -ge 3) 'WaitForExit never returns early merely because no plugin update exists'
$script:waitMode = $false
Set-Release '0.6.0' $archive

foreach ($bad in @('../evil','C:/evil','/evil','package/../evil','package/CON.txt','package/a.','package/a:b','package/a?b','package/a|b','package/a"b','other/file')) {
    Reject { Get-AZSGArchivePath $bad 'package' } "unsafe archive name rejected: $bad"
}
$safeNames = @(1..17 | ForEach-Object { "package/f$_.txt" })
$traversal = New-ZipFixture 'zip-traversal' ($safeNames + 'package/../../escaped.txt')
Reject { Expand-AZSGPackage $traversal (Join-Path $root 'extract-traversal') 'package' } 'ZIP traversal rejected before payload writes'
Check (-not (Test-Path -LiteralPath (Join-Path $root 'escaped.txt'))) 'traversal never creates outside file'
$collision = New-ZipFixture 'zip-case-collision' ($safeNames + 'package/F1.txt')
Reject { Expand-AZSGPackage $collision (Join-Path $root 'extract-collision') 'package' } 'case-colliding archive rejected'
$linkZip = New-ZipFixture 'zip-link' ($safeNames + 'package/link') 17 -1610612736
Reject { Expand-AZSGPackage $linkZip (Join-Path $root 'extract-link') 'package' } 'Unix symlink entry rejected'
$reparseZip = New-ZipFixture 'zip-reparse' ($safeNames + 'package/reparse') 17 1024
Reject { Expand-AZSGPackage $reparseZip (Join-Path $root 'extract-reparse') 'package' } 'Windows reparse entry rejected'
$largeZip = New-ZipFixture 'zip-large-entry' ($safeNames + 'package/large') 17 0 33MB
Reject { Expand-AZSGPackage $largeZip (Join-Path $root 'extract-large') 'package' } 'per-file expansion quota enforced'
$tooFew = New-ZipFixture 'zip-too-few' $safeNames
Reject { Expand-AZSGPackage $tooFew (Join-Path $root 'extract-too-few') 'package' } 'fewer than 18 archive files rejected'
$tooMany = New-ZipFixture 'zip-too-many' @(1..101 | ForEach-Object { "package/f$_.txt" })
Reject { Expand-AZSGPackage $tooMany (Join-Path $root 'extract-too-many') 'package' } 'more than 100 archive files rejected'
$validatedRoot = Join-Path $root 'validate'
$package = Expand-AZSGPackage $archive $validatedRoot 'AZSSpeedGear-0.6.0-Windows-x64'
$manifestHash = Get-AZSGArchiveManifestHash $archive 'AZSSpeedGear-0.6.0-Windows-x64'
Assert-AZSGPackage $package '0.6.0' $manifestHash
Check $true 'complete package manifest accepted'
Write-Text (Join-Path $package 'docs\unlisted.txt') 'unlisted'
Reject { Assert-AZSGPackage $package '0.6.0' $manifestHash } 'unlisted extracted file rejected'
Write-Text (Join-Path $package 'files.json') '[]'
Reject { Assert-AZSGPackage $package '0.6.0' $manifestHash } 'pending payload cannot rewrite its own integrity manifest'
$wrongVersionArchive = New-Package '0.7.0'
$wrongVersionRoot = Expand-AZSGPackage $wrongVersionArchive (Join-Path $root 'wrong-version') 'AZSSpeedGear-0.7.0-Windows-x64'
$wrongVersionManifest = Get-AZSGArchiveManifestHash $wrongVersionArchive 'AZSSpeedGear-0.7.0-Windows-x64'
Reject { Assert-AZSGPackage $wrongVersionRoot '0.6.0' $wrongVersionManifest } 'package TOC must match release version'
$wrongTitleArchive = New-Package '0.8.0' 'OtherAddon'
$wrongTitleRoot = Expand-AZSGPackage $wrongTitleArchive (Join-Path $root 'wrong-title') 'AZSSpeedGear-0.8.0-Windows-x64'
$wrongTitleManifest = Get-AZSGArchiveManifestHash $wrongTitleArchive 'AZSSpeedGear-0.8.0-Windows-x64'
Reject { Assert-AZSGPackage $wrongTitleRoot '0.8.0' $wrongTitleManifest } 'package TOC title must match product'
$badGame = New-Game 'changed-installed'
Write-Text (Join-Path (Split-Path -Parent $badGame) 'dwmapi.dll') 'foreign-change'
Reject { Invoke-AZSGUpdate -GamePath $badGame -CheckOnly } 'modified installed DLL rejected'

$savedCore = ${function:Invoke-AZSGUpdateCore}
$script:pendingCoreCalls = 0
function Invoke-AZSGUpdateCore($Game, [switch]$CheckOnly) {
    $script:pendingCoreCalls++
    if ($script:pendingCoreCalls -eq 1) { return [pscustomobject]@{status='pending'} }
    return [pscustomobject]@{status='up_to_date'}
}
try {
    $resumed = Invoke-AZSGUpdate -GamePath $game -WaitForExit
    Check ($resumed.status -eq 'up_to_date' -and $script:pendingCoreCalls -eq 2) 'exit helper waits again when a direct relaunch leaves a pending package'
} finally { Set-Item -LiteralPath Function:\Invoke-AZSGUpdateCore -Value $savedCore }

Write-Host "updater checks=$script:checks failures=$script:failures fixture=$root"
if ($script:failures) { throw 'Updater regression checks failed.' }

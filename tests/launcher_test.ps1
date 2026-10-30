#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot ('artifacts\launcher-tests-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith($projectRoot + '\artifacts\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $fixtureRoot)) { throw 'Launcher fixtures must be a new project artifacts child.' }
$gameRoot = Join-Path $fixtureRoot "game with spaces & apostrophe's"
$gameExe = Join-Path $gameRoot 'AzerothSurvivors.exe'
$updaterDirectory = Join-Path $gameRoot 'benilla-config\AddOns\AZSSpeedGear\Updater'
$updaterFile = Join-Path $updaterDirectory 'Update.ps1'
$nativeUpdaterFile = Join-Path $updaterDirectory 'NativeUpdate.ps1'
$oldUpdaterDirectory = Join-Path $fixtureRoot 'previous-updater'
$utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $updaterDirectory -Force | Out-Null
[IO.File]::WriteAllText($gameExe, 'inert launcher fixture; never executed', $utf8)
[IO.File]::WriteAllText($updaterFile, 'inert update fixture; never executed', $utf8)
. (Join-Path $projectRoot 'scripts\Start.ps1') -GamePath $gameExe
$script:checks = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    $script:checks++
}

function Reset-LauncherMocks {
    $script:processes = @()
    $script:events = @()
    $script:starts = @()
    $script:updateCalls = @()
    $script:scanCount = 0
    $script:cimFailure = $false
    $script:updateFailure = $false
    $script:helperFailure = $false
    $script:gameFailure = $false
    $script:startDuringUpdate = $false
    $script:replaceUpdater = $false
    $script:replaceWithNativeUpdater = $false
    $script:stopCalls = 0
}

# These mocks prevent every test branch from launching a process, running the
# updater, contacting the network, waiting on a game or terminating anything.
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    $script:scanCount++
    if ($script:cimFailure) { throw 'mocked process query failure' }
    if ($script:startDuringUpdate -and $script:scanCount -gt 1) {
        return [pscustomobject]@{ ProcessId = 505; ExecutablePath = $script:gameExe; Name = 'AzerothSurvivors.exe' }
    }
    return $script:processes
}

function Invoke-LauncherUpdate([string]$UpdaterPath, [string]$Executable) {
    $script:events += 'update'
    $script:updateCalls += [pscustomobject]@{
        UpdaterPath = $UpdaterPath; Executable = $Executable
        SkipEnvironment = [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')
    }
    if ($script:updateFailure) { throw 'mocked network failure' }
    if ($script:replaceUpdater) {
        $source = [IO.Path]::GetFullPath($script:updaterDirectory)
        $target = [IO.Path]::GetFullPath($script:oldUpdaterDirectory)
        foreach ($path in @($source, $target)) {
            if (-not $path.StartsWith($script:fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Mock updater move escaped its fixture root.'
            }
        }
        Move-Item -LiteralPath $source -Destination $target
        New-Item -ItemType Directory -Path $script:updaterDirectory -Force | Out-Null
        [IO.File]::WriteAllText($script:updaterFile, 'new installed updater generation', $script:utf8)
        if ($script:replaceWithNativeUpdater) {
            [IO.File]::WriteAllText($script:nativeUpdaterFile, 'new installed native host generation', $script:utf8)
        }
    }
    return [pscustomobject]@{ State = 'mock-check-returned'; CompatibilityVerified = $false }
}

function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$WorkingDirectory, [string[]]$ArgumentList, [string]$WindowStyle, [switch]$PassThru)
    $isGame = [string]::Equals($FilePath, $script:gameExe, [StringComparison]::OrdinalIgnoreCase)
    $script:events += $(if ($isGame) { 'start-game' } else { 'start-helper' })
    $script:starts += [pscustomobject]@{
        FilePath = $FilePath; WorkingDirectory = $WorkingDirectory
        ArgumentList = @($ArgumentList); WindowStyle = $WindowStyle; PassThru = [bool]$PassThru
        UpdaterContents = $(if (Test-Path -LiteralPath $script:updaterFile -PathType Leaf) { [IO.File]::ReadAllText($script:updaterFile) } else { $null })
        NativeUpdaterContents = $(if (Test-Path -LiteralPath $script:nativeUpdaterFile -PathType Leaf) { [IO.File]::ReadAllText($script:nativeUpdaterFile) } else { $null })
        SkipEnvironment = [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')
    }
    if ($isGame -and $script:gameFailure) { throw 'mocked game start failure' }
    if (-not $isGame -and $script:helperFailure) { throw 'mocked helper start failure' }
    return [pscustomobject]@{ Id = $(if ($isGame) { 404 } else { 405 }) }
}

function Stop-Process {
    [CmdletBinding()]
    param([int]$Id, [switch]$Force)
    $script:stopCalls++
    throw 'Launcher must never stop a game.'
}

function Invoke-Case {
    Start-AZSSpeedGearGame -SelectedGamePath $script:gameExe -WarningAction SilentlyContinue
}

Reset-LauncherMocks
$result = Invoke-Case
Assert-True ($result.Started -and $result.GameProcessId -eq 404) 'selected exact game starts after the check'
Assert-True ($script:updateCalls.Count -eq 1 -and $script:updateCalls[0].UpdaterPath -ceq $updaterFile) 'only installed updater is invoked synchronously'
Assert-True (($script:events -join ',') -ceq 'update,start-game,start-helper') 'update check completes before game and helper launch'
Assert-True ($script:starts.Count -eq 2 -and $script:starts[0].FilePath -ceq $gameExe) 'game launch uses exact selected EXE'
Assert-True ($script:starts[0].WorkingDirectory -ceq $gameRoot) 'game working directory is exact game folder'
Assert-True ($script:starts[1].WindowStyle -ceq 'Hidden' -and $result.ExitHelperStarted) 'exit updater is a hidden background process'
Assert-True ($result.UpdateState -ceq 'returned' -and -not $result.UpdateOutput[0].CompatibilityVerified) 'launcher never upgrades a returned check into compatibility verification'
$arguments = $script:starts[1].ArgumentList
$encodedIndex = [Array]::IndexOf($arguments, '-EncodedCommand')
Assert-True ($encodedIndex -ge 0 -and $encodedIndex + 1 -lt $arguments.Count) 'helper uses encoded arguments rather than shell interpolation'
$decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($arguments[$encodedIndex + 1]))
Assert-True ($decoded.Contains("& '" + $updaterFile.Replace("'", "''") + "'")) 'helper uses the newly located installed updater path'
Assert-True ($decoded.Contains("-GamePath '" + $gameExe.Replace("'", "''") + "'")) 'paths containing spaces and apostrophes remain literal'
Assert-True ($decoded.Contains('-WaitForExit') -and -not $decoded.Contains('-ProcessId')) 'updater owns waiting for all selected game instances'
Assert-True ($script:stopCalls -eq 0) 'normal launch never closes a game'

Reset-LauncherMocks
$script:processes = @([pscustomobject]@{ ProcessId = 888; ExecutablePath = $gameExe; Name = 'AzerothSurvivors.exe' })
$result = Invoke-Case
Assert-True ($result.AlreadyRunning -and -not $result.Started) 'running selected game is not started twice'
Assert-True ($script:updateCalls.Count -eq 0 -and $script:starts.Count -eq 0 -and $script:stopCalls -eq 0) 'running game is neither changed nor closed'

Reset-LauncherMocks
$script:processes = @([pscustomobject]@{ ProcessId = 889; ExecutablePath = $null; Name = 'AzerothSurvivors.exe' })
$result = Invoke-Case
Assert-True ($result.AlreadyRunning -and $script:starts.Count -eq 0) 'unknown same-name process path cannot create a duplicate'

Reset-LauncherMocks
$script:updateFailure = $true
$result = Invoke-Case
Assert-True ($result.Started -and $result.UpdateState -ceq 'failed' -and $result.UpdateError -match 'network') 'network failure still starts installed game with explicit failed check'
Assert-True ($result.ExitHelperStarted) 'exit-time helper can retry after failed startup check'

Reset-LauncherMocks
$result = Start-AZSSpeedGearGame -SelectedGamePath $gameRoot -SkipUpdate -WarningAction SilentlyContinue
Assert-True ($result.Started -and $result.UpdateState -ceq 'skipped' -and -not $result.UpdateAttempted) 'SkipUpdate explicitly omits startup network check'
Assert-True ($script:updateCalls.Count -eq 0 -and $script:starts.Count -eq 1 -and -not $result.ExitHelperStarted) 'SkipUpdate also omits later network helper'

Reset-LauncherMocks
$script:startDuringUpdate = $true
$result = Invoke-Case
Assert-True ($result.AlreadyRunning -and $result.UpdateAttempted -and $script:starts.Count -eq 0) 'game started during update is caught by second process check'

Reset-LauncherMocks
$script:replaceUpdater = $true
$result = Invoke-Case
Assert-True ($result.Started -and $result.ExitHelperStarted) 'replacing updater directory does not break launch'
Assert-True ($script:starts[1].UpdaterContents -ceq 'new installed updater generation') 'helper launch uses fresh installed updater after old directory moves'

Reset-LauncherMocks
$script:helperFailure = $true
$result = Invoke-Case
Assert-True ($result.Started -and -not $result.ExitHelperStarted -and $result.ExitHelperError -match 'helper') 'helper failure does not hide successful game start'

Reset-LauncherMocks
$heldUpdater = Join-Path $fixtureRoot 'held-updater.ps1'
Move-Item -LiteralPath $updaterFile -Destination $heldUpdater
try {
    $result = Invoke-Case
    Assert-True ($result.Started -and $result.UpdateState -ceq 'failed') 'missing installed updater still permits existing game launch'
    Assert-True (-not $result.ExitHelperStarted -and $null -ne $result.ExitHelperError) 'missing helper is reported without executing another updater location'
} finally { Move-Item -LiteralPath $heldUpdater -Destination $updaterFile }

Reset-LauncherMocks
$script:cimFailure = $true
$refused = $false
try { Invoke-Case | Out-Null } catch { $refused = $_.Exception.Message -match 'process query' }
Assert-True ($refused -and $script:starts.Count -eq 0 -and $script:updateCalls.Count -eq 0) 'failed process inventory cannot silently launch a duplicate'

Reset-LauncherMocks
[IO.File]::WriteAllText($nativeUpdaterFile, 'inert native lifecycle host; never executed', $utf8)
$result = Invoke-Case
Assert-True ($result.Started -and $result.ExitHelperStarted -and $script:starts[1].WindowStyle -ceq 'Hidden') 'native lifecycle helper remains hidden'
$nativeArguments = $script:starts[1].ArgumentList
$nativeEncodedIndex = [Array]::IndexOf($nativeArguments, '-EncodedCommand')
$nativeDecoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($nativeArguments[$nativeEncodedIndex + 1]))
Assert-True ($nativeDecoded.Contains("& '" + $nativeUpdaterFile.Replace("'", "''") + "'")) 'new launcher invokes the same installed NativeUpdate host as the native trigger'
Assert-True ($nativeDecoded.Contains("-GamePath '" + $gameExe.Replace("'", "''") + "'") -and -not $nativeDecoded.Contains('-WaitForExit')) 'native host owns staging and exit waiting without duplicate launcher wait mode'

Reset-LauncherMocks
$script:replaceUpdater = $true
$script:replaceWithNativeUpdater = $true
$script:oldUpdaterDirectory = Join-Path $fixtureRoot 'previous-native-updater'
$result = Invoke-Case
Assert-True ($result.Started -and $result.ExitHelperStarted -and
    $script:starts[1].NativeUpdaterContents -ceq 'new installed native host generation') 'native lifecycle helper is relocated after synchronous directory replacement'
$nativeArguments = $script:starts[1].ArgumentList
$nativeEncodedIndex = [Array]::IndexOf($nativeArguments, '-EncodedCommand')
$nativeDecoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($nativeArguments[$nativeEncodedIndex + 1]))
Assert-True ($nativeDecoded.Contains("& '" + $nativeUpdaterFile.Replace("'", "''") + "'")) 'relocation never launches the backed-up old host path'

$environmentBeforeCases = [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')
try {
    Reset-LauncherMocks
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', [NullString]::Value, 'Process')
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')) 'explicit null fixture really removes the variable'
    $result = Start-AZSSpeedGearGame -SelectedGamePath $gameExe -SkipUpdate -WarningAction SilentlyContinue
    Assert-True ($script:starts.Count -eq 1 -and $script:starts[0].SkipEnvironment -ceq '1') 'SkipUpdate is inherited by only the launched game'
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')) 'absent parent environment restored after SkipUpdate launch'
    Assert-True ($script:updateCalls.Count -eq 0 -and -not $result.ExitHelperStarted) 'SkipUpdate schedules neither network path nor lifecycle helper'

    # .NET 9 can represent an existing empty value; older runtimes delete it.
    # Exercise preservation only where the runtime can create that distinct case.
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', [string]::Empty, 'Process')
    if ($null -ne [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')) {
        Reset-LauncherMocks
        $result = Start-AZSSpeedGearGame -SelectedGamePath $gameExe -SkipUpdate -WarningAction SilentlyContinue
        $restoredEmpty = [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')
        Assert-True ($script:starts[0].SkipEnvironment -ceq '1' -and $null -ne $restoredEmpty -and $restoredEmpty -ceq '') 'SkipUpdate preserves an existing empty value rather than deleting it'
        Reset-LauncherMocks
        $result = Invoke-Case
        $restoredEmpty = [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')
        Assert-True ($null -ne $script:starts[0].SkipEnvironment -and $script:starts[0].SkipEnvironment -ceq '' -and
            $null -ne $restoredEmpty -and $restoredEmpty -ceq '') 'normal launch preserves distinct empty parent and child values'
    }

    Reset-LauncherMocks
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'preserve-me', 'Process')
    $result = Start-AZSSpeedGearGame -SelectedGamePath $gameExe -SkipUpdate -WarningAction SilentlyContinue
    Assert-True ($script:starts[0].SkipEnvironment -ceq '1' -and
        [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process') -ceq 'preserve-me') 'SkipUpdate restores a preexisting custom parent value'

    Reset-LauncherMocks
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', '1', 'Process')
    $result = Invoke-Case
    Assert-True ($null -eq $script:starts[0].SkipEnvironment) 'normal launch clears an inherited skip flag for the game only'
    Assert-True ($script:updateCalls[0].SkipEnvironment -ceq '1' -and $script:starts[1].SkipEnvironment -ceq '1') 'environment override excludes startup checks and background helper creation'
    Assert-True ([Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process') -ceq '1') 'normal launch restores inherited parent skip flag'

    Reset-LauncherMocks
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'preserve-me', 'Process')
    $result = Invoke-Case
    Assert-True ($script:starts[0].SkipEnvironment -ceq 'preserve-me' -and
        [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process') -ceq 'preserve-me') 'normal launch preserves non-skip custom values'

    Reset-LauncherMocks
    $script:gameFailure = $true
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'preserve-failure', 'Process')
    $refused = $false
    try { Start-AZSSpeedGearGame -SelectedGamePath $gameExe -SkipUpdate -WarningAction SilentlyContinue | Out-Null }
    catch { $refused = $_.Exception.Message -match 'game start failure' }
    Assert-True ($refused -and $script:starts[0].SkipEnvironment -ceq '1' -and
        [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process') -ceq 'preserve-failure') 'failed SkipUpdate CreateProcess restores original environment in finally'

    Reset-LauncherMocks
    $script:gameFailure = $true
    [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', '1', 'Process')
    $refused = $false
    try { Invoke-Case | Out-Null } catch { $refused = $_.Exception.Message -match 'game start failure' }
    Assert-True ($refused -and $null -eq $script:starts[0].SkipEnvironment -and
        [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process') -ceq '1') 'failed normal CreateProcess restores the inherited skip flag'
    Assert-True ($script:starts.Count -eq 1) 'failed game creation never starts a lifecycle helper'
} finally {
    if ($null -eq $environmentBeforeCases) {
        [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', [NullString]::Value, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', $environmentBeforeCases, 'Process')
    }
}

# Fixtures deliberately remain under artifacts for remote CI inspection. They
# contain only inert text files, and all external operations above were mocked.
Write-Output ("Launcher: {0} checks passed; no real game, updater or child process executed." -f $script:checks)

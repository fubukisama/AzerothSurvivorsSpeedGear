#requires -Version 5.1
[CmdletBinding()]
param()

# Written for remote Windows CI only. All updater invocations, CIM observations,
# lifetime mutexes and logs are mocked. No fixture script or EXE is executed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePathBeforeLibrary = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::Process)
. (Join-Path $projectRoot 'scripts\NativeUpdate.ps1') -LibraryOnly
$modulePathAfterLibrary = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::Process)
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $temporaryBase ('AZSSpeedGear-native-updater-tests-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith($temporaryBase + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $fixtureRoot)) { throw 'Unsafe fixture path.' }
$gameRoot = Join-Path $fixtureRoot 'game'
$gameExe = Join-Path $gameRoot 'AzerothSurvivors.exe'
$updater = Join-Path $gameRoot 'benilla-config\AddOns\AZSSpeedGear\Updater\Update.ps1'
$receiptPath = Join-Path $gameRoot 'benilla-config\AZSSpeedGear-install.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$script:checks = 0

function Assert-NativeTest([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:checks++
}

# Exercise host initialization through pure fakes. These calls cannot alter the
# CI process's own module path, user/machine settings, or any game environment.
$script:hostFolderCalls = 0
$script:modulePathAssignments = @()
$script:fakeHostFolders = [pscustomobject]@{
    Home = 'C:\FixtureWindows\System32\WindowsPowerShell\v1.0'
    ProgramFiles = 'C:\FixtureProgramFiles'
    Documents = 'C:\FixtureDocuments'
}
function Get-AZSGNativeHostFolders {
    $script:hostFolderCalls++
    return $script:fakeHostFolders
}
function Set-AZSGNativeProcessModulePath([string]$Value) {
    $script:modulePathAssignments += $Value
}
Assert-NativeTest ($modulePathBeforeLibrary -ceq $modulePathAfterLibrary) 'LibraryOnly preserves its caller PSModulePath'
Initialize-AZSGNativeHostEnvironment -Edition 'Desktop' -LibraryMode $true
Initialize-AZSGNativeHostEnvironment -Edition 'Core' -LibraryMode $false
Assert-NativeTest ($script:hostFolderCalls -eq 0 -and $script:modulePathAssignments.Count -eq 0) 'library and Core modes do not initialize host environment'
Initialize-AZSGNativeHostEnvironment -Edition 'Desktop' -LibraryMode $false
$expectedModulePath = 'C:\FixtureWindows\System32\WindowsPowerShell\v1.0\Modules;C:\FixtureProgramFiles\WindowsPowerShell\Modules;C:\FixtureDocuments\WindowsPowerShell\Modules'
Assert-NativeTest ($script:hostFolderCalls -eq 1 -and $script:modulePathAssignments.Count -eq 1) 'Desktop run initializes its module path once'
Assert-NativeTest ($script:modulePathAssignments[0] -ceq $expectedModulePath) 'system PSHOME modules precede known-folder module paths'
Assert-NativeTest (([Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::Process)) -ceq $modulePathBeforeLibrary) 'environment mocks never mutate the CI host'

function Save-NativeReceipt([string]$Version = '0.5.0') {
    $files = @([pscustomobject]@{
        RelativePath = 'benilla-config\AddOns\AZSSpeedGear\Updater\Update.ps1'
        SHA256 = (Get-FileHash -LiteralPath $script:updater -Algorithm SHA256).Hash
        Bytes = (Get-Item -LiteralPath $script:updater).Length
    })
    $receipt = [ordered]@{ Product = 'AZSSpeedGear'; SchemaVersion = 1; Version = $Version
        GameExecutable = $script:gameExe; ManagedFiles = $files }
    [IO.File]::WriteAllText($script:receiptPath, ($receipt | ConvertTo-Json -Depth 7), $script:utf8)
}

function Reset-NativeScenario {
    $script:events = @(); $script:calls = @(); $script:logs = @(); $script:mutexNames = @()
    $script:enterAllowed = $true; $script:lifetimeHeld = $false
    $script:releaseCount = 0; $script:closeCount = 0; $script:failImmediate = $false
    $script:replaceAfterImmediate = $false; $script:removeAfterImmediate = $false
    $script:runningReplies = [Collections.Queue]::new()
    $script:runningReplies.Enqueue($true); $script:runningReplies.Enqueue($true); $script:runningReplies.Enqueue($false)
    [IO.File]::WriteAllText($script:updater, '# inert old updater fixture', $script:utf8)
    Save-NativeReceipt
}

# The only created mutex must be the helper-lifetime mutex. There is no fake
# launcher lock to hide an accidental long-held launcher acquisition.
function New-AZSGNativeMutex([string]$Name) {
    $script:mutexNames += $Name
    return [pscustomobject]@{ Name = $Name }
}
function Enter-AZSGNativeMutex($Mutex) {
    $script:events += 'mutex_enter'
    $script:lifetimeHeld = $script:enterAllowed
    return $script:enterAllowed
}
function Release-AZSGNativeMutex($Mutex) {
    Assert-NativeTest $script:lifetimeHeld 'only an owned lifetime mutex is released'
    $script:lifetimeHeld = $false; $script:releaseCount++; $script:events += 'mutex_release'
}
function Close-AZSGNativeMutex($Mutex) { $script:closeCount++; $script:events += 'mutex_close' }
function Write-AZSGNativeLog($Game, [string]$Event, [string]$Message) {
    $script:logs += [pscustomobject]@{ Product = 'AzerothSurvivorsSpeedGear'; Event = $Event; Message = $Message }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    Assert-NativeTest ($ClassName -eq 'Win32_Process') 'process query remains scoped to CIM game observations'
    $script:events += 'cim'
    if ($script:runningReplies.Count -gt 0 -and $script:runningReplies.Dequeue()) {
        return [pscustomobject]@{ ExecutablePath = $script:gameExe; ProcessId = 4242 }
    }
}
function Invoke-AZSGNativeUpdateStep([string]$UpdaterPath, [string]$Executable, [switch]$WaitForExit) {
    Assert-NativeTest $script:lifetimeHeld 'helper lock spans both updater calls'
    Assert-NativeTest ($UpdaterPath -ieq $script:updater -and $Executable -ieq $script:gameExe) 'only the fixed updater and selected game are invoked'
    $script:calls += [pscustomobject]@{ WaitForExit = [bool]$WaitForExit; Hash = (Get-FileHash -LiteralPath $UpdaterPath).Hash }
    if (-not $WaitForExit) {
        $script:events += 'immediate'
        $running = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='AzerothSurvivors.exe'")
        if ($script:failImmediate) { throw 'Mock network unavailable during first check.' }
        if ($script:replaceAfterImmediate) {
            $oldDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $script:updater))
            $backupDirectory = [IO.Path]::GetFullPath((Join-Path $script:fixtureRoot ('old-updater-' + [guid]::NewGuid().ToString('N'))))
            if (-not $oldDirectory.StartsWith($script:fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                -not $backupDirectory.StartsWith($script:fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Fixture directory swap escaped its test root.'
            }
            Move-Item -LiteralPath $oldDirectory -Destination $backupDirectory
            New-Item -ItemType Directory -Path $oldDirectory | Out-Null
            [IO.File]::WriteAllText($script:updater, '# inert new updater fixture', $script:utf8)
            Save-NativeReceipt '0.6.0'
        }
        if ($script:removeAfterImmediate) {
            Move-Item -LiteralPath $script:updater -Destination (Join-Path $script:fixtureRoot 'retained-old-updater.ps1')
        }
        return [pscustomobject]@{ status = $(if ($running.Count) { 'pending' } else { 'up_to_date' }) }
    }
    $script:events += 'wait'
    Assert-NativeTest (@($script:mutexNames | Where-Object { $_ -like 'Local\AZSSpeedGearLauncher_*' }).Count -eq 0) 'no launcher/update mutex is held while waiting'
    $polls = 0
    while (@(Get-CimInstance -ClassName Win32_Process -Filter "Name='AzerothSurvivors.exe'").Count -gt 0) {
        $polls++
        if ($polls -gt 4) { throw 'Mock process queue failed to terminate.' }
    }
    $script:events += 'install'
    return [pscustomobject]@{ status = 'installed' }
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $updater) -Force | Out-Null
    [IO.File]::WriteAllBytes($gameExe, [byte[]]@(0x4d, 0x5a))
    Reset-NativeScenario
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'completed') 'immediate stage and wait/install complete'
    Assert-NativeTest ($script:calls.Count -eq 2 -and -not $script:calls[0].WaitForExit -and $script:calls[1].WaitForExit) 'immediate call precedes wait-for-exit call'
    Assert-NativeTest ([array]::IndexOf($script:events, 'immediate') -lt [array]::IndexOf($script:events, 'wait')) 'stage is attempted before waiting'
    Assert-NativeTest ($script:releaseCount -eq 1 -and $script:closeCount -eq 1 -and -not $script:lifetimeHeld) 'lifetime lock is released and closed'
    Assert-NativeTest ($script:mutexNames.Count -eq 1 -and $script:mutexNames[0] -match '^Local\\AZSSpeedGearNativeUpdater_[A-F0-9]{64}$') 'independent mutex namespace'
    Assert-NativeTest (@($script:logs | Where-Object Product -cne 'AzerothSurvivorsSpeedGear').Count -eq 0) 'log product name'
    $canonicalName = Get-AZSGNativeMutexName $gameExe
    Assert-NativeTest ($canonicalName -ceq (Get-AZSGNativeMutexName ($gameExe.ToLowerInvariant()))) 'mutex identity is case invariant'

    Reset-NativeScenario; $script:failImmediate = $true
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameRoot
    Assert-NativeTest ($result.status -eq 'completed' -and $result.immediateCheck -eq 'failed' -and $result.exitCheck -eq 'completed') 'first network failure still performs exit-time check'
    Assert-NativeTest ($script:calls.Count -eq 2 -and $script:calls[1].WaitForExit) 'exit invocation survives initial exception'
    Assert-NativeTest (@($script:logs | Where-Object Event -eq 'immediate_check_failed').Count -eq 1) 'initial failure remains visible in the log'

    Reset-NativeScenario; $script:enterAllowed = $false
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'already_running' -and $script:calls.Count -eq 0) 'duplicate helper skips all updater work'
    Assert-NativeTest ($script:releaseCount -eq 0 -and $script:closeCount -eq 1) 'duplicate helper does not release another owner lock'

    Reset-NativeScenario; $script:runningReplies.Clear()
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'completed' -and $script:calls.Count -eq 2) 'already-exited game still receives both checks'

    Reset-NativeScenario
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.GameExecutable = Join-Path $fixtureRoot 'another\AzerothSurvivors.exe'
    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 7), $utf8)
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'failed' -and $script:calls.Count -eq 0) 'foreign-game receipt never executes an updater'

    Reset-NativeScenario
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.Product = 'AnotherProduct'
    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 7), $utf8)
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'failed' -and $script:calls.Count -eq 0) 'foreign product receipt never executes an updater'

    Reset-NativeScenario
    [IO.File]::WriteAllText($updater, '# changed without receipt update', $utf8)
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'failed' -and $script:calls.Count -eq 0) 'bad updater hash never executes'

    Reset-NativeScenario
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.ManagedFiles[0].RelativePath = 'benilla-config\AddOns\AZSSpeedGear\Updater\Other.ps1'
    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 7), $utf8)
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'failed' -and $script:calls.Count -eq 0) 'receipt cannot choose another script'

    Reset-NativeScenario; $script:replaceAfterImmediate = $true
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'completed' -and $script:calls.Count -eq 2) 'script replacement triggers fresh ownership validation'
    Assert-NativeTest ($script:calls[0].Hash -ne $script:calls[1].Hash) 'exit invocation resolves the new updater bytes'

    Reset-NativeScenario; $script:removeAfterImmediate = $true
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $gameExe
    Assert-NativeTest ($result.status -eq 'failed' -and $script:calls.Count -eq 1) 'missing relocated updater cannot reach the wait invocation'
    Assert-NativeTest (-not $script:lifetimeHeld) 'failed revalidation releases the lifetime lock'

    [pscustomobject]@{ Passed = $true; Checks = $checks; RealGameTouched = $false; UpdaterScriptsExecuted = $false } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).ProviderPath
        $item = Get-Item -LiteralPath $fixtureRoot -Force
        if ($resolved -ieq $fixtureRoot -and $resolved.StartsWith($temporaryBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        } else { Write-Warning 'Fixture cleanup refused an unexpected path.' }
    }
}

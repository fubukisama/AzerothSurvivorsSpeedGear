#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GamePath,
    [switch]$SkipUpdate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-LauncherGame([string]$SelectedPath) {
    $candidate = [IO.Path]::GetFullPath($SelectedPath)
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $candidate = Join-Path $candidate 'AzerothSurvivors.exe'
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
        [IO.Path]::GetFileName($candidate) -ine 'AzerothSurvivors.exe') {
        throw 'GamePath must select an existing AzerothSurvivors.exe or its directory.'
    }
    return [IO.Path]::GetFullPath((Get-Item -LiteralPath $candidate).FullName)
}

function Get-LauncherGameProcesses([string]$Executable) {
    foreach ($item in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'AzerothSurvivors.exe'" -ErrorAction Stop)) {
        # An inaccessible same-name process cannot safely be ruled out.
        if ([string]::IsNullOrWhiteSpace([string]$item.ExecutablePath)) { $item; continue }
        try { $observed = [IO.Path]::GetFullPath([string]$item.ExecutablePath) }
        catch { $item; continue }
        if ([string]::Equals($observed, $Executable, [StringComparison]::OrdinalIgnoreCase)) { $item }
    }
}

function Get-LauncherUpdater([string]$Executable) {
    $directory = Split-Path -Parent $Executable
    $path = [IO.Path]::GetFullPath((Join-Path $directory 'benilla-config\AddOns\AZSSpeedGear\Updater\Update.ps1'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'The installed AZSSpeedGear Updater/Update.ps1 was not found; install the complete plugin package.'
    }
    return $path
}

function Invoke-LauncherUpdate([string]$UpdaterPath, [string]$Executable) {
    # The updater owns network policy, package checks and compatibility decisions.
    # Merely returning from it is not a claim that compatibility was verified.
    & $UpdaterPath -GamePath $Executable
}

function Get-LauncherPowerShell {
    $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        throw 'The Windows PowerShell host needed for the background update helper was not found.'
    }
    return $hostPath
}

function Start-LauncherExitHelper([string]$Executable) {
    # Resolve again AFTER the synchronous update: that update may have moved the
    # old Updater directory and installed an entirely new copy in its place.
    $updaterDirectory = Join-Path (Split-Path -Parent $Executable) 'benilla-config\AddOns\AZSSpeedGear\Updater'
    $nativeHost = [IO.Path]::GetFullPath((Join-Path $updaterDirectory 'NativeUpdate.ps1'))
    $waitArgument = ''
    if (Test-Path -LiteralPath $nativeHost -PathType Leaf) {
        # The native trigger and this fallback use the same host and its
        # per-game lifecycle mutex. Only one stages now and installs after exit.
        $updater = $nativeHost
    } else {
        $updater = Get-LauncherUpdater $Executable
        $waitArgument = ' -WaitForExit'
    }
    $hostPath = Get-LauncherPowerShell
    $updaterLiteral = $updater.Replace("'", "''")
    $gameLiteral = $Executable.Replace("'", "''")
    $command = "& '$updaterLiteral' -GamePath '$gameLiteral'$waitArgument"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $helper = Start-Process -FilePath $hostPath -WorkingDirectory (Split-Path -Parent $Executable) `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden -PassThru -ErrorAction Stop
    return [pscustomobject]@{ Started = $true; ProcessId = [int]$helper.Id; UpdaterPath = $updater }
}

function Get-LauncherMutexName([string]$Executable) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Executable.ToUpperInvariant())
        $digest = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '')
        return 'Local\AZSSpeedGearLauncher_' + $digest
    } finally { $algorithm.Dispose() }
}

function Start-AZSSpeedGearGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SelectedGamePath,
        [switch]$SkipUpdate
    )

    $executable = Resolve-LauncherGame $SelectedGamePath
    $result = [ordered]@{
        Product = 'AzerothSurvivorsSpeedGear'
        GameExecutable = $executable
        Started = $false
        AlreadyRunning = $false
        LaunchInProgress = $false
        GameProcessId = $null
        ExistingProcessIds = @()
        UpdateAttempted = $false
        UpdateState = $(if ($SkipUpdate) { 'skipped' } else { 'not_attempted' })
        UpdateOutput = @()
        UpdateError = $null
        ExitHelperStarted = $false
        ExitHelperProcessId = $null
        ExitHelperError = $null
    }
    $mutex = [Threading.Mutex]::new($false, (Get-LauncherMutexName $executable))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) {
            $result.LaunchInProgress = $true
            Write-Warning 'Another launch/update task is still in progress; the game was not started. Try again shortly.'
            return [pscustomobject]$result
        }

        $running = @(Get-LauncherGameProcesses $executable)
        if ($running.Count -gt 0) {
            $result.AlreadyRunning = $true
            $result.ExistingProcessIds = @($running | ForEach-Object { [int]$_.ProcessId })
            return [pscustomobject]$result
        }

        if (-not $SkipUpdate) {
            $result.UpdateAttempted = $true
            try {
                $updater = Get-LauncherUpdater $executable
                $result.UpdateOutput = @(Invoke-LauncherUpdate -UpdaterPath $updater -Executable $executable)
                $result.UpdateState = 'returned'
            } catch {
                $result.UpdateState = 'failed'
                $result.UpdateError = $_.Exception.Message
                Write-Warning ('Plugin update check failed; starting the existing game without confirming compatibility. ' + $_.Exception.Message)
            }
        }

        # A user may have started the game manually while the network request ran.
        $running = @(Get-LauncherGameProcesses $executable)
        if ($running.Count -gt 0) {
            $result.AlreadyRunning = $true
            $result.ExistingProcessIds = @($running | ForEach-Object { [int]$_.ProcessId })
            return [pscustomobject]$result
        }
        # Change only this parent process's environment during CreateProcess.
        # Neither the synchronous update nor the later helper sees this override.
        $previousSkip = [Environment]::GetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', 'Process')
        try {
            if ($SkipUpdate) { [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', '1', 'Process') }
            elseif ($previousSkip -ceq '1') { [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', [NullString]::Value, 'Process') }
            $game = Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) -PassThru -ErrorAction Stop
        } finally {
            # .NET 9 preserves empty values; PowerShell's ordinary $null binds
            # to an empty string here. Preserve absence separately from empty.
            if ($null -eq $previousSkip) {
                [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', [NullString]::Value, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable('AZSSPEEDGEAR_SKIP_UPDATE', $previousSkip, 'Process')
            }
        }
        $result.Started = $true
        $result.GameProcessId = [int]$game.Id

        if (-not $SkipUpdate) {
            try {
                $helper = Start-LauncherExitHelper $executable
                $result.ExitHelperStarted = $helper.Started
                $result.ExitHelperProcessId = $helper.ProcessId
            } catch {
                $result.ExitHelperError = $_.Exception.Message
                Write-Warning ('The game started, but the background plugin update helper could not be scheduled. ' + $_.Exception.Message)
            }
        }
        return [pscustomobject]$result
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Dot-sourcing exposes the functions for mocked CI tests without launching or
# checking anything. Normal -File invocation is the user-facing launch entry.
if ($MyInvocation.InvocationName -ne '.') {
    Start-AZSSpeedGearGame -SelectedGamePath $GamePath -SkipUpdate:$SkipUpdate | ConvertTo-Json -Depth 8
}

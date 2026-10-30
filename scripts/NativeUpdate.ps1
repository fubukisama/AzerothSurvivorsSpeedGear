#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$GamePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Library')]
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AZSGNativeFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty game path is not allowed.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    return $full
}

function Assert-AZSGNativeNoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $link = $item.PSObject.Properties['LinkType']
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($null -ne $link -and -not [string]::IsNullOrEmpty([string]$link.Value))) {
                throw 'Native updater paths must not contain links or reparse points.'
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Get-AZSGNativeGame([string]$SelectedPath) {
    $exe = Get-AZSGNativeFullPath $SelectedPath
    if (Test-Path -LiteralPath $exe -PathType Container) { $exe = Join-Path $exe 'AzerothSurvivors.exe' }
    if ([IO.Path]::GetFileName($exe) -ine 'AzerothSurvivors.exe' -or
        -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw 'GamePath must identify AzerothSurvivors.exe or its directory.'
    }
    Assert-AZSGNativeNoLinks $exe
    return [pscustomobject]@{ Executable = $exe; Root = (Split-Path -Parent $exe) }
}

function Get-AZSGNativeMutexName([string]$Executable) {
    $canonical = Get-AZSGNativeFullPath $Executable
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical.ToUpperInvariant())
        $digest = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '')
        return 'Local\AZSSpeedGearNativeUpdater_' + $digest
    } finally { $algorithm.Dispose() }
}

# These small wrappers are replaced by CI fakes. The production helper owns one
# distinct lifetime mutex; it never creates/acquires the launcher/update mutex.
function New-AZSGNativeMutex([string]$Name) { return [Threading.Mutex]::new($false, $Name) }
function Enter-AZSGNativeMutex($Mutex) {
    try { return $Mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { return $true }
}
function Release-AZSGNativeMutex($Mutex) { $Mutex.ReleaseMutex() }
function Close-AZSGNativeMutex($Mutex) { $Mutex.Dispose() }

function Read-AZSGNativeReceipt([string]$Path) {
    Assert-AZSGNativeNoLinks $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The installed AZSSpeedGear receipt is missing.' }
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 1MB) { throw 'The installation receipt is oversized.' }
        $buffer = New-Object byte[] (1MB + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt 1MB) { throw 'The installation receipt is oversized.' }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $count)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) { $text = $text.Substring(1) }
        return (ConvertFrom-Json -InputObject $text)
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-AZSGNativeTrustedUpdater($Game) {
    # The path is fixed by our package layout. A receipt can prove its hash, but
    # can never select a different script for this helper to execute.
    $relative = 'benilla-config\AddOns\AZSSpeedGear\Updater\Update.ps1'
    $path = Get-AZSGNativeFullPath (Join-Path $Game.Root $relative)
    $receiptPath = Join-Path $Game.Root 'benilla-config\AZSSpeedGear-install.json'
    $receipt = Read-AZSGNativeReceipt $receiptPath
    if ($null -eq $receipt -or $receipt -isnot [pscustomobject] -or
        [string]$receipt.Product -cne 'AZSSpeedGear' -or $receipt.SchemaVersion -ne 1 -or
        (Get-AZSGNativeFullPath ([string]$receipt.GameExecutable)) -ine $Game.Executable -or
        $receipt.ManagedFiles -isnot [array]) {
        throw 'The installation receipt does not belong to the selected game.'
    }
    $ownedEntries = @($receipt.ManagedFiles | Where-Object {
        [string]$_.RelativePath -and ([string]$_.RelativePath).Replace('/', '\') -ieq $relative
    })
    if ($ownedEntries.Count -ne 1 -or [string]$ownedEntries[0].SHA256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'The fixed updater script is not uniquely receipt-owned.'
    }
    Assert-AZSGNativeNoLinks $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 1MB) {
        throw 'The installed updater script is missing or oversized.'
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ine [string]$ownedEntries[0].SHA256) { throw 'The installed updater script failed its receipt SHA-256 check.' }
    return [pscustomobject]@{ Path = $path; SHA256 = $actual; ReceiptPath = $receiptPath }
}

function Write-AZSGNativeLog($Game, [string]$Event, [string]$Message) {
    # Logging is best effort: a logging error must not prevent the second,
    # exit-time attempt after an initial network failure.
    try {
        $directory = Join-Path $Game.Root 'benilla-config\AZSSpeedGear-updates'
        $path = Join-Path $directory 'native-update.log'
        Assert-AZSGNativeNoLinks $path
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        if ($Message.Length -gt 2048) { $Message = $Message.Substring(0, 2048) }
        $record = [ordered]@{
            schema = 1; product = 'AzerothSurvivorsSpeedGear'; checkedUtc = [DateTime]::UtcNow.ToString('o')
            event = $Event; message = $Message
        }
        $line = ($record | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine
        [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
    } catch {
        # No alternative log file, preference, save or global setting is used.
    }
}

function Invoke-AZSGNativeUpdateStep([string]$UpdaterPath, [string]$Executable, [switch]$WaitForExit) {
    if ($WaitForExit) { & $UpdaterPath -GamePath $Executable -WaitForExit }
    else { & $UpdaterPath -GamePath $Executable }
}

function Invoke-AZSGNativeUpdateSession([string]$SelectedGamePath) {
    $result = [pscustomobject][ordered]@{
        schema = 1; product = 'AzerothSurvivorsSpeedGear'; status = 'failed'
        gameExecutable = $null; mutexName = $null; logPath = $null
        immediateCheck = 'not_attempted'; immediateError = $null
        exitCheck = 'not_attempted'; reason = $null
    }
    $game = $null; $mutex = $null; $held = $false
    try {
        $game = Get-AZSGNativeGame $SelectedGamePath
        $result.gameExecutable = $game.Executable
        $result.logPath = Join-Path $game.Root 'benilla-config\AZSSpeedGear-updates\native-update.log'
        $result.mutexName = Get-AZSGNativeMutexName $game.Executable
        $mutex = New-AZSGNativeMutex $result.mutexName
        $held = Enter-AZSGNativeMutex $mutex
        if (-not $held) {
            $result.status = 'already_running'
            return $result
        }
        $trusted = Get-AZSGNativeTrustedUpdater $game
        Write-AZSGNativeLog $game 'session_started' 'Native updater lifetime lock acquired.'
        try {
            Write-AZSGNativeLog $game 'immediate_check_started' 'Checking and staging without stopping the running game.'
            $result.immediateCheck = 'running'
            $null = Invoke-AZSGNativeUpdateStep -UpdaterPath $trusted.Path -Executable $game.Executable
            $result.immediateCheck = 'completed'
            Write-AZSGNativeLog $game 'immediate_check_completed' 'The immediate update invocation returned.'
        } catch {
            $result.immediateCheck = 'failed'
            $result.immediateError = $_.Exception.Message
            Write-AZSGNativeLog $game 'immediate_check_failed' $result.immediateError
        }
        # The first invocation may have installed a release and moved the old
        # Updater directory. Resolve the canonical path and the NEW receipt now.
        $trusted = Get-AZSGNativeTrustedUpdater $game
        $result.exitCheck = 'running'
        Write-AZSGNativeLog $game 'exit_check_started' 'Waiting for all selected-game instances to exit before checking and installing.'
        # This helper holds only its own lifetime mutex. Update.ps1 -WaitForExit
        # waits before acquiring its short-lived launcher/install mutex.
        $null = Invoke-AZSGNativeUpdateStep -UpdaterPath $trusted.Path -Executable $game.Executable -WaitForExit
        $result.exitCheck = 'completed'
        $result.status = 'completed'
        Write-AZSGNativeLog $game 'session_completed' 'Exit-time check returned; this does not claim gameplay compatibility.'
    } catch {
        $result.status = 'failed'
        $result.reason = $_.Exception.Message
        if ($result.exitCheck -eq 'running') { $result.exitCheck = 'failed' }
        if ($null -ne $game) { Write-AZSGNativeLog $game 'session_failed' $result.reason }
    } finally {
        if ($null -ne $mutex) {
            try { if ($held) { Release-AZSGNativeMutex $mutex } }
            finally { Close-AZSGNativeMutex $mutex }
        }
    }
    return $result
}

if (-not $LibraryOnly) {
    $result = Invoke-AZSGNativeUpdateSession -SelectedGamePath $GamePath
    $result | ConvertTo-Json -Depth 6
    if ($result.status -eq 'failed') { exit 1 }
    exit 0
}

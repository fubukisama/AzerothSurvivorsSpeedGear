#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GamePath,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Assert-InGame([string]$Path) {
    $full = Get-FullPath $Path
    if (-not $full.StartsWith($script:gameRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the selected game folder: $full"
    }
    return $full
}

function Assert-NoLinks([string]$Path, [switch]$Recursive) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $items = @(Get-Item -LiteralPath $Path -Force)
    if ($Recursive -and $items[0].PSIsContainer) { $items += @(Get-ChildItem -LiteralPath $Path -Force -Recurse) }
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Directory links and reparse points are not managed: $($item.FullName)"
        }
    }
}

function Assert-GameStopped {
    $name = [IO.Path]::GetFileName($script:gameExe).Replace("'", "''")
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = '$name'")) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
            (Get-FullPath ([string]$process.ExecutablePath)) -ieq $script:gameExe) {
            throw 'Close the selected game completely before uninstalling AZSSpeedGear.'
        }
    }
}

function Get-ManagedPath([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Invalid relative path in installation receipt.'
    }
    $relative = $RelativePath.Replace('/', '\')
    if (@($relative.Split('\') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }).Count -gt 0) {
        throw 'Invalid path component in installation receipt.'
    }
    if ($relative -ine 'dwmapi.dll' -and
        -not $relative.StartsWith('benilla-config\AddOns\AZSSpeedGear\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Receipt names an unmanaged file: $relative"
    }
    return Assert-InGame (Join-Path $script:gameRoot $relative)
}

function Assert-LocaleHint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Runtime locale hint is missing: $Path"
    }
    if ((Get-Item -LiteralPath $Path).Length -gt 256) { throw "Runtime locale hint is too large: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 256) { throw "Runtime locale hint is too large: $Path" }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $pattern = '\A-- AZSSpeedGear runtime locale hint\r?\nAZSSpeedGearNativeLocale = (?:nil|"(?:en|pl|cs|de|pt|es|fr|ro|tr|ru|uk|zh|ja|ko)");(?:\r?\n)?\z'
    if ($text -cnotmatch $pattern) {
        throw "Runtime locale hint contains an invalid header, language or Lua statement: $Path"
    }
}

function Test-AZSGOwnedTocNotes([string]$Path, [string]$RelativePath, [string]$ExpectedSHA256, $Receipt, [string]$GameRoot) {
    # Exact hashes remain the default. Only the root TOC's known Notes value is
    # mutable, and no code from a downloaded package is loaded for this check.
    if ($RelativePath -cne 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc') { return $false }
    try {
        $expectedPath = [IO.Path]::GetFullPath([IO.Path]::Combine($GameRoot, $RelativePath))
        if (-not [string]::Equals([IO.Path]::GetFullPath($Path), $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $libraryRelative = 'benilla-config\AddOns\AZSSpeedGear\Updater\TocNotes.ps1'
        $entries = @($Receipt.ManagedFiles | Where-Object { [string]$_.RelativePath -ceq $libraryRelative })
        if ($entries.Count -ne 1 -or [string]$entries[0].SHA256 -cnotmatch '^[a-fA-F0-9]{64}$') { return $false }
        $library = [IO.Path]::GetFullPath([IO.Path]::Combine($GameRoot, $libraryRelative))
        $current = $library
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $current = [IO.Path]::GetDirectoryName($current)
        }
        $readBounded = {
            param([string]$Name, [int]$Maximum)
            $stream = [IO.File]::Open($Name, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                if ($stream.Length -gt $Maximum) { throw 'Receipt-owned metadata file exceeds its size limit.' }
                $payload = [byte[]]::new([int]$stream.Length)
                $offset = 0
                while ($offset -lt $payload.Length) {
                    $count = $stream.Read($payload, $offset, $payload.Length - $offset)
                    if ($count -eq 0) { throw 'Receipt-owned metadata file changed while reading.' }
                    $offset += $count
                }
                return ,$payload
            } finally { $stream.Dispose() }
        }
        $libraryBytes = & $readBounded $library 65536
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $libraryHash = [BitConverter]::ToString($algorithm.ComputeHash($libraryBytes)).Replace('-', '') }
        finally { $algorithm.Dispose() }
        if ($libraryHash -ine [string]$entries[0].SHA256) { return $false }
        # Execute the bytes just verified, avoiding a second path read between
        # hash verification and loading. Old receipts without the library fail.
        $libraryText = ([Text.UTF8Encoding]::new($false, $true)).GetString($libraryBytes)
        . ([scriptblock]::Create($libraryText))
        return Test-AZSGTocNotesReceiptHash -Bytes (& $readBounded $Path 16384) -ExpectedSHA256 $ExpectedSHA256
    } catch { return $false }
}

function Assert-OwnedInstallation($Receipt) {
    if ($Receipt.Product -cne 'AZSSpeedGear' -or $Receipt.SchemaVersion -ne 1 -or
        (Get-FullPath ([string]$Receipt.GameExecutable)) -ine $script:gameExe) {
        throw 'Installation receipt does not belong to this product and game path.'
    }
    $expected = @{}
    foreach ($file in @($Receipt.ManagedFiles)) {
        $path = Get-ManagedPath ([string]$file.RelativePath)
        if ($path -ieq (Join-Path $script:targetAddon 'NativeLocale.lua')) {
            throw 'NativeLocale.lua must be declared as a LocaleHint runtime file, not a static hash entry.'
        }
        if ($expected.ContainsKey($path) -or ([string]$file.SHA256) -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Invalid or duplicate file in installation receipt.'
        }
        $expected[$path] = [string]$file.SHA256
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$file.SHA256 -and
             -not (Test-AZSGOwnedTocNotes $path ([string]$file.RelativePath) ([string]$file.SHA256) $Receipt $script:gameRoot))) {
            throw "Installed file is missing or changed; refusing to move it: $path"
        }
    }
    if ($null -ne $Receipt.PSObject.Properties['RuntimeFiles']) {
        foreach ($file in @($Receipt.RuntimeFiles)) {
            if ([string]$file.RelativePath -cne 'benilla-config\AddOns\AZSSpeedGear\NativeLocale.lua' -or
                [string]$file.Kind -cne 'LocaleHint') {
                throw 'The receipt contains an unsupported runtime file or kind.'
            }
            $path = Get-ManagedPath ([string]$file.RelativePath)
            if ($expected.ContainsKey($path)) { throw 'Duplicate managed/runtime file in installation receipt.' }
            Assert-LocaleHint $path
            $expected[$path] = 'Runtime:LocaleHint'
        }
    }
    if (-not $expected.ContainsKey($script:targetDll) -or
        -not $expected.ContainsKey((Join-Path $script:targetAddon 'AZSSpeedGear.toc'))) {
        throw 'The receipt does not cover both the native DLL and addon TOC.'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $script:targetAddon -File -Force -Recurse)) {
        if (-not $expected.ContainsKey($file.FullName)) {
            throw "Additional addon file is not owned by this installation: $($file.FullName)"
        }
    }
}

$gameInput = Get-FullPath $GamePath
if (Test-Path -LiteralPath $gameInput -PathType Container) { $gameInput = Join-Path $gameInput 'AzerothSurvivors.exe' }
$script:gameExe = Get-FullPath $gameInput
if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf)) { throw "Game executable not found: $gameExe" }
$script:gameRoot = Get-FullPath (Split-Path -Parent $gameExe)
$configRoot = Assert-InGame (Join-Path $gameRoot 'benilla-config')
$addonsRoot = Assert-InGame (Join-Path $configRoot 'AddOns')
$script:targetAddon = Assert-InGame (Join-Path $addonsRoot 'AZSSpeedGear')
$script:targetDll = Assert-InGame (Join-Path $gameRoot 'dwmapi.dll')
$receiptPath = Assert-InGame (Join-Path $configRoot 'AZSSpeedGear-install.json')
$backupsRoot = Assert-InGame (Join-Path $configRoot 'AZSSpeedGear-backups')

Assert-NoLinks $gameRoot
foreach ($path in @($configRoot, $addonsRoot, $backupsRoot, $receiptPath, $targetDll)) { Assert-NoLinks $path }
Assert-NoLinks $targetAddon -Recursive
Assert-GameStopped
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw 'No AZSSpeedGear installation receipt was found. No files were moved.'
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-OwnedInstallation $receipt
if ($CheckOnly) {
    [pscustomobject]@{
        Product = 'AZSSpeedGear'; GameExecutable = $gameExe; OwnershipVerified = $true
        ManagedFileCount = @($receipt.ManagedFiles).Count; CheckOnly = $true
    } | ConvertTo-Json
    return
}

$transactionName = 'uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Assert-InGame (Join-Path $backupsRoot $transactionName)
$backupAddon = Assert-InGame (Join-Path $backupRoot 'AZSSpeedGear')
$backupDll = Assert-InGame (Join-Path $backupRoot 'dwmapi.dll')
$backupReceipt = Assert-InGame (Join-Path $backupRoot 'AZSSpeedGear-install.json')
$movedAddon = $false; $movedDll = $false; $movedReceipt = $false
try {
    Assert-GameStopped
    Assert-OwnedInstallation $receipt
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Move-Item -LiteralPath (Assert-InGame $targetAddon) -Destination $backupAddon
    $movedAddon = $true
    Move-Item -LiteralPath (Assert-InGame $targetDll) -Destination $backupDll
    $movedDll = $true
    Move-Item -LiteralPath (Assert-InGame $receiptPath) -Destination $backupReceipt
    $movedReceipt = $true
    [ordered]@{
        SchemaVersion = 1; Product = 'AZSSpeedGear'; UninstalledUtc = [DateTime]::UtcNow.ToString('o')
        GameExecutable = $gameExe; RetainedInstallationReceipt = $backupReceipt
        AddonBackup = $backupAddon; NativeBackup = $backupDll
        RestoreInstructions = @(
            'Close the game. Verify managed file SHA-256 values and restricted runtime-file content against the retained installation receipt.',
            'Only when both destinations are absent, move AZSSpeedGear to benilla-config/AddOns/AZSSpeedGear and dwmapi.dll beside the game executable.',
            'Move AZSSpeedGear-install.json back into benilla-config. Never overwrite another mod or a newer installation.'
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backupRoot 'uninstall-recovery.json') -Encoding UTF8
    [pscustomobject]@{
        Uninstalled = $true; Product = 'AZSSpeedGear'; BackupDirectory = $backupRoot
        Message = 'Owned addon, native DLL and receipt were moved to backup. Saves, shared settings and other addons were not modified.'
    } | ConvertTo-Json
} catch {
    $uninstallError = $_
    try {
        if ($movedAddon -and -not (Test-Path -LiteralPath $targetAddon)) { Move-Item -LiteralPath $backupAddon -Destination $targetAddon }
        if ($movedDll -and -not (Test-Path -LiteralPath $targetDll)) { Move-Item -LiteralPath $backupDll -Destination $targetDll }
        if ($movedReceipt -and -not (Test-Path -LiteralPath $receiptPath)) { Move-Item -LiteralPath $backupReceipt -Destination $receiptPath }
    } catch {
        Write-Warning "Automatic rollback was incomplete. Retained files are under $backupRoot. Recovery error: $($_.Exception.Message)"
    }
    throw $uninstallError
}

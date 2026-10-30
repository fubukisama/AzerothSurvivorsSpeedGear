#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GamePath,
    [string]$PackagePath = (Split-Path -Parent $PSScriptRoot),
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
    if ($Recursive -and $items[0].PSIsContainer) {
        $items += @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
    }
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Directory links and reparse points are not managed: $($item.FullName)"
        }
    }
}

function Assert-GameStopped {
    $name = [IO.Path]::GetFileName($script:gameExe).Replace("'", "''")
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = '$name'")
    foreach ($process in $processes) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
            (Get-FullPath ([string]$process.ExecutablePath)) -ieq $script:gameExe) {
            throw 'Close the selected game completely before installing or updating AZSSpeedGear.'
        }
    }
}

function Assert-X64DwmImport([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    function Read-U16([int]$Offset) {
        if ($Offset -lt 0 -or $Offset -gt $bytes.Length - 2) { throw 'Invalid PE bounds.' }
        return [BitConverter]::ToUInt16($bytes, $Offset)
    }
    function Read-U32([int]$Offset) {
        if ($Offset -lt 0 -or $Offset -gt $bytes.Length - 4) { throw 'Invalid PE bounds.' }
        return [BitConverter]::ToUInt32($bytes, $Offset)
    }
    if ($bytes.Length -lt 64 -or (Read-U16 0) -ne 0x5a4d) { throw 'The game is not a PE executable.' }
    $pe = [long](Read-U32 0x3c)
    if ($pe -gt $bytes.Length - 24 -or (Read-U32 ([int]$pe)) -ne 0x4550) { throw 'Invalid PE header.' }
    if ((Read-U16 ([int]$pe + 4)) -ne 0x8664) { throw 'AZSSpeedGear requires an AMD64/x64 game executable.' }
    $sectionCount = Read-U16 ([int]$pe + 6)
    $optionalSize = Read-U16 ([int]$pe + 20)
    $optional = [int]$pe + 24
    if ($sectionCount -eq 0 -or $sectionCount -gt 96 -or $optionalSize -lt 128 -or
        $optional -gt $bytes.Length - $optionalSize -or (Read-U16 $optional) -ne 0x20b) {
        throw 'Invalid PE32+ optional header.'
    }
    if ((Read-U32 ($optional + 108)) -lt 2) { throw 'The game does not declare an import directory.' }
    $importRva = Read-U32 ($optional + 120)
    $importSize = Read-U32 ($optional + 124)
    $headersSize = Read-U32 ($optional + 60)
    $sections = @()
    $sectionTable = $optional + $optionalSize
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $entry = $sectionTable + 40 * $index
        if ($entry -gt $bytes.Length - 40) { throw 'Invalid PE section table.' }
        $sections += [pscustomobject]@{
            VirtualSize = [long](Read-U32 ($entry + 8)); Rva = [long](Read-U32 ($entry + 12))
            RawSize = [long](Read-U32 ($entry + 16)); Raw = [long](Read-U32 ($entry + 20))
        }
    }
    function Convert-Rva([long]$Rva) {
        if ($Rva -lt $headersSize -and $Rva -lt $bytes.Length) { return [int]$Rva }
        foreach ($section in $sections) {
            if ($Rva -ge $section.Rva -and $Rva -lt $section.Rva + [Math]::Max($section.VirtualSize, $section.RawSize)) {
                $delta = $Rva - $section.Rva
                if ($delta -ge $section.RawSize -or $section.Raw + $delta -ge $bytes.Length) { break }
                return [int]($section.Raw + $delta)
            }
        }
        throw "Unmapped PE RVA: $Rva"
    }
    if ($importRva -eq 0 -or $importSize -lt 20) { throw 'The game has no ordinary DLL imports.' }
    $found = $false
    $limit = [Math]::Min([long]4096, [Math]::Floor($importSize / 20))
    for ($index = 0; $index -lt $limit; $index++) {
        $entry = Convert-Rva ([long]$importRva + 20 * $index)
        if ($entry -gt $bytes.Length - 20) { throw 'Invalid PE import descriptor.' }
        $nameRva = Read-U32 ($entry + 12)
        if ($nameRva -eq 0) { break }
        $nameOffset = Convert-Rva $nameRva
        $end = $nameOffset
        while ($end -lt $bytes.Length -and $end - $nameOffset -lt 260 -and $bytes[$end] -ne 0) { $end++ }
        if ($end -ge $bytes.Length -or $end - $nameOffset -ge 260) { throw 'Invalid PE import name.' }
        $dllName = [Text.Encoding]::ASCII.GetString($bytes, $nameOffset, $end - $nameOffset)
        if ($dllName -ieq 'dwmapi.dll') { $found = $true; break }
    }
    if (-not $found) { throw 'The game does not import dwmapi.dll; this native bootstrap is unsupported.' }
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

function Assert-OwnedInstallation($Receipt) {
    if ($Receipt.Product -cne 'AZSSpeedGear' -or $Receipt.SchemaVersion -ne 1 -or
        (Get-FullPath ([string]$Receipt.GameExecutable)) -ine $script:gameExe) {
        throw 'Installation receipt does not belong to this product and game path.'
    }
    $expected = @{}
    foreach ($file in @($Receipt.ManagedFiles)) {
        $path = Get-ManagedPath ([string]$file.RelativePath)
        if ($expected.ContainsKey($path) -or ([string]$file.SHA256) -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Invalid or duplicate file in installation receipt.'
        }
        $expected[$path] = [string]$file.SHA256
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$file.SHA256) {
            throw "Installed file is missing or changed; refusing to replace it: $path"
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
$packageRoot = Get-FullPath $PackagePath
$sourceAddon = Join-Path $packageRoot 'AddOns\AZSSpeedGear'
$sourceDll = Join-Path $packageRoot 'Native\dwmapi.dll'
$configRoot = Assert-InGame (Join-Path $gameRoot 'benilla-config')
$addonsRoot = Assert-InGame (Join-Path $configRoot 'AddOns')
$script:targetAddon = Assert-InGame (Join-Path $addonsRoot 'AZSSpeedGear')
$script:targetDll = Assert-InGame (Join-Path $gameRoot 'dwmapi.dll')
$receiptPath = Assert-InGame (Join-Path $configRoot 'AZSSpeedGear-install.json')
$backupsRoot = Assert-InGame (Join-Path $configRoot 'AZSSpeedGear-backups')

Assert-NoLinks $gameRoot
foreach ($path in @($configRoot, $addonsRoot, $backupsRoot, $receiptPath, $targetDll)) { Assert-NoLinks $path }
Assert-NoLinks $targetAddon -Recursive
Assert-NoLinks $sourceAddon -Recursive
Assert-NoLinks $sourceDll
if (-not (Test-Path -LiteralPath (Join-Path $sourceAddon 'AZSSpeedGear.toc') -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sourceDll -PathType Leaf)) {
    throw "Package is incomplete. Expected AddOns\AZSSpeedGear\AZSSpeedGear.toc and Native\dwmapi.dll under $packageRoot"
}
if ($sourceAddon -ieq $targetAddon -or $sourceDll -ieq $targetDll) { throw 'Package and installed paths must be separate.' }
Assert-GameStopped
Assert-X64DwmImport $gameExe

$oldReceipt = $null
if (Test-Path -LiteralPath $receiptPath) {
    $oldReceipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-OwnedInstallation $oldReceipt
} elseif ((Test-Path -LiteralPath $targetDll) -or (Test-Path -LiteralPath $targetAddon)) {
    throw 'An existing dwmapi.dll or AZSSpeedGear folder has no verified receipt. Nothing was replaced.'
}

$managedFiles = @()
foreach ($file in @(Get-ChildItem -LiteralPath $sourceAddon -File -Force -Recurse | Sort-Object FullName)) {
    $insideAddon = $file.FullName.Substring($sourceAddon.Length).TrimStart([char[]]@('\', '/'))
    $relative = 'benilla-config\AddOns\AZSSpeedGear\' + $insideAddon
    $destination = Get-ManagedPath $relative
    $managedFiles += [pscustomobject]@{
        RelativePath = $relative; SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Bytes = $file.Length
    }
}
$managedFiles += [pscustomobject]@{
    RelativePath = 'dwmapi.dll'; SHA256 = (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash.ToLowerInvariant()
    Bytes = (Get-Item -LiteralPath $sourceDll).Length
}
$versionLine = @(Get-Content -LiteralPath (Join-Path $sourceAddon 'AZSSpeedGear.toc') -Encoding UTF8 |
    Where-Object { $_ -match '^##\s*Version\s*:' } | Select-Object -First 1)
$version = if ($versionLine.Count -gt 0) { ($versionLine[0] -replace '^##\s*Version\s*:\s*', '').Trim() } else { 'unknown' }
if ($CheckOnly) {
    [pscustomobject]@{
        Product = 'AZSSpeedGear'; Version = $version; GameExecutable = $gameExe
        X64AndDwmImportVerified = $true; ExistingInstallationVerified = ($null -ne $oldReceipt)
        ManagedFileCount = $managedFiles.Count; CheckOnly = $true
    } | ConvertTo-Json
    return
}

$transactionName = 'install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Assert-InGame (Join-Path $backupsRoot $transactionName)
$previousRoot = Assert-InGame (Join-Path $backupRoot 'previous')
$failedRoot = Assert-InGame (Join-Path $backupRoot 'failed-new')
$previousAddon = Assert-InGame (Join-Path $previousRoot 'AZSSpeedGear')
$previousDll = Assert-InGame (Join-Path $previousRoot 'dwmapi.dll')
$previousReceipt = Assert-InGame (Join-Path $previousRoot 'AZSSpeedGear-install.json')
$movedAddon = $false; $movedDll = $false; $movedReceipt = $false
$startedAddonCopy = $false; $startedDllCopy = $false; $wroteReceipt = $false
try {
    Assert-GameStopped
    if ($null -ne $oldReceipt) { Assert-OwnedInstallation $oldReceipt }
    New-Item -ItemType Directory -Path $addonsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $previousRoot -Force | Out-Null
    if (Test-Path -LiteralPath $targetAddon) {
        Move-Item -LiteralPath (Assert-InGame $targetAddon) -Destination $previousAddon
        $movedAddon = $true
    }
    if (Test-Path -LiteralPath $targetDll) {
        Move-Item -LiteralPath (Assert-InGame $targetDll) -Destination $previousDll
        $movedDll = $true
    }
    if (Test-Path -LiteralPath $receiptPath) {
        Move-Item -LiteralPath (Assert-InGame $receiptPath) -Destination $previousReceipt
        $movedReceipt = $true
    }
    $startedAddonCopy = $true
    Copy-Item -LiteralPath $sourceAddon -Destination $targetAddon -Recurse
    $startedDllCopy = $true
    Copy-Item -LiteralPath $sourceDll -Destination $targetDll
    foreach ($file in $managedFiles) {
        $installedFile = Get-ManagedPath $file.RelativePath
        if ((Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash -ine $file.SHA256) {
            throw "Copied file failed SHA-256 verification: $installedFile"
        }
    }
    $receipt = [ordered]@{
        SchemaVersion = 1; Product = 'AZSSpeedGear'; Version = $version
        InstallationId = [guid]::NewGuid().ToString(); InstalledUtc = [DateTime]::UtcNow.ToString('o')
        GameExecutable = $gameExe; GameExeSHA256 = (Get-FileHash -LiteralPath $gameExe -Algorithm SHA256).Hash.ToLowerInvariant()
        ManagedFiles = @($managedFiles); BackupDirectory = $backupRoot
        PreviousInstallationBackedUp = ($null -ne $oldReceipt)
    }
    $temporaryReceipt = Assert-InGame ($receiptPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryReceipt -Encoding UTF8
    Move-Item -LiteralPath $temporaryReceipt -Destination $receiptPath
    $wroteReceipt = $true
    Assert-OwnedInstallation ([pscustomobject]$receipt)
    [pscustomobject]@{
        Installed = $true; Product = 'AZSSpeedGear'; Version = $version; GameExecutable = $gameExe
        AddonPath = $targetAddon; NativePath = $targetDll; ReceiptPath = $receiptPath
        BackupDirectory = $backupRoot; ManagedFileCount = $managedFiles.Count
        Message = 'Start the game normally. Enable AZSSpeedGear in Options > AddOns. No game was launched by this script.'
    } | ConvertTo-Json
} catch {
    $installError = $_
    try {
        New-Item -ItemType Directory -Path $failedRoot -Force | Out-Null
        if ($wroteReceipt -and (Test-Path -LiteralPath $receiptPath)) {
            Move-Item -LiteralPath (Assert-InGame $receiptPath) -Destination (Join-Path $failedRoot 'AZSSpeedGear-install.json')
        }
        if ($startedAddonCopy -and (Test-Path -LiteralPath $targetAddon)) {
            Move-Item -LiteralPath (Assert-InGame $targetAddon) -Destination (Join-Path $failedRoot 'AZSSpeedGear')
        }
        if ($startedDllCopy -and (Test-Path -LiteralPath $targetDll)) {
            Move-Item -LiteralPath (Assert-InGame $targetDll) -Destination (Join-Path $failedRoot 'dwmapi.dll')
        }
        if ($movedAddon -and -not (Test-Path -LiteralPath $targetAddon)) { Move-Item -LiteralPath $previousAddon -Destination $targetAddon }
        if ($movedDll -and -not (Test-Path -LiteralPath $targetDll)) { Move-Item -LiteralPath $previousDll -Destination $targetDll }
        if ($movedReceipt -and -not (Test-Path -LiteralPath $receiptPath)) { Move-Item -LiteralPath $previousReceipt -Destination $receiptPath }
    } catch {
        Write-Warning "Automatic rollback was incomplete. All retained files are under $backupRoot. Recovery error: $($_.Exception.Message)"
    }
    throw $installError
}

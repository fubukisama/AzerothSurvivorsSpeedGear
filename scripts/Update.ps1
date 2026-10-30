#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$GamePath,
    [Parameter(ParameterSetName = 'Run')][switch]$CheckOnly,
    [Parameter(ParameterSetName = 'Run')][switch]$WaitForExit,
    [Parameter(Mandatory = $true, ParameterSetName = 'Library')][switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:AzsgReleaseApi = 'https://api.github.com/repos/fubukisama/AzerothSurvivorsSpeedGear/releases/latest'
$script:AzsgCompatibilityUrl = 'https://raw.githubusercontent.com/fubukisama/AzerothSurvivorsSpeedGear/main/compatibility/windows.json'
$script:AzsgHeaders = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'AzerothSurvivorsSpeedGear-Updater' }
$script:AzsgMaximumArchive = 64MB
$script:AzsgMaximumExpanded = 256MB
$script:AzsgMaximumEntry = 32MB

function Get-AZSGFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    return $full
}

function Assert-AZSGNoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not accepted by the updater: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([char[]]@('\', '/')))
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-AZSGUInt64($Value, [string]$Name) {
    $text = [string]$Value
    [uint64]$number = 0
    if ($Value -is [bool] -or $text -cnotmatch '^(0|[1-9][0-9]*)$' -or
        -not [uint64]::TryParse($text, [ref]$number)) { throw "Invalid unsigned integer: $Name" }
    return $number
}

function Get-AZSGVersion([string]$Text) {
    if ($Text -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "A stable three-part version is required: $Text"
    }
    try { return [version]$Text } catch { throw "Version is out of range: $Text" }
}

function Read-AZSGJson([string]$Path, [long]$MaximumBytes = 1MB) {
    Assert-AZSGNoLinks $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -gt $MaximumBytes) {
        throw "Missing or oversized JSON file: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt $MaximumBytes) { throw "Oversized JSON file: $Path" }
    return ConvertFrom-Json -InputObject $text
}

function Get-AZSGGame([string]$Path) {
    $exe = Get-AZSGFullPath $Path
    if (Test-Path -LiteralPath $exe -PathType Container) { $exe = Join-Path $exe 'AzerothSurvivors.exe' }
    if ([IO.Path]::GetFileName($exe) -ine 'AzerothSurvivors.exe' -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw 'GamePath must identify AzerothSurvivors.exe or its containing directory.'
    }
    Assert-AZSGNoLinks $exe
    return [pscustomobject]@{ Executable = $exe; Root = (Split-Path -Parent $exe) }
}

function Get-AZSGGameProcesses([string]$Executable) {
    $name = [IO.Path]::GetFileName($Executable).Replace("'", "''")
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = '$name'")) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
            (Get-AZSGFullPath ([string]$process.ExecutablePath)) -ieq $Executable) { $process }
    }
}

function Wait-AZSGGameExit([string]$Executable) {
    while (@(Get-AZSGGameProcesses $Executable).Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

function Get-AZSGUpdateMutexName([string]$Executable) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Executable.ToUpperInvariant())
        $digest = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '')
        return 'Local\AZSSpeedGearLauncher_' + $digest
    } finally { $algorithm.Dispose() }
}

function Get-AZSGManagedPath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) { throw 'Invalid managed path.' }
    $name = $Relative.Replace('/', '\')
    if (@($name.Split('\') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_.Contains(':') }).Count) {
        throw 'Invalid managed path component.'
    }
    if ($name -ine 'dwmapi.dll' -and
        -not $name.StartsWith('benilla-config\AddOns\AZSSpeedGear\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unmanaged receipt path: $name"
    }
    $full = Get-AZSGFullPath (Join-Path $Root $name)
    if (-not $full.StartsWith($Root.TrimEnd([char[]]@('\', '/')) + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed path escaped the game.' }
    Assert-AZSGNoLinks $full
    return $full
}

function Get-AZSGInstalledReceipt($Game) {
    $receiptPath = Join-Path $Game.Root 'benilla-config\AZSSpeedGear-install.json'
    $receipt = Read-AZSGJson $receiptPath
    if ([string]$receipt.Product -cne 'AZSSpeedGear' -or $receipt.SchemaVersion -ne 1 -or
        (Get-AZSGFullPath ([string]$receipt.GameExecutable)) -ine $Game.Executable -or
        [string]$receipt.GameExeSHA256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Installed receipt does not belong to this product and selected game.'
    }
    $null = Get-AZSGVersion ([string]$receipt.Version)
    $files = @($receipt.ManagedFiles)
    if ($files.Count -lt 2 -or $files.Count -gt 4096) { throw 'Invalid installed managed-file count.' }
    $owned = @{}
    foreach ($file in $files) {
        $path = Get-AZSGManagedPath $Game.Root ([string]$file.RelativePath)
        if ($owned.ContainsKey($path) -or [string]$file.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid managed hash or duplicate path.' }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$file.SHA256) {
            throw "Installed file is missing or changed: $path"
        }
        $owned[$path] = [string]$file.SHA256
    }
    $dll = Join-Path $Game.Root 'dwmapi.dll'
    $toc = Join-Path $Game.Root 'benilla-config\AddOns\AZSSpeedGear\AZSSpeedGear.toc'
    if (-not $owned.ContainsKey($dll) -or -not $owned.ContainsKey($toc)) { throw 'Receipt does not own both DLL and addon TOC.' }
    return [pscustomobject]@{ Receipt = $receipt; Owned = $owned }
}

function Get-AZSGRelease {
    $release = Invoke-RestMethod -Uri $script:AzsgReleaseApi -Headers $script:AzsgHeaders -TimeoutSec 8
    if ($release.draft -isnot [bool] -or $release.prerelease -isnot [bool] -or $release.draft -or $release.prerelease -or
        [string]$release.tag_name -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        [string]::IsNullOrWhiteSpace([string]$release.published_at)) { throw 'Latest release is not a published stable version.' }
    $version = ([string]$release.tag_name).Substring(1)
    $null = Get-AZSGVersion $version
    [DateTimeOffset]$published = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$release.published_at, [ref]$published)) { throw 'Release publication date is invalid.' }
    $name = 'AZSSpeedGear-' + $version + '-Windows-x64.zip'
    $assets = @($release.assets | Where-Object { [string]$_.name -ceq $name })
    if ($assets.Count -ne 1) { throw 'Release package asset is missing or ambiguous.' }
    $asset = $assets[0]
    $size = Get-AZSGUInt64 $asset.size 'asset.size'
    $url = 'https://github.com/fubukisama/AzerothSurvivorsSpeedGear/releases/download/' + $release.tag_name + '/' + $name
    if ([string]$asset.digest -cnotmatch '^sha256:[a-fA-F0-9]{64}$' -or $size -eq 0 -or $size -gt $script:AzsgMaximumArchive -or
        -not [string]::Equals([string]$asset.browser_download_url, $url, [StringComparison]::Ordinal)) {
        throw 'Release asset has an invalid digest, size or fixed-project download URL.'
    }
    return [pscustomobject]@{
        Version = $version; Tag = [string]$release.tag_name; Name = $name
        Size = $size; SHA256 = ([string]$asset.digest).Substring(7).ToLowerInvariant(); Url = $url
    }
}

function Get-AZSGScannerFingerprint($Game, $Installation) {
    $path = Join-Path $Game.Root 'benilla-config\AddOns\AZSSpeedGear\Updater\Scanner.json'
    if (-not $Installation.Owned.ContainsKey($path)) { return $null }
    try {
        $metadata = Read-AZSGJson $path 4KB
        if ($metadata.schema -ne 1 -or [string]$metadata.product -cne 'AzerothSurvivorsSpeedGear' -or
            [string]$metadata.scannerContract -cne 'rust-duration25ms-waitable-timer-v1' -or
            [string]$metadata.engineFingerprint -notmatch '^[a-fA-F0-9]{64}$') { return $null }
        return ([string]$metadata.engineFingerprint).ToLowerInvariant()
    } catch { return $null }
}

function Get-AZSGCompatibility([string]$GameHash, [long]$GameBytes, [string]$ExpectedFingerprint) {
    $unknown = [pscustomobject]@{ status = 'unknown'; reason = 'report_unavailable'; gameVersion = $null }
    if ($ExpectedFingerprint -notmatch '^[a-fA-F0-9]{64}$') {
        $unknown.reason = 'scanner_fingerprint_unavailable'; return $unknown
    }
    try {
        $data = Invoke-RestMethod -Uri $script:AzsgCompatibilityUrl -Headers $script:AzsgHeaders -TimeoutSec 5
        if ($data -is [string]) {
            if ([Text.Encoding]::UTF8.GetByteCount($data) -gt 64KB) { throw 'Compatibility report too large.' }
            $data = ConvertFrom-Json -InputObject $data
        }
        if ($data.schema -ne 1 -or [string]$data.product -cne 'AzerothSurvivorsSpeedGear' -or
            [string]$data.scannerContract -cne 'rust-duration25ms-waitable-timer-v1' -or
            [string]$data.gameSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            [string]$data.engineFingerprint -notmatch '^[a-fA-F0-9]{64}$' -or
            @('structural_only', 'unsupported') -cnotcontains [string]$data.status) { throw 'Invalid compatibility schema.' }
        if ([string]$data.engineFingerprint -ine $ExpectedFingerprint) {
            $unknown.reason = 'different_scanner_fingerprint'; return $unknown
        }
        $bytes = Get-AZSGUInt64 $data.gameBytes 'compatibility.gameBytes'
        if ([string]$data.gameSha256 -ine $GameHash -or $bytes -ne $GameBytes) {
            $unknown.reason = 'different_game_fingerprint'; return $unknown
        }
        $reason = [string]$data.reason
        if ($reason.Length -gt 512 -or ([string]$data.gameVersion).Length -gt 64) { throw 'Compatibility text too large.' }
        return [pscustomobject]@{ status = [string]$data.status; reason = $reason; gameVersion = [string]$data.gameVersion }
    } catch { return $unknown }
}

function Get-AZSGArchivePath([string]$Name, [string]$ExpectedRoot) {
    $name = $Name.Replace('\', '/')
    $directory = $name.EndsWith('/')
    if ($directory) { $name = $name.TrimEnd('/') }
    if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name -match '[\x00-\x1f]') { throw 'Unsafe ZIP path.' }
    $parts = $name.Split('/')
    foreach ($part in $parts) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part.Contains(':') -or $part -match '[<>"|?*]' -or $part -match '[. ]$' -or
            $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') { throw "Unsafe ZIP path component: $part" }
    }
    if ($parts[0] -cne $ExpectedRoot -or ($parts.Count -eq 1 -and -not $directory)) { throw 'ZIP has an unexpected package root.' }
    return [pscustomobject]@{ Name = $name; Directory = $directory }
}

function Expand-AZSGPackage([string]$Archive, [string]$Destination, [string]$ExpectedRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-AZSGNoLinks $Destination
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $prefix = (Get-AZSGFullPath $Destination) + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 512) { throw 'Too many ZIP entries.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $files = 0; [long]$declared = 0
        foreach ($entry in $zip.Entries) {
            $path = Get-AZSGArchivePath $entry.FullName $ExpectedRoot
            if (-not $names.Add($path.Name)) { throw 'Duplicate or case-colliding ZIP path.' }
            $attributes = [long]$entry.ExternalAttributes -band 0xffffffffL
            $type = ($attributes -shr 16) -band 0xf000
            if (($attributes -band 0x400) -ne 0 -or ($type -ne 0 -and $type -ne 0x8000 -and $type -ne 0x4000)) { throw 'ZIP links or special files are forbidden.' }
            if (($path.Directory -and $type -eq 0x8000) -or (-not $path.Directory -and $type -eq 0x4000)) { throw 'ZIP file type and directory name disagree.' }
            if (-not $path.Directory) {
                $files++; $declared += $entry.Length
                if ($entry.Length -lt 0 -or $entry.Length -gt $script:AzsgMaximumEntry -or $declared -gt $script:AzsgMaximumExpanded) { throw 'ZIP expansion quota exceeded.' }
            } elseif ($entry.Length -ne 0) { throw 'ZIP directory has a payload.' }
        }
        if ($files -lt 18 -or $files -gt 100) { throw 'ZIP must contain between 18 and 100 files.' }
        $buffer = New-Object byte[] 65536
        [long]$expanded = 0
        foreach ($entry in $zip.Entries) {
            $path = Get-AZSGArchivePath $entry.FullName $ExpectedRoot
            $target = Get-AZSGFullPath (Join-Path $Destination $path.Name.Replace('/', '\'))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'ZIP escaped staging.' }
            Assert-AZSGNoLinks $target
            if ($path.Directory) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            $zipInput = $entry.Open()
            $outputStream = $null
            try {
                $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                [long]$written = 0
                while (($count = $zipInput.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $written += $count; $expanded += $count
                    if ($written -gt $entry.Length -or $written -gt $script:AzsgMaximumEntry -or $expanded -gt $script:AzsgMaximumExpanded) { throw 'ZIP stream exceeded its declared size or quota.' }
                    $outputStream.Write($buffer, 0, $count)
                }
                if ($written -ne $entry.Length) { throw 'ZIP stream length mismatch.' }
                $outputStream.Flush()
            } finally { if ($null -ne $outputStream) { $outputStream.Dispose() }; $zipInput.Dispose() }
        }
    } finally { $zip.Dispose() }
    return Join-Path $Destination $ExpectedRoot
}

function Get-AZSGArchiveManifestHash([string]$Archive, [string]$RootName) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq ($RootName + '/files.json') })
        if ($entries.Count -ne 1 -or $entries[0].Length -gt 1MB) { throw 'Archive has no unique bounded files.json.' }
        $stream = $entries[0].Open()
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $buffer = New-Object byte[] 65536
            [long]$total = 0
            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $count
                if ($total -gt 1MB -or $total -gt $entries[0].Length) { throw 'Archive manifest exceeded its size.' }
                $null = $algorithm.TransformBlock($buffer, 0, $count, $buffer, 0)
            }
            if ($total -ne $entries[0].Length) { throw 'Archive manifest stream length mismatch.' }
            $null = $algorithm.TransformFinalBlock([byte[]]@(), 0, 0)
            return [BitConverter]::ToString($algorithm.Hash).Replace('-', '').ToLowerInvariant()
        } finally { $algorithm.Dispose(); $stream.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-AZSGPackageFiles([string]$Root) {
    Assert-AZSGNoLinks $Root
    $directories = [Collections.Generic.Stack[string]]::new()
    $directories.Push($Root)
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $seen = 0
    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            $seen++
            if ($seen -gt 512) { throw 'Extracted package has too many entries.' }
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Extracted package contains a reparse point.' }
            if ($entry.PSIsContainer) { $directories.Push($entry.FullName) }
            else {
                $files.Add($entry)
                if ($files.Count -gt 100) { throw 'Extracted package contains too many files.' }
            }
        }
    }
    return $files.ToArray()
}

function Assert-AZSGPackage([string]$Root, [string]$Version, [string]$ManifestSHA256) {
    $root = Get-AZSGFullPath $Root
    $manifestPath = Join-Path $root 'files.json'
    Assert-AZSGNoLinks $manifestPath
    if ($ManifestSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine $ManifestSHA256) {
        throw 'Extracted files.json differs from the verified release archive.'
    }
    $manifest = @(Read-AZSGJson $manifestPath)
    $actual = @(Get-AZSGPackageFiles $root)
    if ($actual.Count -lt 18 -or $actual.Count -gt 100 -or $manifest.Count -ne $actual.Count - 1) { throw 'Package manifest does not enumerate every payload file.' }
    $expected = @{}
    foreach ($file in $manifest) {
        $names = @($file.PSObject.Properties.Name)
        if ($names.Count -ne 3 -or $names -cnotcontains 'Path' -or $names -cnotcontains 'Bytes' -or $names -cnotcontains 'SHA256') { throw 'Unknown files.json entry schema.' }
        $relative = [string]$file.Path
        $safe = Get-AZSGArchivePath ('package/' + $relative) 'package'
        if ($safe.Directory -or $relative -ieq 'files.json' -or $expected.ContainsKey($safe.Name)) { throw 'Invalid or duplicate manifest path.' }
        $path = Get-AZSGFullPath (Join-Path $root $relative.Replace('/', '\'))
        if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escaped package.' }
        Assert-AZSGNoLinks $path
        $length = Get-AZSGUInt64 $file.Bytes 'files.json Bytes'
        if ([string]$file.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path).Length -ne $length -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$file.SHA256) {
            throw "Package hash or length mismatch: $relative"
        }
        $expected[$safe.Name] = $true
    }
    foreach ($file in $actual) {
        Assert-AZSGNoLinks $file.FullName
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($relative -ine 'files.json' -and -not $expected.ContainsKey('package/' + $relative)) { throw 'Package contains an unlisted file.' }
    }
    $toc = Join-Path $root 'AddOns\AZSSpeedGear\AZSSpeedGear.toc'
    $lines = @(Get-Content -LiteralPath $toc -Encoding UTF8)
    $titles = @($lines | Where-Object { $_ -match '^##\s*Title\s*:' })
    $versions = @($lines | Where-Object { $_ -match '^##\s*Version\s*:' })
    if ($titles.Count -ne 1 -or $versions.Count -ne 1 -or
        ($titles[0] -replace '^##\s*Title\s*:\s*', '').Trim() -cne 'AzerothSurvivorsSpeedGear' -or
        ($versions[0] -replace '^##\s*Version\s*:\s*', '').Trim() -cne $Version -or
        -not (Test-Path -LiteralPath (Join-Path $root 'Native\dwmapi.dll') -PathType Leaf)) { throw 'Package title/version/native DLL contract mismatch.' }
}

function Assert-AZSGUpdateState([string]$Root) {
    Assert-AZSGNoLinks $Root
    $destination = Join-Path $Root 'update-state.json'
    Assert-AZSGNoLinks $destination
    if (Test-Path -LiteralPath $destination) {
        $old = Read-AZSGJson $destination 64KB
        if ($old.schema -ne 1 -or [string]$old.product -cne 'AZSSpeedGear') { throw 'Existing updater state belongs to another schema or product.' }
    }
}

function Write-AZSGUpdateState([string]$Root, $Result) {
    Assert-AZSGUpdateState $Root
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $destination = Join-Path $Root 'update-state.json'
    $temporary = Join-Path $Root ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    if ([IO.File]::Exists($destination)) {
        # Some PowerShell hosts bind a null backup argument to an empty path.
        $stateBackup = Join-Path $Root ('state-backup-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::Replace($temporary, $destination, $stateBackup)
        Remove-Item -LiteralPath $stateBackup -Force
    }
    else { [IO.File]::Move($temporary, $destination) }
}

function Invoke-AZSGUpdateCore($Game, [switch]$CheckOnly) {
    $installation = Get-AZSGInstalledReceipt $game
    $hash = (Get-FileHash -LiteralPath $game.Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes = (Get-Item -LiteralPath $game.Executable).Length
    $release = Get-AZSGRelease
    $fingerprint = Get-AZSGScannerFingerprint $game $installation
    $compatibility = Get-AZSGCompatibility $hash $bytes $fingerprint
    $result = [pscustomobject][ordered]@{
        schema = 1; product = 'AZSSpeedGear'; status = 'up_to_date'; checkedUtc = [DateTime]::UtcNow.ToString('o')
        gameExecutable = $game.Executable; gameSha256 = $hash; gameChanged = ($hash -ine [string]$installation.Receipt.GameExeSHA256)
        installedVersion = [string]$installation.Receipt.Version; availableVersion = $release.Version
        compatibility = $compatibility; releaseTag = $release.Tag; packageSha256 = $release.SHA256; pendingPackage = $null
    }
    $updateRoot = Join-Path $game.Root 'benilla-config\AZSSpeedGear-updates'
    if ((Get-AZSGVersion $release.Version) -le (Get-AZSGVersion $result.installedVersion)) {
        if (-not $CheckOnly) { Write-AZSGUpdateState $updateRoot $result }
        return $result
    }
    $result.status = 'update_available'
    if ($CheckOnly) { return $result }

    Assert-AZSGNoLinks $updateRoot
    New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
    $lockPath = Join-Path $updateRoot 'update.lock'; Assert-AZSGNoLinks $lockPath
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-AZSGUpdateState $updateRoot
        $rootName = 'AZSSpeedGear-' + $release.Version + '-Windows-x64'
        $pending = Join-Path $updateRoot ('pending-' + $release.Version + '-' + $release.SHA256.Substring(0, 16))
        Assert-AZSGNoLinks $pending
        if (-not (Test-Path -LiteralPath $pending)) {
            $temporary = Join-Path $updateRoot ('download-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $temporary | Out-Null
            $part = Join-Path $temporary 'package.zip.download'
            Invoke-WebRequest -Uri $release.Url -Headers $script:AzsgHeaders -UseBasicParsing -OutFile $part -TimeoutSec 90 | Out-Null
            if ((Get-Item -LiteralPath $part).Length -ne $release.Size -or (Get-Item -LiteralPath $part).Length -gt $script:AzsgMaximumArchive -or
                (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ine $release.SHA256) { throw 'Downloaded archive size or SHA-256 mismatch.' }
            $archive = Join-Path $temporary 'package.zip'
            Move-Item -LiteralPath $part -Destination $archive
            $package = Expand-AZSGPackage $archive (Join-Path $temporary 'payload') $rootName
            $manifestHash = Get-AZSGArchiveManifestHash $archive $rootName
            Assert-AZSGPackage $package $release.Version $manifestHash
            Move-Item -LiteralPath $temporary -Destination $pending
        }
        # Pending state is untrusted until its bytes are checked again.
        $archive = Join-Path $pending 'package.zip'
        Assert-AZSGNoLinks $archive
        if ((Get-Item -LiteralPath $archive).Length -ne $release.Size -or
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $release.SHA256) { throw 'Pending archive integrity check failed.' }
        $package = Join-Path $pending ('payload\' + $rootName)
        $manifestHash = Get-AZSGArchiveManifestHash $archive $rootName
        Assert-AZSGPackage $package $release.Version $manifestHash
        $result.pendingPackage = $package
        if (@(Get-AZSGGameProcesses $game.Executable).Count -gt 0) {
            $result.status = 'pending'; Write-AZSGUpdateState $updateRoot $result; return $result
        }
        # A changed game or installation during download must be rechecked on a
        # fresh invocation; never install against stale compatibility metadata.
        if ((Get-FileHash -LiteralPath $game.Executable -Algorithm SHA256).Hash -ine $hash) { throw 'The game changed during download; retry after its update completes.' }
        $freshInstallation = Get-AZSGInstalledReceipt $game
        if ([string]$freshInstallation.Receipt.Version -cne $result.installedVersion) { throw 'Installed plugin changed during this update.' }
        $trustedInstaller = Join-Path $game.Root 'benilla-config\AddOns\AZSSpeedGear\Updater\Install.ps1'
        if (-not $freshInstallation.Owned.ContainsKey($trustedInstaller)) { throw 'No receipt-owned installed updater installer is available.' }
        if (@(Get-AZSGGameProcesses $game.Executable).Count -gt 0) { throw 'The game restarted; retry after it exits.' }
        # Only the CURRENT receipt-owned installer is executed. A script inside
        # the downloaded archive is never used to perform this installation.
        $null = & $trustedInstaller -GamePath $game.Executable -PackagePath $package
        $after = Get-AZSGInstalledReceipt $game
        if ([string]$after.Receipt.Version -cne $release.Version) { throw 'Installer did not finalize the requested plugin version.' }
        $installedFingerprint = Get-AZSGScannerFingerprint $game $after
        $result.gameSha256 = (Get-FileHash -LiteralPath $game.Executable -Algorithm SHA256).Hash.ToLowerInvariant()
        $result.gameChanged = ($result.gameSha256 -ine [string]$installation.Receipt.GameExeSHA256)
        $result.compatibility = Get-AZSGCompatibility $result.gameSha256 (Get-Item -LiteralPath $game.Executable).Length $installedFingerprint
        $result.status = 'installed'; $result.installedVersion = $release.Version; $result.pendingPackage = $null
        Write-AZSGUpdateState $updateRoot $result
        return $result
    } finally { $lock.Dispose() }
}

function Invoke-AZSGUpdate([string]$GamePath, [switch]$CheckOnly, [switch]$WaitForExit) {
    $game = Get-AZSGGame $GamePath
    # The exit callback waits BEFORE acquiring the launcher/install mutex and
    # before looking at receipts, hashes or the network. This avoids deadlocking
    # a launcher and ensures a game's own update is observed after it finishes.
    if ($WaitForExit) { Wait-AZSGGameExit $game.Executable }
    $mutex = [Threading.Mutex]::new($false, (Get-AZSGUpdateMutexName $game.Executable))
    $held = $false
    try {
        try { $held = $mutex.WaitOne() }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Could not acquire the shared launcher/update mutex.' }
        # Windows mutexes are reentrant for the same thread: a synchronous
        # Start.ps1 -> & Update.ps1 releases only this invocation's acquisition.
        $game = Get-AZSGGame $GamePath
        return Invoke-AZSGUpdateCore -Game $game -CheckOnly:$CheckOnly
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $LibraryOnly) {
    try { Invoke-AZSGUpdate -GamePath $GamePath -CheckOnly:$CheckOnly -WaitForExit:$WaitForExit | ConvertTo-Json -Depth 8 }
    catch {
        $updateError = $_
        [pscustomobject]@{ schema = 1; product = 'AZSSpeedGear'; status = 'failed'; reason = $updateError.Exception.Message } | ConvertTo-Json
        throw $updateError
    }
}

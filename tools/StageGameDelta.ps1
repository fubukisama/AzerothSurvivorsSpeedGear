#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\private-game-deltas'),
    [string]$CacheIndexPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'AzerothSurvivorsTestAssets\gamebundles.json'),
    [string]$ExpectedGameSHA256 = '6ca5f4ba4eb6b26716e4b7d9e03cbd25ddafe7582dcd8e55333e070a28058afa',
    [long]$ExpectedGameBytes = 151493632
)

# Static private-artifact preparation only. This script never runs the game,
# addon code, tests or probes, and never includes saves or account settings.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$baseBundleSHA='6c1e064ffe80b5b43b2374326667ac959e2408ff885da9050ffc88091a873667'
$baseBundleBytes=936145410L
$maximumFiles=512
$maximumBytes=512MB
$utf8=New-Object Text.UTF8Encoding($false,$true)
$addons=@('AZSSpellMeter','KeijinUI','SurvivorsDragonUi')
$extensions=@('.lua','.toc','.xml','.blp','.tga','.png','.ttf','.dds','.md','.txt')
$excludedFolders=@('.git','Updater','logs','backup','backups','saved','saves','account','accounts','WTF','Cache')

function Assert-NoLinks([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrEmpty($cursor)) {
        if(Test-Path -LiteralPath $cursor) {
            if(((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Linked input/output path is not packaged: $cursor"
            }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent -eq $cursor){break}
        $cursor=$parent
    }
}
function Assert-Within([string]$Path,[string]$Root) {
    if(-not $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Artifact path leaves its selected root.'
    }
}
function Get-ByteSHA([byte[]]$Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}
    finally{$algorithm.Dispose()}
}
function Get-FileSHA([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Addon-Files([string]$Root) {
    Assert-NoLinks $Root
    if(-not (Test-Path -LiteralPath $Root -PathType Container)){throw "Addon folder missing: $Root"}
    $queue=New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    while($queue.Count -gt 0) {
        $directory=$queue.Dequeue()
        foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Linked addon entry is not packaged: $($item.FullName)"
            }
            if($item.PSIsContainer) {
                if($excludedFolders -notcontains $item.Name){$queue.Enqueue($item.FullName)}
            } elseif($extensions -contains $item.Extension.ToLowerInvariant()) {
                $item.FullName
            }
        }
    }
}
function Assert-ZipIdentity([string]$Path,[byte[]]$ManifestBytes,$Entries) {
    Assert-NoLinks $Path
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if($archive.Entries.Count -ne $Entries.Count+1){throw 'Delta ZIP has an unexpected file count.'}
        $manifestEntry=$archive.GetEntry('delta.json')
        if($null -eq $manifestEntry -or $manifestEntry.Length -ne $ManifestBytes.Length){throw 'Delta manifest missing or changed.'}
        $stream=$manifestEntry.Open();$algorithm=[Security.Cryptography.SHA256]::Create()
        try{$manifestSHA=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
        finally{$algorithm.Dispose();$stream.Dispose()}
        if($manifestSHA -cne (Get-ByteSHA $ManifestBytes)){throw 'Cached delta belongs to another source snapshot.'}
        foreach($item in $Entries) {
            $entry=$archive.GetEntry($item.path)
            if($null -eq $entry -or $entry.Length -ne $item.bytes){throw ('Delta entry size mismatch: '+$item.path)}
            $stream=$entry.Open();$algorithm=[Security.Cryptography.SHA256]::Create()
            try{$sha=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
            finally{$algorithm.Dispose();$stream.Dispose()}
            if($sha -cne $item.sha256){throw ('Delta entry identity mismatch: '+$item.path)}
        }
    } finally {$archive.Dispose()}
}

$gameExe=[IO.Path]::GetFullPath($GamePath)
Assert-NoLinks $gameExe
if([IO.Path]::GetFileName($gameExe) -ine 'AzerothSurvivors.exe' -or -not (Test-Path -LiteralPath $gameExe -PathType Leaf)) {
    throw 'GamePath must name the installed AzerothSurvivors.exe.'
}
if($ExpectedGameSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $ExpectedGameBytes -lt 1){throw 'Invalid expected current-game identity.'}
$gameRoot=[IO.Path]::GetDirectoryName($gameExe)
$output=[IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
Assert-NoLinks $output
if($output -ieq $gameRoot -or $output.StartsWith($gameRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Artifacts must be staged outside the installed game folder.'
}
if((Get-Item -LiteralPath $gameExe).Length -ne $ExpectedGameBytes -or (Get-FileSHA $gameExe) -cne $ExpectedGameSHA256) {
    throw 'Current EXE changed; inspect and explicitly pin the new identity before staging.'
}
$index=Get-Content -LiteralPath $CacheIndexPath -Raw | ConvertFrom-Json
$base=@($index.bundles | Where-Object {$_.bundleSha256 -ceq $baseBundleSHA -and $_.bundleBytes -eq $baseBundleBytes})
if($index.schema -ne 1 -or $base.Count -ne 1){throw 'Expected reusable base-bundle identity is missing.'}
$baseMPQs=@($base[0].files | Where-Object {$_.path -clike 'Data/*.MPQ'})
if($baseMPQs.Count -ne 11){throw 'Expected eleven cached base MPQs.'}
foreach($item in $baseMPQs) {
    $path=[IO.Path]::GetFullPath((Join-Path $gameRoot $item.path))
    Assert-Within $path $gameRoot; Assert-NoLinks $path
    if((Get-Item -LiteralPath $path).Length -ne $item.bytes -or (Get-FileSHA $path) -cne $item.sha256) {
        throw ('A cached MPQ changed and needs a new delta plan: '+$item.path)
    }
}
$newMPQ=Join-Path $gameRoot 'Data\patch-C.MPQ'
Assert-NoLinks $newMPQ
if((Get-Item -LiteralPath $newMPQ).Length -ne 59489189 -or (Get-FileSHA $newMPQ) -cne 'b2b17d7732de1902e1befed90eeed0fc9588c88d8951a396559f6937c3928a44') {
    throw 'The new patch-C identity changed.'
}
$allMPQs=@(Get-ChildItem -LiteralPath (Join-Path $gameRoot 'Data') -File | Where-Object Extension -ieq '.MPQ')
if($allMPQs.Count -ne 12){throw 'An unexpected MPQ was added; update the delta plan first.'}
$sourcePaths=@($gameExe,$newMPQ,(Join-Path $gameRoot 'avrt.dll'))
$addonVersions=@()
foreach($addon in $addons) {
    $root=Join-Path $gameRoot ('benilla-config\AddOns\'+$addon)
    $sourcePaths+=@(Addon-Files $root)
    $toc=Join-Path $root ($addon+'.toc')
    $version=@([IO.File]::ReadAllLines($toc) | Where-Object {$_ -match '^##\s*Version\s*:'})
    if($version.Count -ne 1){throw ('Addon TOC version is ambiguous: '+$addon)}
    $addonVersions += [ordered]@{name=$addon;version=($version[0] -replace '^##\s*Version\s*:\s*','').Trim()}
}
$sources=@{}; $relativePaths=@()
foreach($source in $sourcePaths) {
    $full=[IO.Path]::GetFullPath($source)
    Assert-Within $full $gameRoot; Assert-NoLinks $full
    $relative=$full.Substring($gameRoot.Length+1).Replace('\','/')
    if($relative -match '(^/|\\|:|[\x00-\x1f\x7f]|(^|/)\.\.?(/|$))'){throw 'Unsafe delta-relative path.'}
    if($sources.ContainsKey($relative)){throw 'Duplicate source path.'}
    $sources[$relative]=$full;$relativePaths+=$relative
}
[Array]::Sort($relativePaths,[StringComparer]::Ordinal)
$entries=@();[long]$expandedBytes=0
foreach($relative in $relativePaths) {
    $file=Get-Item -LiteralPath $sources[$relative]
    if($file.Length -lt 1 -or $file.Length -gt 256MB){throw ('Source file exceeds delta bounds: '+$relative)}
    $entries += [ordered]@{path=$relative;bytes=$file.Length;sha256=(Get-FileSHA $file.FullName)}
    $expandedBytes+=$file.Length
}
if($entries.Count -gt $maximumFiles -or $expandedBytes -gt $maximumBytes){throw 'Delta exceeds bounded file/byte limits.'}
foreach($addon in $addonVersions) {
    $toc=Join-Path $gameRoot ('benilla-config\AddOns\'+$addon.name+'\'+$addon.name+'.toc')
    $current=@([IO.File]::ReadAllLines($toc) | Where-Object {$_ -match '^##\s*Version\s*:'})
    if($current.Count -ne 1 -or ($current[0] -replace '^##\s*Version\s*:\s*','').Trim() -cne $addon.version) {
        throw 'Addon version changed while taking the source snapshot.'
    }
}
$manifest=[ordered]@{schema=1;product='AzerothSurvivorsPrivateTestDelta';baseBundleSHA256=$baseBundleSHA;baseBundleBytes=$baseBundleBytes;
    gameVersion=$null;gameSHA256=$ExpectedGameSHA256;gameBytes=$ExpectedGameBytes;addons=$addonVersions;files=$entries}
$manifestBytes=$utf8.GetBytes(($manifest | ConvertTo-Json -Depth 8))
$fingerprint=Get-ByteSHA $manifestBytes
New-Item -ItemType Directory -Path $output -Force | Out-Null
$zip=Join-Path $output ('delta-'+$fingerprint+'.zip')
Assert-Within $zip $output
if(Test-Path -LiteralPath $zip) {
    Assert-ZipIdentity $zip $manifestBytes $entries
    [pscustomobject]@{Reused=$true;ZipPath=$zip;SHA256=(Get-FileSHA $zip);Bytes=(Get-Item -LiteralPath $zip).Length;ManifestSHA256=$fingerprint;Files=$entries.Count;ExpandedBytes=$expandedBytes;GameSHA256=$ExpectedGameSHA256;Addons=$addonVersions} | ConvertTo-Json -Depth 5 -Compress
    return
}
$stage=Join-Path $output ('stage-'+[guid]::NewGuid().ToString('N'))
Assert-Within $stage $output; Assert-NoLinks $stage
New-Item -ItemType Directory -Path $stage | Out-Null
foreach($entry in $entries) {
    $source=$sources[$entry.path]
    $target=[IO.Path]::GetFullPath((Join-Path $stage $entry.path))
    Assert-Within $target $stage; Assert-NoLinks $source; Assert-NoLinks $target
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
    if((Get-Item -LiteralPath $target).Length -ne $entry.bytes -or (Get-FileSHA $target) -cne $entry.sha256 -or
       (Get-FileSHA $source) -cne $entry.sha256){throw ('Input changed during delta copy: '+$entry.path)}
}
foreach($addon in $addons) {
    $now=@(Addon-Files (Join-Path $gameRoot ('benilla-config\AddOns\'+$addon)))
    $expected=@($entries | Where-Object {$_.path.StartsWith('benilla-config/AddOns/'+$addon+'/',[StringComparison]::Ordinal)})
    if($now.Count -ne $expected.Count){throw 'Addon file set changed during staging.'}
}
foreach($entry in $entries) {
    if((Get-FileSHA $sources[$entry.path]) -cne $entry.sha256){throw ('Input changed after staging: '+$entry.path)}
}
[IO.File]::WriteAllBytes((Join-Path $stage 'delta.json'),$manifestBytes)
$temporary=$zip+'.'+[guid]::NewGuid().ToString('N')+'.partial'
Assert-Within $temporary $output; Assert-NoLinks $temporary
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$temporary,[IO.Compression.CompressionLevel]::Optimal,$false)
Assert-ZipIdentity $temporary $manifestBytes $entries
Move-Item -LiteralPath $temporary -Destination $zip
[pscustomobject]@{Reused=$false;ZipPath=$zip;SHA256=(Get-FileSHA $zip);Bytes=(Get-Item -LiteralPath $zip).Length;ManifestSHA256=$fingerprint;Files=$entries.Count;ExpandedBytes=$expandedBytes;GameSHA256=$ExpectedGameSHA256;StagePath=$stage;Addons=$addonVersions} | ConvertTo-Json -Depth 5 -Compress

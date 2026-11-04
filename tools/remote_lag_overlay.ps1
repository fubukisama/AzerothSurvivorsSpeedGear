#requires -Version 7.2
# Dot-source only from the disposable remote Windows game harness.
# Delta assets remain private; addon settings below are synthetic, not user saves.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Text.Json
function Assert-LagRemote {
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        throw 'blocked_lag_remote_only'
    }
}
function Assert-LagInside([string]$Path,[string]$Root) {
    if(-not $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'blocked_lag_path'}
}
function Assert-LagNoLinks([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrEmpty($cursor)) {
        if(Test-Path -LiteralPath $cursor) {
            if(((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'blocked_lag_link'}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
}
function Get-LagSHA([string]$Path) {return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Assert-LagJsonKeys($Node) {
    if($Node.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Node.EnumerateObject()) {
            if(-not $seen.Add($property.Name)){throw 'blocked_lag_duplicate_json_key'}
            Assert-LagJsonKeys $property.Value
        }
    } elseif($Node.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach($value in $Node.EnumerateArray()){Assert-LagJsonKeys $value}
    }
}
function Assert-LagShape($Value,[string[]]$Keys) {
    if($null -eq $Value){throw 'blocked_lag_manifest_shape'}
    $actual=@($Value.PSObject.Properties.Name)
    if($actual.Count -ne $Keys.Count){throw 'blocked_lag_manifest_shape'}
    foreach($key in $actual){if($Keys -cnotcontains $key){throw 'blocked_lag_manifest_shape'}}
}
function Test-LagInteger($Value,[long]$Minimum,[long]$Maximum) {
    return ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Minimum -and $Value -le $Maximum
}
function Test-LagEntryPath([string]$Path) {
    if($Path -cmatch '(^/|\\|:|[\x00-\x1f\x7f]|(^|/)\.\.?(/|$))'){return $false}
    if($Path -cin @('AzerothSurvivors.exe','Data/patch-C.MPQ','avrt.dll')){return $true}
    if($Path -cnotmatch '^benilla-config/AddOns/(AZSSpellMeter|KeijinUI|SurvivorsDragonUi)/.+$'){return $false}
    if($Path -match '(^|/)(\.git|Updater|logs|backup|backups|saved|saves|account|accounts|WTF|Cache)(/|$)'){return $false}
    return [IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.lua','.toc','.xml','.blp','.tga','.png','.ttf','.dds','.md','.txt')
}

function Apply-PrivateGameDelta($Identity,[string]$FixtureRoot) {
    Assert-LagRemote
    $fixture=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
    Assert-LagInside $fixture ([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\'));Assert-LagNoLinks $fixture
    $archivePath=[IO.Path]::GetFullPath($env:AZSG_GAME_DELTA_PATH)
    Assert-LagInside $archivePath ([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\'));Assert-LagNoLinks $archivePath
    if($env:AZSG_GAME_DELTA_SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $env:AZSG_GAME_DELTA_BYTES -cnotmatch '^[1-9][0-9]{0,9}$'){throw 'blocked_lag_delta_identity'}
    $compressed=[long]$env:AZSG_GAME_DELTA_BYTES
    if($compressed -gt 512MB -or (Get-Item -LiteralPath $archivePath).Length -ne $compressed -or (Get-LagSHA $archivePath) -cne $env:AZSG_GAME_DELTA_SHA256){throw 'blocked_lag_delta_digest'}
    $base=Join-Path $fixture 'private-bundle'
    Assert-LagNoLinks $base
    $baseExe=Join-Path $base 'AzerothSurvivors.exe'
    if((Get-LagSHA $baseExe) -cne $Identity.sha256 -or (Get-Item -LiteralPath $baseExe).Length -ne $Identity.size){throw 'blocked_lag_base_changed'}
    $stage=Join-Path $fixture ('private-delta-'+[guid]::NewGuid().ToString('N'))
    Assert-LagInside $stage $fixture
    New-Item -ItemType Directory -Path $stage | Out-Null
    $zip=[IO.Compression.ZipFile]::OpenRead($archivePath)
    $utf8=[Text.UTF8Encoding]::new($false,$true)
    try {
        if($zip.Entries.Count -lt 4 -or $zip.Entries.Count -gt 513){throw 'blocked_lag_entry_count'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $zipEntries=@{}
        [long]$expanded=0
        foreach($entry in $zip.Entries) {
            $name=$entry.FullName
            $kind=($entry.ExternalAttributes -shr 16) -band 0xf000
            if(-not $seen.Add($name) -or $kind -notin @(0,0x8000) -or ($entry.ExternalAttributes -band 0x400) -ne 0){throw 'blocked_lag_entry_type'}
            if($name -cne 'delta.json' -and -not (Test-LagEntryPath $name)){throw 'blocked_lag_entry_path'}
            if($entry.Length -lt 1 -or $entry.Length -gt 256MB){throw 'blocked_lag_entry_size'}
            $expanded+=$entry.Length;if($expanded -gt 512MB){throw 'blocked_lag_expanded_size'}
            $zipEntries[$name]=$entry
        }
        $manifestEntry=$zipEntries['delta.json']
        if($null -eq $manifestEntry -or $manifestEntry.Length -gt 128KB){throw 'blocked_lag_manifest_bounds'}
        $stream=$manifestEntry.Open();$memory=[IO.MemoryStream]::new();$buffer=[byte[]]::new(65536);[long]$count=0
        try {
            while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $count+=$read
                if($count -gt 128KB -or $count -gt $manifestEntry.Length){throw 'blocked_lag_manifest_expansion'}
                $memory.Write($buffer,0,$read)
            }
            if($count -ne $manifestEntry.Length){throw 'blocked_lag_manifest_length'}
            $manifestText=$utf8.GetString($memory.ToArray())
        } finally {$memory.Dispose();$stream.Dispose()}
        $document=[System.Text.Json.JsonDocument]::Parse([string]$manifestText)
        try{Assert-LagJsonKeys $document.RootElement}finally{$document.Dispose()}
        $manifest=$manifestText | ConvertFrom-Json -ErrorAction Stop
        Assert-LagShape $manifest @('schema','product','baseBundleSHA256','baseBundleBytes','gameVersion','gameSHA256','gameBytes','addons','files')
        if(-not (Test-LagInteger $manifest.schema 1 1) -or $manifest.product -isnot [string] -or $manifest.product -cne 'AzerothSurvivorsPrivateTestDelta' -or
           $manifest.baseBundleSHA256 -isnot [string] -or -not (Test-LagInteger $manifest.baseBundleBytes 1 2147483647) -or
           $manifest.baseBundleSHA256 -cne $Identity.bundleSha256 -or $manifest.baseBundleBytes -ne $Identity.bundleBytes -or
           $manifest.baseBundleSHA256 -cne $env:AZSG_GAME_BUNDLE_SHA256 -or [long]$manifest.baseBundleBytes -ne [long]$env:AZSG_GAME_BUNDLE_BYTES){throw 'blocked_lag_manifest_base'}
        if($null -ne $manifest.gameVersion -and $manifest.gameVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$'){throw 'blocked_lag_game_version'}
        if($manifest.gameSHA256 -isnot [string] -or $manifest.gameSHA256 -cnotmatch '^[a-f0-9]{64}$' -or -not (Test-LagInteger $manifest.gameBytes 1 268435456)){throw 'blocked_lag_game_identity'}
        if(@($manifest.files).Count -ne $zip.Entries.Count-1 -or @($manifest.addons).Count -ne 3){throw 'blocked_lag_manifest_count'}
        $addonNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($addon in $manifest.addons) {
            Assert-LagShape $addon @('name','version')
            if($addon.name -cnotin @('AZSSpellMeter','KeijinUI','SurvivorsDragonUi') -or -not $addonNames.Add($addon.name) -or
               $addon.version -isnot [string] -or $addon.version.Length -lt 1 -or $addon.version.Length -gt 128){throw 'blocked_lag_addon_identity'}
        }
        $wanted=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($item in $manifest.files) {
            Assert-LagShape $item @('path','bytes','sha256')
            if($item.path -isnot [string] -or -not (Test-LagEntryPath $item.path) -or -not $wanted.Add($item.path) -or
               -not (Test-LagInteger $item.bytes 1 268435456) -or $item.sha256 -isnot [string] -or $item.sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'blocked_lag_file_identity'}
            $entry=$zipEntries[$item.path]
            if($null -eq $entry -or $entry.FullName -cne $item.path -or $entry.Length -ne $item.bytes){throw 'blocked_lag_file_set'}
            $target=[IO.Path]::GetFullPath((Join-Path $stage $item.path))
            Assert-LagInside $target $stage;Assert-LagNoLinks $target
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            $incoming=$entry.Open();$outgoing=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $buffer=[byte[]]::new(65536);[long]$count=0
                while(($read=$incoming.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $count+=$read;if($count -gt $item.bytes){throw 'blocked_lag_file_expansion'}
                    $outgoing.Write($buffer,0,$read)
                }
                if($count -ne $item.bytes){throw 'blocked_lag_file_length'}
            } finally {$incoming.Dispose();$outgoing.Dispose()}
            if((Get-Item -LiteralPath $target).Length -ne $item.bytes -or (Get-LagSHA $target) -cne $item.sha256){throw 'blocked_lag_expanded_digest'}
        }
        foreach($required in @('AzerothSurvivors.exe','Data/patch-C.MPQ','avrt.dll')){if(-not $wanted.Contains($required)){throw 'blocked_lag_required_file'}}
        $exe=@($manifest.files | Where-Object path -ceq 'AzerothSurvivors.exe')
        if($exe.Count -ne 1 -or $exe[0].bytes -ne $manifest.gameBytes -or $exe[0].sha256 -cne $manifest.gameSHA256){throw 'blocked_lag_exe_identity'}
        foreach($addon in $manifest.addons) {
            $toc='benilla-config/AddOns/'+$addon.name+'/'+$addon.name+'.toc'
            if(-not $wanted.Contains($toc)){throw 'blocked_lag_missing_toc'}
            $versions=@([IO.File]::ReadAllLines((Join-Path $stage $toc)) | Where-Object {$_ -match '^##\s*Version\s*:'})
            if($versions.Count -ne 1 -or ($versions[0] -replace '^##\s*Version\s*:\s*','').Trim() -cne $addon.version){throw 'blocked_lag_toc_version'}
        }
    } finally {$zip.Dispose()}
    # Base extraction was verified independently; overlay only these verified
    # files, before any game process exists. All remaining cached MPQs stay put.
    foreach($item in $manifest.files) {
        $target=[IO.Path]::GetFullPath((Join-Path $base $item.path))
        Assert-LagInside $target $base;Assert-LagNoLinks $target
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
        if((Test-Path -LiteralPath $target) -and $item.path -cne 'AzerothSurvivors.exe'){throw 'blocked_lag_unexpected_overlay_target'}
        Copy-Item -LiteralPath (Join-Path $stage $item.path) -Destination $target -Force
        if((Get-LagSHA $target) -cne $item.sha256){throw 'blocked_lag_overlay_digest'}
    }
    $script:lagOverlayRoot=$base;$script:lagFixtureRoot=$fixture;$script:lagDeltaManifest=$manifest
    return [pscustomobject]@{version=$manifest.gameVersion;sha256=$manifest.gameSHA256;size=$manifest.gameBytes;assetsSha256=$null;
        bundleSha256=$Identity.bundleSha256;bundleBytes=$Identity.bundleBytes;deltaSHA256=$env:AZSG_GAME_DELTA_SHA256;
        deltaBytes=$compressed;deltaFiles=@($manifest.files).Count;avrtOmitted=$true}
}

function Copy-LagAddons([string]$GameRoot,[string]$Variant='all') {
    Assert-LagRemote
    if($Variant -cnotin @('all','no_keijin','speedgear_only')){throw 'blocked_lag_variant'}
    if($null -eq (Get-Variable -Name lagDeltaManifest -Scope Script -ErrorAction SilentlyContinue)){throw 'blocked_lag_overlay_required'}
    $root=[IO.Path]::GetFullPath($GameRoot).TrimEnd('\')
    Assert-LagInside $root $script:lagFixtureRoot;Assert-LagNoLinks $root
    $selected=@(if($Variant -ceq 'all'){'AZSSpellMeter';'KeijinUI';'SurvivorsDragonUi'}elseif($Variant -ceq 'no_keijin'){'AZSSpellMeter';'SurvivorsDragonUi'})
    $state=Join-Path $root 'benilla-config'
    $copied=0
    foreach($addon in $selected) {
        $prefix='benilla-config/AddOns/'+$addon+'/'
        foreach($item in @($script:lagDeltaManifest.files | Where-Object {$_.path.StartsWith($prefix,[StringComparison]::Ordinal)})) {
            $source=Join-Path $script:lagOverlayRoot $item.path;$target=[IO.Path]::GetFullPath((Join-Path $root $item.path))
            Assert-LagInside $target $root;Assert-LagNoLinks $source;Assert-LagNoLinks $target
            if(Test-Path -LiteralPath $target){throw 'blocked_lag_existing_addon_target'}
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
            if((Get-LagSHA $target) -cne $item.sha256){throw 'blocked_lag_addon_digest'}
            $copied++
        }
    }
    $settings=@{
        AZSSpellMeter="AZSSpellMeterDB = { mini = true, shown = true, view = 'damage', viewChosen = true }`n";
        KeijinUI="KeijinUIDB = { lang = 'zh', combatTextMode = 'scroll', combatTextPosition = 'fixed', combatTextMerge = true, combatTextIcons = true, combatTextSize = 0.76 }`n";
        SurvivorsDragonUi="SurvivorsDragonUiSctMode = 'off'`nSurvivorsDragonUiCopyEnabled = false`n"
    }
    $utf8=[Text.UTF8Encoding]::new($false)
    foreach($addon in $selected) {
        $saved=Join-Path $state ('saved\'+$addon+'.lua');Assert-LagInside $saved $root;Assert-LagNoLinks $saved
        if(Test-Path -LiteralPath $saved){throw 'blocked_lag_existing_saved_fixture'}
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($saved)) -Force | Out-Null
        [IO.File]::WriteAllText($saved,$settings[$addon],$utf8)
    }
    # Call this helper after the caller has created its redirected AppData.
    $appData=Join-Path $root 'AppData'
    if(-not (Test-Path -LiteralPath $appData -PathType Container)){throw 'blocked_lag_appdata_not_ready'}
    $language=Join-Path $appData 'wenilla-rogue\language.txt';Assert-LagInside $language $root;Assert-LagNoLinks $language
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($language)) -Force | Out-Null
    [IO.File]::WriteAllText($language,'zh',$utf8)
    # avrt.dll is intentionally omitted: its bootstrap updater can replace the
    # pinned Lua payload before game entry. This is a Lua-addon comparison.
    return [pscustomobject]@{variant=$Variant;addons=@($selected);files=$copied;avrtOmitted=$true;syntheticSettings=$true;language='zh'}
}

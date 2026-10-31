# Dot-sourced only after the remote runner has verified and provisioned assets.
# Observations use the production button's actual GetText and physical OS input.
function Invoke-LauncherAcceptance([string]$GameRoot, [string]$Assets, [string]$OfficialExe) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') { throw 'blocked_remote_only' }
    $script:la = [ordered]@{schema=1; status='blocked'; reason='not_started'; phase='provision'; criteria=@();
        session=$null; current=$null; rows=[Collections.Generic.List[object]]::new(); inputs=[Collections.Generic.List[object]]::new();
        native=[Collections.Generic.List[object]]::new(); nativeLog=[Collections.Generic.List[object]]::new();
        nativeSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); held=@{};
        gracefulExit=$false; cleanupWarning=$null; exceptionType=$null; errorLine=$null;
        scope='Actual launcher GetText and visibility in one real game process, using physical OS input. No screenshot, general gameplay or future-build certification.'}
    function Decode-LauncherHex([string]$Value) {
        if ($Value -cnotmatch '^(?:[0-9A-F]{2}){1,256}$') { throw 'blocked_caption_encoding' }
        $bytes=[byte[]]::new($Value.Length/2)
        for($i=0;$i -lt $bytes.Length;$i++){ $bytes[$i]=[Convert]::ToByte($Value.Substring($i*2,2),16) }
        return ([Text.UTF8Encoding]::new($false,$true)).GetString($bytes)
    }
    function Read-LauncherRow($Row) {
        $match=[regex]::Match($Row.Payload,'^(AZSGL1\|[A-Za-z0-9_.|_-]{1,1800})(?:[^A-Za-z0-9_.|_-]|$)')
        if(-not $match.Success){return $null}
        $p=$match.Groups[1].Value.Split('|'); if($p.Count -ne 25){return $null}
        try {
            return [pscustomobject]@{fileTime=[long]$Row.FileTime;seq=[long]$p[1];instance=[long]$p[2];phase=$p[3];
                speed100=[int]$p[4];desiredSpeed100=[int]$p[5];active=[int]$p[6];guard=[int]$p[7];confirmedSpeed100=[int]$p[8];
                measured=[double]::Parse($p[9],[Globalization.CultureInfo]::InvariantCulture);mismatch=[int]$p[10];shown=[int]$p[11];
                caption=(Decode-LauncherHex $p[12]);expectedCaption=(Decode-LauncherHex $p[13]);captionHex=$p[12];
                actions=[int]$p[14];direction=[int]$p[15];before=[int]$p[16];after=[int]$p[17];accepted=[int]$p[18];frames=[int]$p[19];
                rawT=[double]::Parse($p[20],[Globalization.CultureInfo]::InvariantCulture);chat=[int]$p[21];menu=[int]$p[22];locale=$p[23];kind=$p[24]}
        } catch { return $null }
    }
    function Drain-Launcher {
        $row=$null
        while($script:la.session.Rows.TryDequeue([ref]$row)){
            $parsed=Read-LauncherRow $row
            if($null -ne $parsed -and $script:la.rows.Count -lt 2000){$script:la.rows.Add($parsed);$script:la.current=$parsed}
            $row=$null
        }
        $snapshot=Read-NativeBackendEvidence $GameRoot
        if($snapshot.statusAvailable -and ($script:la.native.Count -eq 0 -or $script:la.native[$script:la.native.Count-1].speed100 -ne $snapshot.speed100)){
            $script:la.native.Add([pscustomobject]@{fileTime=[AZSGRemoteGame]::Wall();speed100=$snapshot.speed100;backend=$snapshot.backend;transport=$snapshot.transport})
        }
        foreach($line in $snapshot.safeLog){
            $change=[regex]::Match($line,'^speed100=([0-9]{1,4}) simulation_calls=([0-9]{1,20})$')
            if($change.Success -and $script:la.nativeSeen.Add([string]$line)){
                $script:la.nativeLog.Add([pscustomobject]@{fileTime=[AZSGRemoteGame]::Wall();speed100=[int]$change.Groups[1].Value;simulationCalls=[ulong]$change.Groups[2].Value;backend=$snapshot.backend;message=[string]$line})
            }
        }
        if($script:la.session.Child.HasExited){throw 'blocked_game_exited'}
    }
    function Assert-Launcher([string]$Name,[bool]$Okay,$Observed){
        $script:la.criteria += [pscustomobject]@{name=$Name;passed=$Okay;observed=$Observed}
        if(-not $Okay){throw ('failed_'+$Name)}
    }
    function Wait-Launcher([string]$Name,[scriptblock]$Condition,[int]$Seconds=6){
        $until=[AZSGRemoteGame]::Wall()+$Seconds*10000000L
        do{Drain-Launcher;if($null -ne $script:la.current -and (& $Condition)){Assert-Launcher $Name $true $script:la.current;return};Start-Sleep -Milliseconds 50}while([AZSGRemoteGame]::Wall() -lt $until)
        Assert-Launcher $Name $false $script:la.current
    }
    function Key-Launcher([uint16]$Key,[bool]$Down){
        $okay=$script:la.session.Key($Key,$Down)
        $script:la.inputs.Add([pscustomobject]@{fileTime=[AZSGRemoteGame]::Wall();kind='keyboard';vk=$Key;down=$Down;sent=$okay})
        if(-not $okay){throw 'blocked_input_or_foreground'}
        $script:la.held[[int]$Key]=$Down
    }
    function Pause-Launcher([int]$Milliseconds){
        $until=[AZSGRemoteGame]::Wall()+$Milliseconds*10000L
        do{Drain-Launcher;Start-Sleep -Milliseconds 50}while([AZSGRemoteGame]::Wall() -lt $until)
        Drain-Launcher
    }
    function Tap-Launcher([uint16]$Key){Key-Launcher $Key $true;Pause-Launcher 450;Key-Launcher $Key $false}
    try {
        $destination=[IO.Path]::GetFullPath($GameRoot)
        if(-not $destination.StartsWith($script:fixtureRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)){throw 'blocked_fixture_path'}
        New-Item -ItemType Directory -Path $destination | Out-Null
        $data=Join-Path $destination 'Data';New-Item -ItemType Directory -Path $data | Out-Null
        foreach($file in @(Get-ChildItem -LiteralPath $Assets -File)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $data $file.Name)}
        Copy-Item -LiteralPath $OfficialExe -Destination (Join-Path $destination 'AzerothSurvivors.exe')
        foreach($runtimeFile in $script:runtimeDllSources){Copy-Item -LiteralPath $runtimeFile.path -Destination (Join-Path $destination $runtimeFile.name)}
        $state=Join-Path $destination 'benilla-config';$addon=Join-Path $state 'AddOns\AZSSpeedGear'
        New-Item -ItemType Directory -Path $addon -Force | Out-Null
        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $script:package 'AddOns\AZSSpeedGear') -File)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $addon $file.Name)}
        Copy-Item -LiteralPath (Join-Path $script:package 'Native\dwmapi.dll') -Destination (Join-Path $destination 'dwmapi.dll')
        $observer=Join-Path $state 'AddOns\AZSGLauncherTest';New-Item -ItemType Directory -Path $observer -Force | Out-Null
        Write-Text (Join-Path $observer 'AZSGLauncherTest.toc') "## Interface: 11200`n## Title: AZSG launcher observation`n## Dependencies: AZSSpeedGear`nTelemetry.lua`n"
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'remote_launcher_telemetry.lua') -Destination (Join-Path $observer 'Telemetry.lua')
        Write-Text (Join-Path $state 'config.toml') "[cvars]`ngxWindow = `"1`"`ngxResolution = `"$script:viewport`"`ngxVSync = `"0`"`nfarclip = `"177`"`nshadowLevel = `"0`"`n"
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $destination 'AzerothSurvivors.exe'))
        $info.WorkingDirectory=$destination;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        foreach($credential in @('AZSG_GAME_BUNDLE_URL','GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN')){[void]$info.Environment.Remove($credential)}
        $info.Environment['WGPU_BACKEND']='dx12';$info.Environment['WGPU_FORCE_FALLBACK_ADAPTER']='1';$info.Environment['WGPU_ADAPTER_NAME']='Microsoft Basic Render Driver'
        $info.Environment['RUST_LOG']='info,wgpu_core=warn,wgpu_hal=warn,naga=warn';$info.Environment['WOW_WIN']=$script:viewport;$info.Environment['BENILLA_HOME']=$state
        $appData=Join-Path $destination 'AppData';New-Item -ItemType Directory -Path $appData | Out-Null
        $info.Environment['APPDATA']=$appData;$info.Environment['LOCALAPPDATA']=$appData
        $script:la.session=[AZSGRemoteGame]::new();$script:la.session.Start($info);$script:la.phase='startup'
        $start=[AZSGRemoteGame]::Wall();$lastInput=0L;$heldUntil=0L;$lastEscape=-1L;$playing=$false
        while(([AZSGRemoteGame]::Wall()-$start)/1e7 -lt $script:startupSeconds){
            Drain-Launcher;$now=[AZSGRemoteGame]::Wall();$latest=$script:la.current
            if($null -ne $latest -and $latest.phase -ceq 'playing' -and $latest.active -eq 1){$playing=$true;break}
            if($script:la.held.ContainsKey(0x57) -and $script:la.held[0x57] -and $now -ge $heldUntil){Key-Launcher 0x57 $false}
            if(($now-$lastInput)/1e7 -ge 5 -and -not $script:la.session.LoadingCoverWaiting){
                $lastInput=$now
                if($null -ne $latest -and ($latest.chat -eq 1 -or $latest.menu -eq 1)){
                    if($latest.seq -gt $lastEscape){Tap-Launcher 0x1b;$lastEscape=$latest.seq}
                }elseif($null -ne $latest -and $latest.phase -ceq 'ready'){
                    Key-Launcher 0x57 $true;$heldUntil=$now+40000000L
                }elseif($null -eq $latest -and $script:la.session.Focus()){Tap-Launcher 0x0d}
            }
            Start-Sleep -Milliseconds 50
        }
        if($script:la.held.ContainsKey(0x57) -and $script:la.held[0x57]){Key-Launcher 0x57 $false}
        if(-not $playing){throw 'blocked_no_playing'}
        $script:la.phase='captions'
        $initial=$script:la.current
        Assert-Launcher 'initial_numeric_1x' ($initial.shown -eq 1 -and $initial.speed100 -eq 100 -and $initial.caption -ceq $initial.expectedCaption -and $initial.caption.Contains(([char]0xD7).ToString()+'1')) $initial
        Drain-Launcher;$actionStarted=[AZSGRemoteGame]::Wall()
        Tap-Launcher 0x45
        Wait-Launcher 'physical_e_records_numeric_2x' {
            @($script:la.rows|Where-Object{$_.fileTime -ge $actionStarted -and $_.actions -eq 1 -and $_.direction -eq 1 -and $_.before -eq 100 -and $_.after -eq 200 -and $_.accepted -eq 1 -and $_.speed100 -eq 200 -and $_.shown -eq 1 -and $_.caption -ceq $_.expectedCaption -and $_.caption.Contains(([char]0xD7).ToString()+'2')}).Count -gt 0
        }
        $observeUntil=$actionStarted+50000000L
        while([AZSGRemoteGame]::Wall() -lt $observeUntil){Drain-Launcher;if($script:la.current.guard -eq 1){break};Start-Sleep -Milliseconds 50}
        $activeRows=@($script:la.rows|Where-Object{$_.active -eq 1})
        $badRows=@($activeRows|Where-Object{$_.shown -ne 1 -or $_.caption -cne $_.expectedCaption -or $_.kind -cnotin @('pending','mismatch','confirmed')})
        Assert-Launcher 'all_active_captions_match_state' ($activeRows.Count -ge 2 -and $badRows.Count -eq 0) ([pscustomobject]@{activeSamples=$activeRows.Count;invalidSamples=$badRows.Count})
        $guardRows=@($activeRows|Where-Object{$_.fileTime -ge $actionStarted -and $_.guard -eq 1})
        if($guardRows.Count -gt 0){
            $guard=$guardRows[0]
            Assert-Launcher 'observed_guard_restore_keeps_numeric_1x' ($guard.speed100 -eq 100 -and $guard.desiredSpeed100 -eq 100 -and $guard.caption -ceq $guard.expectedCaption -and $guard.caption.Contains(([char]0xD7).ToString()+'1')) $guard
        }
        Assert-Launcher 'software_adapter_observed' $script:la.session.SoftwareObserved $script:la.session.SoftwareObserved
        Assert-Launcher 'no_dropped_telemetry' ($script:la.session.Dropped -eq 0) $script:la.session.Dropped
        $script:la.status='passed';$script:la.reason='actual_launcher_text_keeps_numeric_speed_during_physical_switch'
    }catch{
        $message=[string]$_.Exception.Message
        $script:la.status=if($message -cmatch '^failed_[a-z0-9_]+$'){'failed'}else{'blocked'}
        $script:la.reason=if($message -cmatch '^(failed|blocked)_[a-z0-9_]{1,100}$'){$message}else{'blocked_launcher_harness_or_environment'}
        $script:la.exceptionType=$_.Exception.GetType().FullName;$script:la.errorLine=$_.InvocationInfo.ScriptLineNumber
    }finally{
        if($null -ne $script:la.session){
            try{
                foreach($key in @($script:la.held.Keys)){if($script:la.held[$key]){[void]$script:la.session.Key([uint16]$key,$false)}}
                if(-not $script:la.session.Child.HasExited){[void]$script:la.session.Child.CloseMainWindow();$script:la.gracefulExit=$script:la.session.Child.WaitForExit(30000)}else{$script:la.gracefulExit=$true}
                if(-not $script:la.gracefulExit){$script:la.cleanupWarning='Final disposable game close exceeded 30 seconds after the functional verdict.'}
            }catch{$script:la.cleanupWarning='Disposable game cleanup could not be confirmed.'}
            $script:la.session.Dispose()
        }
    }
    return [pscustomobject]@{schema=$script:la.schema;status=$script:la.status;reason=$script:la.reason;phase=$script:la.phase;criteria=$script:la.criteria;
        samples=$script:la.rows.ToArray();inputs=$script:la.inputs.ToArray();nativeTransitions=$script:la.native.ToArray();nativeLogEvents=$script:la.nativeLog.ToArray();
        guardFallbackObserved=(@($script:la.rows|Where-Object guard -eq 1).Count -gt 0);gracefulExit=$script:la.gracefulExit;cleanupWarning=$script:la.cleanupWarning;
        exceptionType=$script:la.exceptionType;errorLine=$script:la.errorLine;scope=$script:la.scope}
}

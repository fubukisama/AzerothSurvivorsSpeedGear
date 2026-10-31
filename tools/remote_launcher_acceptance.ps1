# Dot-sourced only after the remote runner has verified and provisioned assets.
# Observations use the production button's actual GetText and physical OS input.
function Invoke-LauncherAcceptance([string]$GameRoot, [string]$Assets, [string]$OfficialExe) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') { throw 'blocked_remote_only' }
    $script:la = [ordered]@{schema=1; status='blocked'; reason='not_started'; phase='provision'; criteria=@();
        session=$null; current=$null; rows=[Collections.Generic.List[object]]::new(); inputs=[Collections.Generic.List[object]]::new();
        native=[Collections.Generic.List[object]]::new(); nativeLog=[Collections.Generic.List[object]]::new();
        nativeSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); held=@{};
        confirmationMode=($env:AZSG_CONFIRMATION_ACCEPTANCE -ceq '1'); confirmationMetrics=$null;
        nativeSnapshots=[Collections.Generic.List[object]]::new(); latestNative=$null; lastNativeSnapshot=0L;
        gracefulExit=$false; cleanupWarning=$null; exceptionType=$null; errorLine=$null;
        scope='Actual launcher GetText and visibility in one real game process, using physical OS input. No screenshot, general gameplay or future-build certification.'}
    if($script:la.confirmationMode){$script:la.scope='Actual measurement confirmation and uninterrupted confirmed launcher text, checked against fresh raw game time and the unhooked parent clock. No movement, skill timing, screenshot or future-build certification.'}
    function Decode-LauncherHex([string]$Value) {
        if ($Value -cnotmatch '^(?:[0-9A-F]{2}){1,256}$') { throw 'blocked_caption_encoding' }
        $bytes=[byte[]]::new($Value.Length/2)
        for($i=0;$i -lt $bytes.Length;$i++){ $bytes[$i]=[Convert]::ToByte($Value.Substring($i*2,2),16) }
        return ([Text.UTF8Encoding]::new($false,$true)).GetString($bytes)
    }
    function Read-LauncherRow($Row) {
        $match=[regex]::Match($Row.Payload,'^(AZSGL1\|[A-Za-z0-9_.|_-]{1,1800})(?:[^A-Za-z0-9_.|_-]|$)')
        if(-not $match.Success){return $null}
        $p=$match.Groups[1].Value.Split('|'); if($p.Count -ne 30){return $null}
        try {
            return [pscustomobject]@{fileTime=[long]$Row.FileTime;seq=[long]$p[1];instance=[long]$p[2];phase=$p[3];
                speed100=[int]$p[4];desiredSpeed100=[int]$p[5];active=[int]$p[6];guard=[int]$p[7];confirmedSpeed100=[int]$p[8];
                measured=[double]::Parse($p[9],[Globalization.CultureInfo]::InvariantCulture);mismatch=[int]$p[10];shown=[int]$p[11];
                caption=(Decode-LauncherHex $p[12]);expectedCaption=(Decode-LauncherHex $p[13]);captionHex=$p[12];
                actions=[int]$p[14];direction=[int]$p[15];before=[int]$p[16];after=[int]$p[17];accepted=[int]$p[18];frames=[int]$p[19];
                rawT=[double]::Parse($p[20],[Globalization.CultureInfo]::InvariantCulture);chat=[int]$p[21];menu=[int]$p[22];locale=$p[23];kind=$p[24];
                wallUnix=[long]$p[25];measurementLower=[double]::Parse($p[26],[Globalization.CultureInfo]::InvariantCulture);
                measurementUpper=[double]::Parse($p[27],[Globalization.CultureInfo]::InvariantCulture);
                storeOptionAttempts=[int]$p[28];storeOptionPcallOk=[int]$p[29]}
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
        if($snapshot.statusAvailable){
            $observedAt=[AZSGRemoteGame]::Wall();$writeAt=0L
            try{$writeAt=(Get-Item -LiteralPath (Join-Path $GameRoot 'AZSSpeedGear-status.json') -ErrorAction Stop).LastWriteTimeUtc.ToFileTimeUtc()}catch{}
            $script:la.latestNative=[pscustomobject]@{fileTime=$observedAt;statusWriteFileTime=$writeAt;speed100=$snapshot.speed100;backend=$snapshot.backend;transport=$snapshot.transport;heartbeatAgeMs=$snapshot.heartbeatAgeMs}
            if($script:la.confirmationMode -and $null -ne $script:la.current -and $script:la.current.active -eq 1 -and $observedAt-$script:la.lastNativeSnapshot -ge 2500000L){
                $script:la.nativeSnapshots.Add($script:la.latestNative);$script:la.lastNativeSnapshot=$observedAt
            }
        }
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
    function Observe-Confirmation {
        $target=100
        if(-not [string]::IsNullOrWhiteSpace($env:AZSG_CONFIRMATION_SPEED100)){
            if($env:AZSG_CONFIRMATION_SPEED100 -cnotin @('50','100')){throw 'blocked_confirmation_speed'}
            $target=[int]$env:AZSG_CONFIRMATION_SPEED100
        }
        $targetRate=$target/100.0
        $firstPlaying=@($script:la.rows|Where-Object{$_.phase -ceq 'playing' -and $_.active -eq 1}|Select-Object -First 1)[0]
        $started=$firstPlaying.fileTime
        if($target -eq 50){
            $started=[AZSGRemoteGame]::Wall();Tap-Launcher 0x51
            Wait-Launcher 'physical_q_requested_half' {
                @($script:la.rows|Where-Object{$_.fileTime -ge $started -and $_.actions -eq 1 -and $_.direction -eq -1 -and $_.before -eq 100 -and $_.after -eq 50 -and $_.accepted -eq 1}).Count -gt 0
            }
        }
        $latencyLimit=if($target -eq 50){20}else{12}
        $firstConfirmed=$null;$lastHeld=$null;$drops=0;$cursor=0;$previousFrame=$null;$frameGaps=0
        $observed=[Collections.Generic.List[object]]::new();$completed=$false
        $deadline=$started+($latencyLimit+6)*10000000L
        $script:la.phase='confirmation'
        $script:la.confirmationMetrics=[ordered]@{requestedSpeed100=$target;startedFileTime=$started;firstConfirmationDelaySeconds=$null;continuousConfirmationSeconds=0;confirmationDrops=0;frameGaps=0;observedFrames=0}
        while([AZSGRemoteGame]::Wall() -lt $deadline){
            Drain-Launcher
            while($cursor -lt $script:la.rows.Count){
                $row=$script:la.rows[$cursor];$cursor++
                if($row.fileTime -lt $started){continue}
                if($row.phase -cne 'playing' -or $row.active -ne 1){throw 'blocked_ui_choice_interrupted'}
                $observed.Add($row)
                if($null -ne $previousFrame -and $row.frames -gt $previousFrame+1){$frameGaps++}
                $previousFrame=$row.frames
                $confirmed=$row.speed100 -eq $target -and $row.desiredSpeed100 -eq $target -and $row.confirmedSpeed100 -eq $target -and $row.kind -ceq 'confirmed' -and $row.shown -eq 1 -and $row.caption -ceq $row.expectedCaption
                if($confirmed){
                    if($null -eq $firstConfirmed){$firstConfirmed=$row}
                    $lastHeld=$row
                    if(($row.fileTime-$firstConfirmed.fileTime)/1e7 -ge 5){$completed=$true}
                }elseif($null -ne $firstConfirmed){$drops++}
                $script:la.confirmationMetrics.observedFrames=$observed.Count
                $script:la.confirmationMetrics.frameGaps=$frameGaps
                $script:la.confirmationMetrics.confirmationDrops=$drops
                if($null -ne $firstConfirmed){$script:la.confirmationMetrics.firstConfirmationDelaySeconds=($firstConfirmed.fileTime-$started)/1e7}
                if($null -ne $lastHeld){$script:la.confirmationMetrics.continuousConfirmationSeconds=($lastHeld.fileTime-$firstConfirmed.fileTime)/1e7}
                if($completed){break}
            }
            if($completed){break}
            $latest=$script:la.current
            if($latest.phase -cne 'playing' -or $latest.active -ne 1){throw 'blocked_ui_choice_interrupted'}
            # The game's first routine level-card modal occurs around 12.5 game
            # seconds. Stop before it can invalidate a stable, uninterrupted run.
            if($latest.rawT -ge 12.25){throw 'blocked_confirmation_observation_budget'}
            if($null -eq $firstConfirmed -and ([AZSGRemoteGame]::Wall()-$started)/1e7 -gt $latencyLimit){break}
            Start-Sleep -Milliseconds 50
        }
        $firstDelay=if($null -ne $firstConfirmed){($firstConfirmed.fileTime-$started)/1e7}else{$null}
        $heldFor=if($null -ne $firstConfirmed -and $null -ne $lastHeld){($lastHeld.fileTime-$firstConfirmed.fileTime)/1e7}else{0}
        $points=@($observed|Where-Object{$_.speed100 -eq $target -and $_.rawT -ge 0})
        $distinct=@($points|Select-Object -ExpandProperty rawT -Unique)
        $elapsed=0.0;$progress=0.0;$rate=$null
        if($points.Count -ge 2){$elapsed=($points[-1].fileTime-$points[0].fileTime)/1e7;$progress=$points[-1].rawT-$points[0].rawT;if($elapsed -gt 0){$rate=$progress/$elapsed}}
        # Latest monitoring bounds may widen while a recent valid proof is
        # retained. Check the first actual confirmation's contained interval;
        # continuous retention is independently checked against all UI frames.
        $firstBoundsOkay=$null -ne $firstConfirmed -and $firstConfirmed.measurementLower -ge $targetRate*0.90-0.00001 -and $firstConfirmed.measurementUpper -le $targetRate*1.10+0.00001 -and $firstConfirmed.measurementUpper -ge $firstConfirmed.measurementLower
        $freshNative=@($script:la.nativeSnapshots|Where-Object{$_.fileTime -ge $started -and $_.speed100 -eq $target -and $_.backend -ceq 'ready' -and $_.transport -cin @('console','file') -and $null -ne $_.heartbeatAgeMs -and $_.heartbeatAgeMs -le 2500 -and $_.statusWriteFileTime -gt 0 -and $_.fileTime-$_.statusWriteFileTime -ge -10000000L -and $_.fileTime-$_.statusWriteFileTime -le 25000000L})
        $script:la.confirmationMetrics=[pscustomobject]@{requestedSpeed100=$target;startedFileTime=$started;firstConfirmationDelaySeconds=$firstDelay;continuousConfirmationSeconds=$heldFor;confirmationDrops=$drops;frameGaps=$frameGaps;
            observedFrames=$observed.Count;distinctRawPoints=$distinct.Count;independentElapsedSeconds=$elapsed;rawProgressSeconds=$progress;independentRawRate=$rate;firstConfirmed=$firstConfirmed;lastConfirmed=$lastHeld}
        Assert-Launcher 'confirmation_latency' ($null -ne $firstConfirmed -and $firstDelay -le $latencyLimit) $script:la.confirmationMetrics
        Assert-Launcher 'confirmed_caption_held_five_seconds' ($completed -and $heldFor -ge 5 -and $drops -eq 0 -and $frameGaps -eq 0) $script:la.confirmationMetrics
        Assert-Launcher 'fresh_raw_progress_matches_independent_parent_time' ($distinct.Count -ge 3 -and $elapsed -ge 4 -and $null -ne $rate -and $rate -ge $targetRate*0.8 -and $rate -le $targetRate*1.2) $script:la.confirmationMetrics
        Assert-Launcher 'first_confirmation_interval_fits_target_tolerance' $firstBoundsOkay $firstConfirmed
        Assert-Launcher 'fresh_native_baseline_receipt' ($freshNative.Count -gt 0) $(if($freshNative.Count -gt 0){$freshNative[-1]}else{$null})
    }
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
        if($script:la.confirmationMode){
            Observe-Confirmation
        }else{
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
        }
        Assert-Launcher 'software_adapter_observed' $script:la.session.SoftwareObserved $script:la.session.SoftwareObserved
        Assert-Launcher 'no_dropped_telemetry' ($script:la.session.Dropped -eq 0) $script:la.session.Dropped
        $script:la.status='passed';$script:la.reason=if($script:la.confirmationMode){'actual_measurement_confirmation_held_with_fresh_independent_raw_progress'}else{'actual_launcher_text_keeps_numeric_speed_during_physical_switch'}
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
        confirmationMode=$script:la.confirmationMode;confirmationMetrics=$script:la.confirmationMetrics;nativeSnapshots=$script:la.nativeSnapshots.ToArray();
        exceptionType=$script:la.exceptionType;errorLine=$script:la.errorLine;scope=$script:la.scope}
}

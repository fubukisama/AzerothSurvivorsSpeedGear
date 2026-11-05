# Dot-sourced by the disposable remote launcher harness. No local invocation.
# Diagnostics describe actual observations, never a verdict that lag is fixed.
function Move-LagFixtureState([string]$GameRoot) {
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows'){throw 'blocked_remote_only'}
    Assert-LagInside ([IO.Path]::GetFullPath($GameRoot)) $script:fixtureRoot
    $index=0
    foreach($path in $script:knownGameStatePaths){
        if(Test-Path -LiteralPath $path){
            Assert-LagNoLinks $path
            $destination=[IO.Path]::GetFullPath((Join-Path $GameRoot ('PriorRunState-'+$index)))
            Assert-LagInside $destination $script:fixtureRoot
            if(Test-Path -LiteralPath $destination){throw 'blocked_lag_state_destination'}
            Move-Item -LiteralPath $path -Destination $destination
            $index++
        }
    }
}
function Read-LagRow($Row) {
    $match=[regex]::Match([string]$Row.Payload,'^(AZSGP1\|[A-Za-z0-9_.|_-]{1,1800})(?:[^A-Za-z0-9_.|_-]|$)')
    if(-not $match.Success){return $null}
    $parts=$match.Groups[1].Value.Split('|')
    if($parts.Count -ne 47){return $null}
    try {
        $names=@('seq','wallUnix','phase','frames','loaded','updates','widthCalls','fontCalls','spawns','misses',
            'activePeak','activeNow','hookedWidths','hookedFonts','unsupported','preexisting','requestedSizes',
            'actualSizes','sizeOverflow','worldChildren','worldShown','regions','worldCapped','totalFrames',
            'framesShown','enumCapped','observerReads','desiredSpeed100','speed100','guard','gcKB','gcThreshold',
            'clockMissing','updateHook','createHook','versionUnsupported','nativeMeterRows','nativeMeterTotal',
            'keijinPerformance','lightweightActive','diagnosticsEnabled','diagnosticFrameCount',
            'diagnosticEventCount','diagnosticFrozen','diagnosticGuardEvents','diagnosticNativeReceiptAvailable')
        $result=[ordered]@{fileTime=[long]$Row.FileTime}
        for($index=0;$index -lt $names.Count;$index++){
            if($names[$index] -eq 'phase'){
                if($parts[$index+1] -cnotmatch '^[a-z_]{1,24}$'){return $null}
                $result.phase=$parts[$index+1]
            }else{
                $value=[long]::Parse($parts[$index+1],[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture)
                if($value -lt -1 -or $value -gt 9007199254740991L){return $null}
                $result[$names[$index]]=$value
            }
        }
        if($result.seq -lt 1 -or $result.fileTime -le 0){return $null}
        return [pscustomobject]$result
    }catch{return $null}
}

function Get-LagFeatureSmoke([object[]]$Rows,[string]$Variant,[bool]$GuardObserved) {
    if($null -eq $Rows){$Rows=@()}
    $optimized=$Variant -ceq 'all_repaired'
    $apiMissing=@($Rows | Where-Object{$null -eq $_.diagnosticsEnabled -or $null -eq $_.diagnosticFrameCount -or $null -eq $_.diagnosticEventCount -or $null -eq $_.diagnosticFrozen -or $_.diagnosticsEnabled -lt 0 -or $_.diagnosticFrameCount -lt 0 -or $_.diagnosticEventCount -lt 0 -or $_.diagnosticFrozen -lt 0})
    $outOfBounds=@($Rows | Where-Object{$_.diagnosticFrameCount -gt 128 -or $_.diagnosticEventCount -gt 64 -or $_.diagnosticFrozen -notin @(0,1) -or $_.diagnosticsEnabled -notin @(0,1) -or $_.lightweightActive -notin @(0,1) -or $_.keijinPerformance -notin @(0,1,2) -or $_.diagnosticGuardEvents -lt -1 -or $_.diagnosticGuardEvents -gt 64})
    # -1 means no valid bounded Export snapshot has been observed. 0 means the
    # snapshot explicitly states false. 1 would incorrectly claim native data.
    $wrongDomain=@($Rows | Where-Object{$_.diagnosticNativeReceiptAvailable -notin @(-1,0) -or ($_.diagnosticGuardEvents -ge 0 -and $_.diagnosticNativeReceiptAvailable -ne 0)})
    $ready=@($Rows | Where-Object{$_.keijinPerformance -eq 2 -and $_.lightweightActive -eq 1 -and $_.diagnosticsEnabled -eq 1 -and $_.diagnosticFrameCount -gt 0 -and $_.diagnosticEventCount -gt 0})
    $guardReasons=@($Rows | Where-Object{$_.diagnosticGuardEvents -gt 0 -and $_.diagnosticNativeReceiptAvailable -eq 0})
    $notDefault=@($Rows | Where-Object{$_.keijinPerformance -ne 0 -or $_.lightweightActive -ne 0 -or $_.diagnosticsEnabled -ne 0 -or $_.diagnosticFrameCount -ne 0 -or $_.diagnosticEventCount -ne 0 -or $_.diagnosticFrozen -ne 0})
    $status='passed';$reason=if($optimized){'optimized_features_observed_not_a_performance_verdict'}else{'default_features_remain_off'}
    if($Variant -cnotin @('all_current','all_repaired','speedgear_only')){$status='blocked';$reason='blocked_lag_variant'}
    elseif($Rows.Count -eq 0){$status='blocked';$reason='blocked_lag_feature_samples'}
    elseif($apiMissing.Count -gt 0){$status='blocked';$reason='blocked_lag_feature_api'}
    elseif($outOfBounds.Count -gt 0){$status='failed';$reason='failed_lag_diagnostic_bounds'}
    elseif($wrongDomain.Count -gt 0){$status='failed';$reason='failed_lag_diagnostic_native_domain'}
    elseif($optimized -and $ready.Count -eq 0){$status='failed';$reason='failed_lag_optimized_features_missing'}
    elseif($optimized -and $GuardObserved -and $guardReasons.Count -eq 0){$status='failed';$reason='failed_lag_guard_reason_missing'}
    elseif(-not $optimized -and $notDefault.Count -gt 0){$status='failed';$reason='failed_lag_default_features_changed'}
    return [pscustomobject]@{
        schema=1;status=$status;reason=$reason;variant=$Variant;expectedOptimized=[bool]$optimized;
        rows=$Rows.Count;optimizedReadyRows=$ready.Count;guardObserved=$GuardObserved;
        guardReasonRows=$guardReasons.Count;apiMissingRows=$apiMissing.Count;
        outOfBoundsRows=$outOfBounds.Count;wrongNativeDomainRows=$wrongDomain.Count;
        unexpectedDefaultRows=$(if($optimized){0}else{$notDefault.Count});frameCapacity=128;eventCapacity=64;requiredOptimizedKeijinLevel=2;
        nativeReceiptFlagMeaning='-1: no valid Export snapshot observed; 0: snapshot explicitly states unavailable/false; 1: invalid native-receipt claim';
        scope='Feature integration smoke only. Counts and a frame_guard reason do not establish frame rate, movement equivalence, sustained acceleration or resolution of lag.'
    }
}

function Observe-Lag {
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows'){
        throw 'blocked_remote_only'
    }
    $started=[AZSGRemoteGame]::Wall()
    $deadline=$started+3600000000L
    $resources=[Collections.Generic.List[object]]::new()
    $first=$script:la.current
    $firstGame=if($null -ne $first){$first.rawT}else{$null}
    $lastGame=$firstGame
    $guardObserved=$null -ne $first -and $first.guard -eq 1
    $presses=0;$acknowledged=0;$reached=$false;$failure=$null;$featureFailure=$null
    $reason='wall_time_budget';$nextResource=$started
    $movement=@([uint16]0x57,[uint16]0x44,[uint16]0x53,[uint16]0x41)
    $moving=$null;$moveIndex=0;$nextMove=$started

    function Wait-LagAction([long]$PreviousActions){
        $until=[AZSGRemoteGame]::Wall()+50000000L
        do {
            Drain-Launcher
            $latest=$script:la.current
            if($null -ne $latest -and ($latest.guard -eq 1 -or $latest.phase -cne 'playing' -or $latest.actions -gt $PreviousActions)){return}
            Start-Sleep -Milliseconds 50
        }while([AZSGRemoteGame]::Wall() -lt $until)
    }

    try {
        Drain-Launcher
        if($env:AZSG_LAG_VARIANT -ceq 'all_repaired'){
            # Make the explicit feature setup observable before the unchanged
            # E,E sequence, so its first possible guard event is in the trace.
            $featureUntil=[AZSGRemoteGame]::Wall()+150000000L
            do {
                Drain-Launcher
                $ready=@($script:la.lagRows | Where-Object{$_.keijinPerformance -eq 2 -and $_.lightweightActive -eq 1 -and $_.diagnosticsEnabled -eq 1})
                if($ready.Count -gt 0){break}
                Start-Sleep -Milliseconds 50
            }while([AZSGRemoteGame]::Wall() -lt $featureUntil)
            if($ready.Count -eq 0){throw 'blocked_lag_optimized_setup_unobserved'}
        }
        # One ordinary physical E,E request sequence only. If the first request
        # already trips protection, the second press is skipped. Never reset or
        # retry acceleration after an observed guard event.
        for($step=0;$step -lt 2;$step++){
            $latest=$script:la.current
            if($null -eq $latest -or $latest.phase -cne 'playing' -or $latest.active -ne 1){break}
            if($latest.guard -eq 1){$guardObserved=$true;break}
            $expectedBefore=if($step -eq 0){100}else{200}
            if($latest.desiredSpeed100 -ne $expectedBefore){break}
            $beforeActions=$latest.actions
            Tap-Launcher 0x45;$presses++
            Wait-LagAction $beforeActions
            $latest=$script:la.current
            if($null -ne $latest -and $latest.actions -gt $beforeActions -and $latest.accepted -eq 1){$acknowledged++}
            if($null -ne $latest -and $latest.guard -eq 1){$guardObserved=$true;break}
        }
        while([AZSGRemoteGame]::Wall() -lt $deadline){
            Drain-Launcher
            $now=[AZSGRemoteGame]::Wall();$latest=$script:la.current
            if($null -eq $latest){Start-Sleep -Milliseconds 50;continue}
            if($latest.guard -eq 1){$guardObserved=$true}
            if($latest.rawT -ge 0){$lastGame=$latest.rawT}
            if($now -ge $nextResource -and $resources.Count -lt 370){
                $process=$script:la.session.Child;$process.Refresh()
                $native=$script:la.latestNative
                $fresh=$null -ne $native -and $native.backend -ceq 'ready' -and
                    $native.transport -cin @('console','file') -and $null -ne $native.heartbeatAgeMs -and
                    $native.heartbeatAgeMs -le 2500 -and $native.statusWriteFileTime -gt 0 -and
                    $now-$native.statusWriteFileTime -ge -10000000L -and $now-$native.statusWriteFileTime -le 25000000L
                $resources.Add([pscustomobject]@{
                    fileTime=$now;elapsedWallSeconds=($now-$started)/1e7;
                    processCpuMilliseconds=$process.TotalProcessorTime.TotalMilliseconds;
                    privateBytes=[long]$process.PrivateMemorySize64;workingSetBytes=[long]$process.WorkingSet64;
                    gameTime=$latest.rawT;frames=$latest.frames;phase=$latest.phase;
                    desiredSpeed100=$latest.desiredSpeed100;requestedSpeed100=$latest.speed100;guard=$latest.guard;
                    nativeSpeed100=$(if($null -ne $native){$native.speed100}else{$null});nativeReceiptFresh=[bool]$fresh
                })
                $nextResource=$now+10000000L
            }
            if($latest.rawT -ge 300){$reached=$true;$reason='five_minute_game_time_reached';break}
            if($latest.phase -cne 'playing' -or $latest.active -ne 1){$reason='combat_phase_ended';break}
            if($latest.chat -eq 1 -or $latest.menu -eq 1){$reason='ui_input_blocked';break}
            if($now -ge $nextMove){
                if($null -ne $moving){Key-Launcher $moving $false}
                $moving=$movement[$moveIndex % $movement.Count]
                Key-Launcher $moving $true
                $moveIndex++;$nextMove=$now+40000000L
            }
            Start-Sleep -Milliseconds 50
        }
    }catch{
        $failure=$_
        $message=[string]$_.Exception.Message
        $reason=if($message -cmatch '^blocked_[a-z_]{1,100}$'){$message}else{'blocked_lag_observer_environment'}
    }finally{
        foreach($key in $movement){
            try{if($script:la.held.ContainsKey([int]$key) -and $script:la.held[[int]$key]){Key-Launcher $key $false}}catch{}
        }
        Drain-Launcher
        $ended=[AZSGRemoteGame]::Wall()
        $lag=@($script:la.lagRows | Where-Object{$_.fileTime -ge $started -and $_.fileTime -le $ended})
        $regular=@($script:la.rows | Where-Object{$_.fileTime -ge $started -and $_.fileTime -le $ended})
        if(@($regular | Where-Object guard -eq 1).Count -gt 0){$guardObserved=$true}
        $activeLag=@($lag | Where-Object{$_.activeNow -gt 0})
        $fullyWrapped=@($activeLag | Where-Object{$_.loaded -eq 1 -and $_.updateHook -eq 1 -and $_.hookedWidths -gt 0 -and $_.hookedFonts -gt 0 -and $_.unsupported -eq 0 -and $_.versionUnsupported -eq 0})
        $enough=$resources.Count -ge 15 -and $lag.Count -ge 15
        $firstCommon=$null;$lastCommon=$null
        if($lag.Count -gt 0 -and $resources.Count -gt 0){
            $firstCommon=[Math]::Max([long]$lag[0].fileTime,[long]$resources[0].fileTime)
            $lastCommon=[Math]::Min([long]$lag[-1].fileTime,[long]$resources[$resources.Count-1].fileTime)
        }
        $coverage=[ordered]@{
            sufficientNumericalSamples=[bool]$enough;lagSamples=$lag.Count;processSamples=$resources.Count;
            activeDamageSamples=$activeLag.Count;fullyWrappedActiveSamples=$fullyWrapped.Count;
            firstCommonFileTime=$firstCommon;lastCommonFileTime=$lastCommon;
            observedThreeTimesRequested=(@($regular | Where-Object{$_.speed100 -eq 300 -and $_.desiredSpeed100 -eq 300}).Count -gt 0);
            freshNativeThreeTimesSamples=@($resources | Where-Object{$_.nativeReceiptFresh -and $_.nativeSpeed100 -eq 300}).Count;
            missingClockSamples=@($lag | Where-Object clockMissing -ne 0).Count;
            unsupportedMethodSamples=@($lag | Where-Object{$_.unsupported -gt 0 -or $_.versionUnsupported -gt 0 -or $_.updateHook -ne 1}).Count;
            cappedFrameWalkSamples=@($lag | Where-Object{$_.enumCapped -ne 0 -or $_.worldCapped -ne 0}).Count
        }
        $featureSmoke=Get-LagFeatureSmoke -Rows $lag -Variant $env:AZSG_LAG_VARIANT -GuardObserved ([bool]$guardObserved)
        if($featureSmoke.status -cne 'passed'){$featureFailure=$featureSmoke.reason}
        $script:la.lagMetrics=[pscustomobject]@{
            schema=1;status=$(if($null -eq $failure -and $null -eq $featureFailure -and $enough){'observed'}else{'partial'});
            reason=$reason;observationOnly=$true;startedFileTime=$started;endedFileTime=$ended;
            elapsedWallSeconds=($ended-$started)/1e7;firstGameTime=$firstGame;lastGameTime=$lastGame;
            reachedFiveMinuteGameTime=[bool]$reached;guardObserved=[bool]$guardObserved;
            accelerationPresses=$presses;acknowledgedAccelerationActions=$acknowledged;
            lagRows=$lag;processSamples=$resources.ToArray();overlapCoverage=[pscustomobject]$coverage;
            featureSmoke=$featureSmoke;
            scope='Actual client observations with independent parent wall/CPU/memory sampling. Reaching five game minutes, a protection event or sufficient samples is not a performance pass or proof that lag is fixed. Native method wrapping and full-walk availability remain explicit.'
        }
    }
    if($null -ne $failure){throw $failure}
    if($null -ne $featureFailure){throw $featureFailure}
    return $script:la.lagMetrics
}

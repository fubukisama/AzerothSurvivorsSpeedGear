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
    if($parts.Count -ne 39){return $null}
    try {
        $names=@('seq','wallUnix','phase','frames','loaded','updates','widthCalls','fontCalls','spawns','misses',
            'activePeak','activeNow','hookedWidths','hookedFonts','unsupported','preexisting','requestedSizes',
            'actualSizes','sizeOverflow','worldChildren','worldShown','regions','worldCapped','totalFrames',
            'framesShown','enumCapped','observerReads','desiredSpeed100','speed100','guard','gcKB','gcThreshold',
            'clockMissing','updateHook','createHook','versionUnsupported','nativeMeterRows','nativeMeterTotal')
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
    $presses=0;$acknowledged=0;$reached=$false;$failure=$null
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
        $script:la.lagMetrics=[pscustomobject]@{
            schema=1;status=$(if($null -eq $failure -and $enough){'observed'}else{'partial'});
            reason=$reason;observationOnly=$true;startedFileTime=$started;endedFileTime=$ended;
            elapsedWallSeconds=($ended-$started)/1e7;firstGameTime=$firstGame;lastGameTime=$lastGame;
            reachedFiveMinuteGameTime=[bool]$reached;guardObserved=[bool]$guardObserved;
            accelerationPresses=$presses;acknowledgedAccelerationActions=$acknowledged;
            lagRows=$lag;processSamples=$resources.ToArray();overlapCoverage=[pscustomobject]$coverage;
            scope='Actual client observations with independent parent wall/CPU/memory sampling. Reaching five game minutes, a protection event or sufficient samples is not a performance pass or proof that lag is fixed. Native method wrapping and full-walk availability remain explicit.'
        }
    }
    if($null -ne $failure){throw $failure}
    return $script:la.lagMetrics
}

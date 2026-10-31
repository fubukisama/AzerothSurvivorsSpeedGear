# Dot-sourced only by the remote-only real-game runner after verified provisioning.
# Never shipped in the release package. All input below uses the actual OS queue.
function Invoke-HotkeyAcceptance([string]$GameRoot, [string]$Assets, [string]$OfficialExe) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') { throw 'blocked_remote_only' }
    $script:hk = [ordered]@{ schema=1; status='blocked'; reason='not_started'; phase='provision'; criteria=@(); sessions=@();
        current=$null; session=$null; rows=$null; native=$null; nativeLog=$null; nativeLogSeen=$null; input=$null; exceptionType=$null; errorLine=$null;
        choiceHeld=$false; choiceStart=0L; choiceFrame=0; choiceLast=0L; choiceAttempts=0;
        scope='Physical SendInput into one official game build. Native acknowledgements prove delivery, not uniform movement or skill timing.' }
    $mouseSource = @'
using System;
using System.Runtime.InteropServices;
public static class AZSGHotkeyMouse {
  [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
  [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort Vk,Scan; public uint Flags,Time; public UIntPtr Extra; }
  [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Mouse Mouse; [FieldOffset(0)] public Keyboard Keyboard; }
  [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public Union Value; }
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window,ref Point point);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern uint SendInput(uint count,Input[] input,int size);
  public static bool MoveClient(IntPtr window,int x,int y) {
    var point=new Point {X=x,Y=y};
    return ClientToScreen(window,ref point) && SetCursorPos(point.X,point.Y);
  }
  public static bool Click(IntPtr window,int x,int y,bool down) {
    if(!MoveClient(window,x,y)) return false;
    var input=new Input {Type=0}; input.Value.Mouse.Flags=down?2u:4u;
    return SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))==1;
  }
}
'@
    function Read-HotkeyRow($Row) {
        $match = [regex]::Match($Row.Payload, '^(AZSGH1\|[A-Za-z0-9_.|_-]{1,1800})(?:[^A-Za-z0-9_.|_-]|$)')
        if (-not $match.Success) { return $null }
        $p = $match.Groups[1].Value.Split('|')
        if ($p.Count -ne 41) { return $null }
        try {
            $r = [ordered]@{ fileTime=[long]$Row.FileTime; seq=[long]$p[1]; instance=[long]$p[2]; phase=$p[3]; desired=[int]$p[4]; speed=[int]$p[5]; guard=[int]$p[6]; active=[int]$p[7]; down=$p[8]; up=$p[9]; q=$p[10]; e=$p[11]; r=$p[12]; ctrlT=$p[13]; capture=[int]$p[14]; panel=[int]$p[15]; actions=[int]$p[16]; direction=[int]$p[17]; before=[int]$p[18]; after=[int]$p[19]; accepted=[int]$p[20]; frames=[int]$p[21]; rawT=[double]::Parse($p[22],[Globalization.CultureInfo]::InvariantCulture); chat=[int]$p[23]; menu=[int]$p[24] }
            $names = @('launcher','downButton','upButton','closeButton','stopButton')
            for ($i=0; $i -lt 5; $i++) { $r[$names[$i]] = @([double]::Parse($p[25+$i*2],[Globalization.CultureInfo]::InvariantCulture), [double]::Parse($p[26+$i*2],[Globalization.CultureInfo]::InvariantCulture)) }
            $r.captureKey=$p[35]; $r.captureCtrl=$p[36]; $r.captureShift=$p[37]; $r.captureAlt=$p[38]; $r.currentCtrl=$p[39]; $r.captureEvents=[int]$p[40]
            return [pscustomobject]$r
        } catch { return $null }
    }
    function Drain-Hotkey {
        $row = $null
        while ($script:hk.session.Rows.TryDequeue([ref]$row)) {
            $parsed = Read-HotkeyRow $row
            if ($null -ne $parsed -and $script:hk.rows.Count -lt 2500) { $script:hk.rows.Add($parsed); $script:hk.current = $parsed }
            $row=$null
        }
        $snapshot=Read-NativeBackendEvidence $GameRoot
        if ($snapshot.statusAvailable -and ($script:hk.native.Count -eq 0 -or $script:hk.native[$script:hk.native.Count-1].speed100 -ne $snapshot.speed100)) {
            $script:hk.native.Add([pscustomobject]@{fileTime=[AZSGRemoteGame]::Wall(); speed100=$snapshot.speed100; backend=$snapshot.backend; transport=$snapshot.transport})
        }
        foreach ($line in $snapshot.safeLog) {
            $change=[regex]::Match($line,'^speed100=([0-9]{1,4}) simulation_calls=([0-9]{1,20})$')
            if ($change.Success -and $script:hk.nativeLogSeen.Add([string]$line)) {
                # Exact normalized text includes the monotonic simulation-call
                # count. Existing lines are observed by the pre-action drain;
                # only a previously unseen change can acknowledge a new input.
                $script:hk.nativeLog.Add([pscustomobject]@{fileTime=[AZSGRemoteGame]::Wall(); speed100=[int]$change.Groups[1].Value; simulationCalls=[ulong]$change.Groups[2].Value; backend=$snapshot.backend; message=[string]$line})
            }
        }
        if ($script:hk.session.Child.HasExited) { throw 'blocked_game_exited' }
        # Resolve the game's own level-choice modal with real number-key input.
        # Never send a choice key while the plugin is recording a binding. Keep
        # the state machine here nonrecursive: no Tap/Pause/Drain helper calls.
        $now=[AZSGRemoteGame]::Wall(); $latest=$script:hk.current
        if ($null -ne $latest) {
            if ($script:hk.choiceHeld) {
                $timedOut=($now-$script:hk.choiceStart)/1e7 -ge 6
                if ($latest.phase -cne 'choosing' -or $latest.capture -ne 0 -or $latest.frames -ge $script:hk.choiceFrame+2 -or $timedOut) {
                    Key-Hotkey 0x31 $false
                    $script:hk.choiceHeld=$false; $script:hk.choiceLast=$now
                    if ($latest.phase -ceq 'choosing' -and $script:hk.choiceAttempts -ge 3) { throw 'blocked_level_choice_input' }
                }
            } elseif ($latest.phase -ceq 'choosing' -and $latest.capture -eq 0 -and ($now-$script:hk.choiceLast)/1e7 -ge 1) {
                $script:hk.choiceAttempts++; $script:hk.choiceStart=$now; $script:hk.choiceFrame=$latest.frames
                Key-Hotkey 0x31 $true
                $script:hk.choiceHeld=$true
            } elseif ($latest.phase -cne 'choosing') {
                $script:hk.choiceAttempts=0
            }
        }
    }
    function Assert-Hotkey([string]$Name,[bool]$Okay,$Observed) {
        $script:hk.criteria += [pscustomobject]@{name=$Name; passed=$Okay; observed=$Observed}
        if (-not $Okay) { throw ('failed_' + $Name) }
    }
    function Wait-Hotkey([string]$Name,[scriptblock]$Condition,[int]$Seconds=12,[scriptblock]$Evidence=$null) {
        $until=[AZSGRemoteGame]::Wall()+$Seconds*10000000L
        do {
            Drain-Hotkey
            if ($null -ne $script:hk.current -and (& $Condition)) {
                $observed=if ($null -ne $Evidence) { & $Evidence } else { $script:hk.current }
                Assert-Hotkey $Name $true $observed; return
            }
            Start-Sleep -Milliseconds 50
        } while ([AZSGRemoteGame]::Wall() -lt $until)
        if ($null -ne $script:hk.current -and $script:hk.current.phase -ceq 'choosing') { throw 'blocked_level_choice_modal' }
        Assert-Hotkey $Name $false $script:hk.current
    }
    function Key-Hotkey([uint16]$Key,[bool]$Down) {
        $okay=$script:hk.session.Key($Key,$Down)
        $script:hk.input.Add([pscustomobject]@{fileTime=[AZSGRemoteGame]::Wall(); kind='keyboard'; vk=$Key; down=$Down; sent=$okay})
        if (-not $okay) { throw 'blocked_input_or_foreground' }
    }
    function Pause-Hotkey([int]$Milliseconds) {
        # Keep the unhooked native observer running while physical keys/buttons
        # are held. A legitimate low-frame-rate reset may make 2x short-lived.
        $until=[AZSGRemoteGame]::Wall()+$Milliseconds*10000L
        do { Drain-Hotkey; Start-Sleep -Milliseconds 50 } while ([AZSGRemoteGame]::Wall() -lt $until)
        Drain-Hotkey
    }
    function Tap-Hotkey([uint16]$Key,[uint16]$Modifier=0) {
        if ($Modifier -ne 0) { Key-Hotkey $Modifier $true; Pause-Hotkey 650 }
        Key-Hotkey $Key $true
        Pause-Hotkey 450
        Key-Hotkey $Key $false
        if ($Modifier -ne 0) { Pause-Hotkey 450; Key-Hotkey $Modifier $false }
    }
    function Click-Hotkey([string]$Name) {
        Wait-Hotkey ('ui_'+$Name+'_playing') { $script:hk.current.phase -ceq 'playing' -and $script:hk.current.active -eq 1 -and -not $script:hk.choiceHeld }
        $point=$script:hk.current.$Name; $size=$script:hk.session.ClientSize()
        if ($null -eq $size -or $null -eq $point -or $point.Count -ne 2 -or $point[0] -le 0 -or $point[0] -ge 1 -or $point[1] -le 0 -or $point[1] -ge 1 -or -not $script:hk.session.Focus()) { throw 'blocked_button_coordinates' }
        $x=[int][Math]::Round($point[0]*$size[0]); $y=[int][Math]::Round($point[1]*$size[1])
        $window=$script:hk.session.Child.MainWindowHandle
        $hoverStarted=[AZSGRemoteGame]::Wall(); $hoverFrame=$script:hk.current.frames; $hoverObserved=$false
        $moved=[AZSGHotkeyMouse]::MoveClient($window,$x,$y)
        $script:hk.input.Add([pscustomobject]@{fileTime=$hoverStarted; kind='mouse_move'; button=$Name; x=$x; y=$y; sent=$moved})
        if (-not $moved) { throw 'blocked_input_or_foreground' }
        while (([AZSGRemoteGame]::Wall()-$hoverStarted)/1e7 -lt 6) {
            Drain-Hotkey
            if ($script:hk.current.frames -gt $hoverFrame) { $hoverObserved=$true; break }
            Start-Sleep -Milliseconds 50
        }
        if (-not $hoverObserved) { throw 'blocked_mouse_hover_cadence' }
        $started=[AZSGRemoteGame]::Wall(); $firstFrame=$script:hk.current.frames; $frameObserved=$false
        $okay=[AZSGHotkeyMouse]::Click($window,$x,$y,$true)
        try {
            # Mouse hit-testing needs the down state to survive rendered frames.
            # A 450ms click can fall entirely inside one software-rendered frame.
            # Keep OS input held through two observed client updates, bounded by
            # six seconds; this never invokes the panel's callback directly.
            while (([AZSGRemoteGame]::Wall()-$started)/1e7 -lt 6) {
                Drain-Hotkey
                if ($script:hk.current.frames -ge $firstFrame+2) { $frameObserved=$true; break }
                Start-Sleep -Milliseconds 50
            }
        } finally {
            $okay=[AZSGHotkeyMouse]::Click($window,$x,$y,$false) -and $okay
            $finished=[AZSGRemoteGame]::Wall()
            $script:hk.input.Add([pscustomobject]@{fileTime=$finished; kind='mouse'; button=$Name; x=$x; y=$y; sent=$okay; downFileTime=$started; holdMilliseconds=($finished-$started)/10000.0; firstFrame=$firstFrame; releaseFrame=$script:hk.current.frames})
        }
        if (-not $okay) { throw 'blocked_input_or_foreground' }
        if (-not $frameObserved) { throw 'blocked_mouse_frame_cadence' }
    }
    function Open-HotkeyCapture([string]$Button,[string]$Criterion) {
        Click-Hotkey $Button
        $until=[AZSGRemoteGame]::Wall()+50000000L
        do {
            Drain-Hotkey
            if ($script:hk.current.capture -eq 1) { Assert-Hotkey $Criterion $true $script:hk.current; return }
            Start-Sleep -Milliseconds 50
        } while ([AZSGRemoteGame]::Wall() -lt $until)
        # One bounded physical retry tolerates a slow hit-test/update boundary;
        # the acceptance condition remains the real recorder becoming active.
        Click-Hotkey $Button
        Wait-Hotkey $Criterion { $script:hk.current.capture -eq 1 }
    }
    function Step-Hotkey([string]$Name,[uint16]$Key,[int]$Expected,[int]$Direction,[uint16]$Modifier=0) {
        Wait-Hotkey ($Name+'_playing') { $script:hk.current.phase -ceq 'playing' -and $script:hk.current.active -eq 1 -and -not $script:hk.choiceHeld }
        $script:hk.previousActions=$script:hk.current.actions
        $script:hk.actionStarted=[AZSGRemoteGame]::Wall()
        Tap-Hotkey $Key $Modifier
        Wait-Hotkey ($Name+'_dispatch') { $script:hk.current.actions -eq $script:hk.previousActions+1 -and $script:hk.current.direction -eq $Direction -and $script:hk.current.after -eq $Expected -and $script:hk.current.accepted -eq 1 }
        $script:hk.nativeAckEvidence=$null
        Wait-Hotkey ($Name+'_native') {
            $status=@($script:hk.native | Where-Object { $_.fileTime -ge $script:hk.actionStarted -and $_.speed100 -eq $Expected -and $_.backend -ceq 'ready' })
            if ($status.Count -gt 0) {
                $script:hk.nativeAckEvidence=[pscustomobject]@{source='status'; actionStarted=$script:hk.actionStarted; observation=$status[-1]}
                return $true
            }
            # The 1s diagnostic publisher may skip a short 2x interval before
            # the real low-frame-rate guard restores 1x. A fresh native change
            # log proves that transition; stable 0.5x/1x still require status.
            if ($Expected -eq 200) {
                $changes=@($script:hk.nativeLog | Where-Object { $_.fileTime -ge $script:hk.actionStarted -and $_.speed100 -eq 200 -and $_.backend -ceq 'ready' })
                if ($changes.Count -gt 0) {
                    $script:hk.nativeAckEvidence=[pscustomobject]@{source='change_log'; actionStarted=$script:hk.actionStarted; observation=$changes[-1]}
                    return $true
                }
            }
            return $false
        } 12 { $script:hk.nativeAckEvidence }
    }
    function Unused-Hotkey([string]$Name,[uint16]$Key) {
        Drain-Hotkey; $count=$script:hk.current.actions; $frame=$script:hk.current.frames
        Tap-Hotkey $Key
        Wait-Hotkey ($Name+'_frames') { $script:hk.current.frames -ge $frame+3 }
        Assert-Hotkey $Name ($script:hk.current.actions -eq $count) $script:hk.current
    }
    function Start-HotkeySession([int]$Number) {
        $script:hk.current=$null; $script:hk.rows=[Collections.Generic.List[object]]::new(); $script:hk.native=[Collections.Generic.List[object]]::new(); $script:hk.input=[Collections.Generic.List[object]]::new()
        $script:hk.nativeLog=[Collections.Generic.List[object]]::new(); $script:hk.nativeLogSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $script:hk.choiceHeld=$false; $script:hk.choiceStart=0L; $script:hk.choiceFrame=0; $script:hk.choiceLast=0L; $script:hk.choiceAttempts=0
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $GameRoot 'AzerothSurvivors.exe'))
        $info.WorkingDirectory=$GameRoot; $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        foreach ($credential in @('AZSG_GAME_BUNDLE_URL','GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN')) { [void]$info.Environment.Remove($credential) }
        $info.Environment['WGPU_BACKEND']='dx12'; $info.Environment['WGPU_FORCE_FALLBACK_ADAPTER']='1'; $info.Environment['WGPU_ADAPTER_NAME']='Microsoft Basic Render Driver'
        $info.Environment['RUST_LOG']='info,wgpu_core=warn,wgpu_hal=warn,naga=warn'; $info.Environment['WOW_WIN']=$script:viewport; $info.Environment['BENILLA_HOME']=(Join-Path $GameRoot 'benilla-config')
        $appData=Join-Path $GameRoot 'AppData'; New-Item -ItemType Directory -Path $appData -Force | Out-Null
        $info.Environment['APPDATA']=$appData; $info.Environment['LOCALAPPDATA']=$appData
        $script:hk.session=[AZSGRemoteGame]::new(); $script:hk.session.Start($info)
        $start=[AZSGRemoteGame]::Wall(); $lastInput=0L; $held=$false; $heldUntil=0L; $lastEscape=-1L
        while (([AZSGRemoteGame]::Wall()-$start)/1e7 -lt $script:startupSeconds) {
            Drain-Hotkey; $now=[AZSGRemoteGame]::Wall(); $latest=$script:hk.current
            if ($null -ne $latest -and $latest.phase -ceq 'playing' -and $latest.active -eq 1 -and -not $script:hk.choiceHeld) { if ($held) { Key-Hotkey 0x57 $false }; Assert-Hotkey ('session'+$Number+'_playing') $true $latest; return }
            if ($held -and $now -ge $heldUntil) { Key-Hotkey 0x57 $false; $held=$false }
            if (($now-$lastInput)/1e7 -ge 5 -and -not $script:hk.session.LoadingCoverWaiting -and -not $held) {
                $lastInput=$now
                if ($null -ne $latest -and ($latest.chat -eq 1 -or $latest.menu -eq 1)) { if ($latest.seq -gt $lastEscape) { Tap-Hotkey 0x1b; $lastEscape=$latest.seq } }
                elseif ($null -ne $latest -and $latest.phase -ceq 'ready') { Key-Hotkey 0x57 $true; $held=$true; $heldUntil=$now+40000000L }
                elseif ($null -eq $latest -and $script:hk.session.Focus()) { Tap-Hotkey 0x0d }
            }
            Start-Sleep -Milliseconds 50
        }
        throw 'blocked_no_playing'
    }
    function Save-HotkeySession([int]$Number,[bool]$Graceful) {
        if ($null -eq $script:hk.session) { return }
        if ($script:hk.choiceHeld -and -not $script:hk.session.Child.HasExited) { Key-Hotkey 0x31 $false; $script:hk.choiceHeld=$false }
        $game=$script:hk.session.Child; $clean=$false
        if ($Graceful -and -not $game.HasExited) { [void]$game.CloseMainWindow(); $clean=$game.WaitForExit(30000) }
        $script:hk.sessions += [pscustomobject]@{number=$Number; gracefulExit=$clean; softwareAdapterObserved=$script:hk.session.SoftwareObserved; panicked=$script:hk.session.Panicked; gpuFailure=$script:hk.session.GpuFailure; startupCategories=@($script:hk.session.StartupCategories); droppedTelemetry=$script:hk.session.Dropped; loadingClearObserved=$script:hk.session.LoadingClearObserved; inputs=$script:hk.input.ToArray(); samples=$script:hk.rows.ToArray(); nativeTransitions=$script:hk.native.ToArray(); nativeLogEvents=$script:hk.nativeLog.ToArray()}
        $script:hk.session.Dispose(); $script:hk.session=$null
        if ($Graceful) { Assert-Hotkey ('session'+$Number+'_graceful_exit') $clean $clean }
    }
    function Capture-Hotkey([int]$Number) {
        if ($env:AZSG_CAPTURE_FRAME -cne '1') { return }
        $process=$null
        try {
            $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            foreach ($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'remote_game_screenshot.ps1'),'-GameProcessId',[string]$script:hk.session.Child.Id,'-OutputPath',(Join-Path $script:projectRoot ('acceptance\hotkeys-'+$Number+'.png')))) { $info.ArgumentList.Add($argument) }
            $process=[Diagnostics.Process]::Start($info); $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(20000)) { $process.Kill(); [void]$process.WaitForExit(1000) }
        } catch { } finally { if ($null -ne $process) { $process.Dispose() } }
    }
    try {
        Add-Type -TypeDefinition $mouseSource
        New-Item -ItemType Directory -Path $GameRoot -Force | Out-Null
        $data=Join-Path $GameRoot 'Data'; New-Item -ItemType Directory -Path $data -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $Assets -File)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $data $file.Name) }
        Copy-Item -LiteralPath $OfficialExe -Destination (Join-Path $GameRoot 'AzerothSurvivors.exe')
        foreach ($runtimeFile in $script:runtimeDllSources) { Copy-Item -LiteralPath $runtimeFile.path -Destination (Join-Path $GameRoot $runtimeFile.name) }
        $state=Join-Path $GameRoot 'benilla-config'; $addon=Join-Path $state 'AddOns\AZSSpeedGear'; New-Item -ItemType Directory -Path $addon -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:package 'AddOns\AZSSpeedGear') -File)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $addon $file.Name) }
        Copy-Item -LiteralPath (Join-Path $script:package 'Native\dwmapi.dll') -Destination (Join-Path $GameRoot 'dwmapi.dll')
        $observer=Join-Path $state 'AddOns\AZSGHotkeyTest'; New-Item -ItemType Directory -Path $observer -Force | Out-Null
        Write-Text (Join-Path $observer 'AZSGHotkeyTest.toc') "## Interface: 11200`n## Title: AZSG remote hotkey test`n## Dependencies: AZSSpeedGear`nTelemetry.lua`n"
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'remote_hotkey_telemetry.lua') -Destination (Join-Path $observer 'Telemetry.lua')
        Write-Text (Join-Path $state 'config.toml') "[cvars]`ngxWindow = `"1`"`ngxResolution = `"$script:viewport`"`ngxVSync = `"0`"`nfarclip = `"177`"`nshadowLevel = `"0`"`n"
        $script:hk.phase='default_keys'; Start-HotkeySession 1
        Assert-Hotkey 'default_qe_bindings' ($script:hk.current.down -ceq 'Q' -and $script:hk.current.up -ceq 'E' -and $script:hk.current.q -ceq 'AZSG_SLOWER' -and $script:hk.current.e -ceq 'AZSG_FASTER') $script:hk.current
        Step-Hotkey 'q_slower' 0x51 50 -1
        Step-Hotkey 'e_faster' 0x45 100 1
        Step-Hotkey 'e_accelerated' 0x45 200 1
        $script:hk.phase='panel_rebind'
        Click-Hotkey 'launcher'; Wait-Hotkey 'panel_opened' { $script:hk.current.panel -eq 1 }
        Click-Hotkey 'stopButton'; Wait-Hotkey 'panel_stop' { $script:hk.current.phase -ceq 'playing' -and $script:hk.current.active -eq 1 -and $script:hk.current.desired -eq 100 -and $script:hk.current.speed -eq 100 -and $script:hk.current.guard -eq 0 }
        Open-HotkeyCapture 'downButton' 'record_down_opened'
        Tap-Hotkey 0x52; Wait-Hotkey 'record_down_r' { $script:hk.current.down -ceq 'R' -and $script:hk.current.capture -eq 0 -and $script:hk.current.r -ceq 'AZSG_SLOWER' }
        Open-HotkeyCapture 'upButton' 'record_up_opened'
        Tap-Hotkey 0x54 0x11; Wait-Hotkey 'record_up_ctrl_t' { $script:hk.current.up -ceq 'CTRL-T' -and $script:hk.current.capture -eq 0 -and $script:hk.current.ctrlT -ceq 'AZSG_FASTER' }
        Capture-Hotkey 1
        Click-Hotkey 'closeButton'; Wait-Hotkey 'panel_hidden' { $script:hk.current.panel -eq 0 }
        Unused-Hotkey 'old_q_released' 0x51; Unused-Hotkey 'old_e_released' 0x45
        Step-Hotkey 'r_slower' 0x52 50 -1; Step-Hotkey 'ctrl_t_faster' 0x54 100 1 0x11
        $script:hk.phase='persist_restart'; Save-HotkeySession 1 $true
        # Declared AddOn SavedVariables use the per-addon account file. The
        # separate flat saved-variables.lua belongs to FrameXML state.
        $savedPath=Join-Path $state 'saved\AZSSpeedGear.lua'
        $saved=if (Test-Path -LiteralPath $savedPath -PathType Leaf) { [IO.File]::ReadAllText($savedPath) } else { '' }
        Assert-Hotkey 'saved_custom_keys' ($saved -match 'hotkeyDown[^\r\n]{0,30}"R"' -and $saved -match 'hotkeyUp[^\r\n]{0,30}"CTRL-T"') $true
        $script:hk.phase='restart_custom_keys'; Start-HotkeySession 2
        Assert-Hotkey 'reloaded_custom_bindings' ($script:hk.current.down -ceq 'R' -and $script:hk.current.up -ceq 'CTRL-T' -and $script:hk.current.r -ceq 'AZSG_SLOWER' -and $script:hk.current.ctrlT -ceq 'AZSG_FASTER') $script:hk.current
        Step-Hotkey 'reloaded_r_slower' 0x52 50 -1; Step-Hotkey 'reloaded_ctrl_t_faster' 0x54 100 1 0x11
        Click-Hotkey 'launcher'; Wait-Hotkey 'reloaded_panel_opened' { $script:hk.current.panel -eq 1 }; Capture-Hotkey 2
        Save-HotkeySession 2 $true
        $script:hk.status='passed'; $script:hk.reason='physical_default_and_rebound_keys_native_delivery_and_restart_persistence_observed'
    } catch {
        $message=[string]$_.Exception.Message
        $script:hk.status=if ($message -cmatch '^failed_[a-z0-9_]+$') { 'failed' } else { 'blocked' }
        $script:hk.reason=if ($message -cmatch '^(failed|blocked)_[a-z0-9_]{1,100}$') { $message } else { 'blocked_hotkey_harness_or_environment' }
        $script:hk.exceptionType=$_.Exception.GetType().FullName; $script:hk.errorLine=$_.InvocationInfo.ScriptLineNumber
    } finally {
        if ($null -ne $script:hk.session) { Save-HotkeySession ($script:hk.sessions.Count+1) $false }
        foreach ($path in $script:knownGameStatePaths) {
            if (Test-Path -LiteralPath $path) {
                if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'blocked_runner_state_link' }
                $destination=Join-Path $GameRoot ('KnownFolderState-'+[guid]::NewGuid().ToString('N'))
                if (-not ([IO.Path]::GetFullPath($destination)).StartsWith($script:fixtureRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'blocked_runner_state_path' }
                Move-Item -LiteralPath $path -Destination $destination
            }
        }
    }
    return [pscustomobject]@{schema=$script:hk.schema; status=$script:hk.status; reason=$script:hk.reason; phase=$script:hk.phase; criteria=$script:hk.criteria; sessions=$script:hk.sessions; exceptionType=$script:hk.exceptionType; errorLine=$script:hk.errorLine; scope=$script:hk.scope}
}

#requires -Version 7.0
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows'){throw 'Remote Windows CI only'}
. (Join-Path $PSScriptRoot '..\tools\remote_lag_observe.ps1')
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
function Row([bool]$Optimized=$true){
    [pscustomobject]@{keijinPerformance=$(if($Optimized){2}else{0});lightweightActive=$(if($Optimized){1}else{0});
        diagnosticsEnabled=$(if($Optimized){1}else{0});diagnosticFrameCount=$(if($Optimized){12}else{0});
        diagnosticEventCount=$(if($Optimized){3}else{0});diagnosticFrozen=0;
        diagnosticGuardEvents=$(if($Optimized){1}else{-1});diagnosticNativeReceiptAvailable=$(if($Optimized){0}else{-1})}
}
$valid=Row
Check ((Get-LagFeatureSmoke @($valid) 'all_repaired' $true).status -ceq 'passed') 'Valid optimized evidence rejected'
foreach($variant in @('all_current','speedgear_only')){
    Check ((Get-LagFeatureSmoke @((Row $false)) $variant $false).status -ceq 'passed') 'Default-off evidence rejected'
    Check ((Get-LagFeatureSmoke @($valid) $variant $false).status -cne 'passed') 'Unexpected default opt-in accepted'
}
Check ((Get-LagFeatureSmoke @() 'all_repaired' $false).status -ceq 'blocked') 'Empty evidence accepted'
Check ((Get-LagFeatureSmoke @($valid) 'unknown' $false).status -ceq 'blocked') 'Unknown variant accepted'
foreach($field in @('diagnosticFrameCount','diagnosticEventCount','diagnosticsEnabled')){
    $bad=Row;$bad.$field=-1
    Check ((Get-LagFeatureSmoke @($bad) 'all_repaired' $false).status -ceq 'blocked') 'Missing API evidence accepted'
}
foreach($entry in @(@('diagnosticFrameCount',129),@('diagnosticEventCount',65),@('diagnosticGuardEvents',65),@('diagnosticFrozen',2),@('diagnosticsEnabled',2),@('lightweightActive',2),@('keijinPerformance',3))){
    $bad=Row;$bad.($entry[0])=$entry[1]
    Check ((Get-LagFeatureSmoke @($valid,$bad) 'all_repaired' $true).status -ceq 'failed') 'One valid row hid malformed feature evidence'
}
$bad=Row;$bad.diagnosticNativeReceiptAvailable=1
Check ((Get-LagFeatureSmoke @($bad) 'all_repaired' $true).status -ceq 'failed') 'Invented native-receipt claim accepted'
$bad=Row;$bad.diagnosticGuardEvents=0
Check ((Get-LagFeatureSmoke @($bad) 'all_repaired' $true).status -ceq 'failed') 'Guard observation without a reason was accepted'
$bad=Row;$bad.keijinPerformance=0
Check ((Get-LagFeatureSmoke @($bad) 'all_repaired' $false).status -ceq 'failed') 'Unpatched Keijin accepted as optimized'
$bad=Row;$bad.keijinPerformance=1
Check ((Get-LagFeatureSmoke @($bad) 'all_repaired' $false).status -ceq 'failed') 'Historical width-only repair accepted as frame-work repair'
$names=@('seq','wallUnix','phase','frames','loaded','updates','widthCalls','fontCalls','spawns','misses',
    'activePeak','activeNow','hookedWidths','hookedFonts','unsupported','preexisting','requestedSizes','actualSizes',
    'sizeOverflow','worldChildren','worldShown','regions','worldCapped','totalFrames','framesShown','enumCapped',
    'observerReads','desiredSpeed100','speed100','guard','gcKB','gcThreshold','clockMissing','updateHook','createHook',
    'versionUnsupported','nativeMeterRows','nativeMeterTotal','keijinPerformance','lightweightActive','diagnosticsEnabled',
    'diagnosticFrameCount','diagnosticEventCount','diagnosticFrozen','diagnosticGuardEvents','diagnosticNativeReceiptAvailable')
$parts=@('AZSGP1')+@($names | ForEach-Object {if($_ -ceq 'phase'){'playing'}elseif($_ -ceq 'seq'){'1'}else{'0'}})
$packet=[pscustomobject]@{FileTime=123456;Payload=($parts -join '|')}
$parsed=Read-LagRow $packet
Check ($null -ne $parsed -and $parsed.phase -ceq 'playing' -and $parsed.diagnosticFrameCount -eq 0) '47-field packet rejected'
$packet.Payload=($parts[0..38] -join '|')
Check ($null -eq (Read-LagRow $packet)) 'Historical 39-field packet was silently accepted'
$parts[1]='not-a-number';$packet.Payload=$parts -join '|'
Check ($null -eq (Read-LagRow $packet)) 'Malformed numeric packet accepted'
"Lag feature smoke: $script:checks counterexample and protocol checks passed."

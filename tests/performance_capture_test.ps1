#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$CapturePath,[Parameter(Mandatory=$true)][string]$HostPath)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){throw 'Remote Windows CI only'}
$capture=(Resolve-Path -LiteralPath $CapturePath).Path
$fixture=(Resolve-Path -LiteralPath $HostPath).Path
$root=Join-Path $env:RUNNER_TEMP ('AZSGPassiveCapture-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$other=Join-Path $root 'OtherGame';$reports=Join-Path $root 'Reports'
foreach($directory in @($game,$other,$reports)){New-Item -ItemType Directory -Path $directory -Force | Out-Null}
$exe=Join-Path $game 'AzerothSurvivors.exe';$otherExe=Join-Path $other 'AzerothSurvivors.exe'
Copy-Item -LiteralPath $fixture -Destination $exe
Copy-Item -LiteralPath $fixture -Destination $otherExe
$status=Join-Path $game 'AZSSpeedGear-status.json'
[IO.File]::WriteAllText($status,'{"product":"AzerothSurvivorsSpeedGear","schema":1,"backend":"ready","transport":"file","speed100":300,"heartbeatAgeMs":100}')
$before=@(Get-ChildItem -LiteralPath $game -File | ForEach-Object{[pscustomobject]@{Name=$_.Name;Hash=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$child=$null
try{
    $child=Start-Process -FilePath $exe -WorkingDirectory $game -WindowStyle Hidden -PassThru
    $out=Join-Path $reports 'observed.json'
    & $capture --game-path $exe --pid $child.Id --seconds 4 --output $out
    if($LASTEXITCODE -ne 0){throw 'Passive capture failed against owned fixture'}
    $data=Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    if($data.schema -ne 1 -or $data.sampleCount -lt 3 -or $data.sampleCount -gt 6 -or $data.status -cne 'observed'){throw 'Insufficient fixture observations'}
    if($data.gameLaunched -ne $false -or $data.inputInjected -ne $false -or $data.memoryContentsRead -ne $false){throw 'Passive-scope flags invalid'}
    foreach($row in $data.samples){
        if($row.fileTime -le 0 -or $null -eq $row.privateBytes -or $row.privateBytes -lt 0 -or $null -eq $row.workingSetBytes -or $row.workingSetBytes -lt 0 -or $row.processCpuMs -lt 0){throw 'Invalid OS resource sample'}
        if($row.native.speed100 -ne 300 -or $row.native.backend -cne 'ready'){throw 'Whitelisted native status was not read'}
        foreach($key in @('gpu3dMaxPercent','gpuDedicatedMaxBytes','gpuSharedMaxBytes')){
            $metric=$row.$key
            if($metric.status -cne 'available' -and $null -ne $metric.value){throw 'Unavailable GPU metric must be null'}
        }
    }
    $mismatch=Join-Path $reports 'mismatch.json'
    & $capture --game-path $otherExe --pid $child.Id --seconds 3 --output $mismatch
    if($LASTEXITCODE -eq 0){throw 'Mismatched process image was accepted'}
    $blocked=Get-Content -LiteralPath $mismatch -Raw | ConvertFrom-Json
    if($blocked.status -cne 'blocked' -or $blocked.reason -cne 'pid_image_mismatch' -or $blocked.sampleCount -ne 0){throw 'Mismatched image must be blocked'}
    $forbidden=Join-Path $game 'must-not-exist.json'
    & $capture --game-path $exe --pid $child.Id --seconds 3 --output $forbidden
    if($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $forbidden)){throw 'Game-directory output was allowed'}
    $existingHash=(Get-FileHash -LiteralPath $out).Hash
    & $capture --game-path $otherExe --pid $child.Id --seconds 3 --output $out
    if($LASTEXITCODE -eq 0 -or (Get-FileHash -LiteralPath $out).Hash -cne $existingHash){throw 'Existing report was overwritten'}
    if(@(Get-ChildItem -LiteralPath $game -File).Count -ne $before.Count){throw 'Fixture game directory acquired files'}
    foreach($entry in $before){if((Get-FileHash -LiteralPath (Join-Path $game $entry.Name)).Hash -cne $entry.Hash){throw 'Fixture game files changed'}}
    $child.WaitForExit(12000) | Out-Null
    $missing=Join-Path $reports 'missing.json'
    & $capture --game-path $exe --pid $child.Id --seconds 3 --output $missing
    if($LASTEXITCODE -eq 0){throw 'Exited process was accepted'}
    $missingData=Get-Content -LiteralPath $missing -Raw | ConvertFrom-Json
    if($missingData.status -cne 'blocked' -or $missingData.sampleCount -ne 0){throw 'Exited process should have no observations'}
    $global:LASTEXITCODE=0
    'Passive capture fixture, PID/image refusal, report protection and unchanged files verified.'
}finally{
    if($null -ne $child){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
}

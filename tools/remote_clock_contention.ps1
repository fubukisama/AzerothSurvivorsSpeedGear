#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$HostPath,
    [Parameter(Mandatory=$true)][string]$DllPath,
    [string]$OutputPath='acceptance/clock-contention.json'
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
    throw 'This diagnostic runs only on a disposable remote Windows runner.'
}
$hostSource=(Resolve-Path -LiteralPath $HostPath).Path
$dllSource=(Resolve-Path -LiteralPath $DllPath).Path
$root=Join-Path $env:RUNNER_TEMP ('AZSGClockContention-'+[guid]::NewGuid().ToString('N'))
$result=[ordered]@{schema=1;status='blocked';reason='not_started';sourceCommit=(git rev-parse HEAD);
    scope='Synthetic fixed-work timing API throughput using the actual production DLL. Wall and process CPU time use unhooked OS FILETIME. Performance values are observations, not pass thresholds or a real-game root-cause verdict.';
    dllSHA256=(Get-FileHash -LiteralPath $dllSource -Algorithm SHA256).Hash.ToLowerInvariant();runs=@()}
$failure=$null
try{
    foreach($mode in @('baseline','hooked')){
        $directory=Join-Path $root $mode
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $testExecutable=Join-Path $directory 'AZSSpeedGearTestHost.exe'
        Copy-Item -LiteralPath $hostSource -Destination $testExecutable
        if($mode -eq 'hooked'){Copy-Item -LiteralPath $dllSource -Destination (Join-Path $directory 'dwmapi.dll')}
        $report=Join-Path $directory 'report.json'
        $info=[Diagnostics.ProcessStartInfo]::new($testExecutable)
        $info.WorkingDirectory=$directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.ArgumentList.Add('--'+$mode);$info.ArgumentList.Add($report)
        foreach($name in @('GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN','AZSG_GAME_BUNDLE_URL')){[void]$info.Environment.Remove($name)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        if(-not $process.Start()){throw 'Diagnostic host did not start'}
        $standard=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(90000)){
            $process.Kill($true);$process.WaitForExit();throw 'Diagnostic host exceeded its remote time budget'
        }
        $standard.GetAwaiter().GetResult() | Out-Null
        $errorText=$errors.GetAwaiter().GetResult()
        $data=if(Test-Path -LiteralPath $report){Get-Content -LiteralPath $report -Raw | ConvertFrom-Json}else{$null}
        if($null -ne $data){$result.runs+=@($data.samples)}
        if($process.ExitCode -ne 0){throw ('Diagnostic host failed with code '+$process.ExitCode+': '+$errorText.Substring(0,[Math]::Min(512,$errorText.Length)))}
        if($data.validClockObservations -ne $true){throw 'Native clock observations were not valid'}
        $process.Dispose()
    }
    $result.status='observed';$result.reason='fixed_work_clock_observations_recorded'
}catch{
    $failure=$_;$result.reason='diagnostic_environment_or_clock_validation_failed'
    $result.exceptionType=$_.Exception.GetType().FullName
}finally{
    $target=[IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target -Encoding utf8
}
if($null -ne $failure){throw $failure}
$result.runs | Select-Object stage,threads,calls,wallMs,processCpuMs,observedQpcRate | ConvertTo-Json -Compress

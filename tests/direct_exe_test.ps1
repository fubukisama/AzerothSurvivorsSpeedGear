#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$HostPath,[Parameter(Mandatory=$true)][string]$DllPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path $env:RUNNER_TEMP ('AZSG-direct-'+[guid]::NewGuid().ToString('N'))
$gameRoot=Join-Path $root "direct game & user's copy"
$updater=Join-Path $gameRoot 'benilla-config\AddOns\AZSSpeedGear\Updater'
New-Item -ItemType Directory -Path $updater -Force | Out-Null
$game=Join-Path $gameRoot 'AzerothSurvivors.exe'
Copy-Item -LiteralPath $HostPath -Destination $game
Copy-Item -LiteralPath $DllPath -Destination (Join-Path $gameRoot 'dwmapi.dll')
$project=Split-Path -Parent $PSScriptRoot
Copy-Item -LiteralPath (Join-Path $project 'scripts\NativeUpdate.ps1') -Destination (Join-Path $updater 'NativeUpdate.ps1')
$mock=@'
param([string]$GamePath,[switch]$WaitForExit)
$root=Split-Path -Parent $GamePath
if(-not $WaitForExit){Add-Content -LiteralPath (Join-Path $root 'immediate.marker') -Value 'checked';return}
while(@(Get-Process -Name AzerothSurvivors -ErrorAction SilentlyContinue | Where-Object {$_.Path -ieq $GamePath}).Count -gt 0){Start-Sleep -Milliseconds 50}
Add-Content -LiteralPath (Join-Path $root 'post.marker') -Value 'checked-after-exit'
'@
[IO.File]::WriteAllText((Join-Path $updater 'Update.ps1'),$mock,[Text.UTF8Encoding]::new($false))
$managed=@(foreach($name in @('Update.ps1','NativeUpdate.ps1')){
    $file=Join-Path $updater $name
    [pscustomobject]@{RelativePath=('benilla-config\AddOns\AZSSpeedGear\Updater\'+$name);SHA256=(Get-FileHash -LiteralPath $file).Hash;Bytes=(Get-Item -LiteralPath $file).Length}
})
[ordered]@{Product='AZSSpeedGear';SchemaVersion=1;Version='0.6.0';GameExecutable=$game;ManagedFiles=$managed} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $gameRoot 'benilla-config\AZSSpeedGear-install.json') -Encoding UTF8
function Wait-Marker([string]$Name,[int]$Seconds=20){
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    $marker=Join-Path $gameRoot $Name
    while([DateTime]::UtcNow -lt $deadline){if(Test-Path -LiteralPath $marker){return};Start-Sleep -Milliseconds 50}
    $details=''
    foreach($relative in @('AZSSpeedGear.log','benilla-config\AZSSpeedGear-updates\native-update.log')){
        $file=Join-Path $gameRoot $relative
        if(Test-Path -LiteralPath $file){$details+=[IO.File]::ReadAllText($file)}
    }
    throw "Timed out waiting for $Name. $details"
}
$process=$null
try{
    # This is the tiny compiled fixture, not the official game. No launcher or
    # Update.ps1 entrypoint is invoked by the harness to trigger the first check.
    $process=Start-Process -FilePath $game -WorkingDirectory $gameRoot -PassThru -WindowStyle Hidden
    Wait-Marker 'host.started'
    Wait-Marker 'immediate.marker'
    if($process.HasExited){throw 'Fixture exited before the immediate update check.'}
    if(Test-Path -LiteralPath (Join-Path $gameRoot 'post.marker')){throw 'Exit-stage work ran while the fixture was alive.'}
    New-Item -ItemType File -Path (Join-Path $gameRoot 'exit.request') | Out-Null
    if(-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0){throw 'Direct EXE fixture failed or did not stop normally.'}
    Wait-Marker 'post.marker'
    if(@(Get-Content -LiteralPath (Join-Path $gameRoot 'immediate.marker')).Count -ne 1){throw 'Immediate check ran more than once.'}
    [pscustomobject]@{Passed=$true;StaticDwmLoadTriggeredUpdate=$true;GameEntrypointUnchanged=$true;AfterExitCheck=$true;ActualGameUsed=$false} | ConvertTo-Json
} finally {
    if($null -ne $process -and -not $process.HasExited){
        New-Item -ItemType File -Path (Join-Path $gameRoot 'exit.request') -Force | Out-Null
        if(-not $process.WaitForExit(5000)){Stop-Process -Id $process.Id -Force}
    }
}

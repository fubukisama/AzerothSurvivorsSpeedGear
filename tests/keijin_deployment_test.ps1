#requires -Version 7.0
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows'){throw 'Remote Windows CI only'}
$checks=0
function Check([bool]$ok,[string]$why){$script:checks++;if(-not $ok){throw $why}}
$root=Join-Path $env:RUNNER_TEMP ('KeijinDeployment-'+[guid]::NewGuid().ToString('N'))
$addon=Join-Path $root 'benilla-config\AddOns\KeijinUI'
New-Item -ItemType Directory -Path $addon -Force | Out-Null
$exe=Join-Path $root 'AzerothSurvivors.exe';[IO.File]::WriteAllText($exe,'Owned fixture only; never executed')
$toc=Join-Path $addon 'KeijinUI.toc';[IO.File]::WriteAllText($toc,"## Version: 4.6.1-damageonly.1`n")
$source=Join-Path $addon 'DamageText.lua';Copy-Item -LiteralPath $env:AZSG_KEIJIN_ORIGINAL -Destination $source
$scriptPath=Join-Path $PSScriptRoot '..\scripts\RepairKeijin.ps1'
$saved=Join-Path $root 'benilla-config\saved';New-Item -ItemType Directory -Path $saved -Force | Out-Null
$settings=Join-Path $saved 'KeijinUI.lua';[IO.File]::WriteAllText($settings,'KeijinUIDB = {keep=true}')
$settingsHash=(Get-FileHash $settings).Hash
$result=& $scriptPath -GamePath $exe
Check $result.Changed 'GamePath deployment did not apply'
Check ($result.RepairRevision -eq 2) 'Wrong repair revision'
Check ((Get-FileHash $source).Hash -ceq (Get-FileHash $env:AZSG_KEIJIN_SOURCE).Hash) 'GamePath output differs from verified CI source'
Check ((Get-FileHash (Join-Path $result.BackupDirectory 'DamageText.lua')).Hash.ToLowerInvariant() -ceq $result.OriginalSHA256) 'GamePath backup mismatch'
Check ((Get-FileHash $settings).Hash -ceq $settingsHash) 'Saved settings changed'
$repeat=& $scriptPath -GamePath $exe
Check (-not $repeat.Changed) 'GamePath deployment is not idempotent'
$before=(Get-FileHash $source).Hash
[IO.File]::WriteAllText($toc,"## Version: 9.9.9`n")
$rejected=$false;try{& $scriptPath -GamePath $exe | Out-Null}catch{$rejected=$true}
Check $rejected 'Unsupported TOC version was accepted'
Check ((Get-FileHash $source).Hash -ceq $before) 'Rejected version changed the source'
[IO.File]::WriteAllText($toc,"## Version: 4.6.1-damageonly.1`n")
[IO.File]::WriteAllText($source,'-- unsupported customization')
$before=(Get-FileHash $source).Hash
$rejected=$false;try{& $scriptPath -GamePath $exe | Out-Null}catch{$rejected=$true}
Check $rejected 'Unknown customization was accepted'
Check ((Get-FileHash $source).Hash -ceq $before) 'Rejected customization changed'
"Keijin deployment: $script:checks GamePath, backup, settings and refusal checks passed; no game launched."

#requires -Version 5.1
param([string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = '0.2.0'
$package = Join-Path $root ('dist\AZSSpeedGear-' + $version + '-Windows-x64')
if (Test-Path -LiteralPath $package) { throw 'Package folder already exists; use a new clean output directory.' }
foreach ($directory in @('AddOns','Native','scripts','docs','licenses')) {
    New-Item -ItemType Directory -Path (Join-Path $package $directory) -Force | Out-Null
}
Copy-Item -LiteralPath (Join-Path $root 'AddOns\AZSSpeedGear') -Destination (Join-Path $package 'AddOns\AZSSpeedGear') -Recurse
Copy-Item -LiteralPath (Join-Path $root "build\$Configuration\dwmapi.dll") -Destination (Join-Path $package 'Native\dwmapi.dll')
Copy-Item -LiteralPath (Join-Path $root "build\$Configuration\AZSSpeedGearProbe.exe") -Destination (Join-Path $package 'Native\AZSSpeedGearProbe.exe')
foreach ($file in @('Install.ps1','Uninstall.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $package "scripts\$file") }
foreach ($file in @('README.md','README.zh-CN.md','LICENSE','THIRD_PARTY_NOTICES.md')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $package $file) }
Copy-Item -LiteralPath (Join-Path $root 'docs\COMPATIBILITY.md') -Destination (Join-Path $package 'docs\COMPATIBILITY.md')
if (Test-Path -LiteralPath (Join-Path $root 'docs\VALIDATION.md')) { Copy-Item -LiteralPath (Join-Path $root 'docs\VALIDATION.md') -Destination (Join-Path $package 'docs\VALIDATION.md') }
Copy-Item -LiteralPath (Join-Path $root 'third_party\azs-speed-controller\LICENSE') -Destination (Join-Path $package 'licenses\AZS-Speed-Controller-MIT.txt')
Copy-Item -LiteralPath (Join-Path $root 'third_party\minhook\LICENSE.txt') -Destination (Join-Path $package 'licenses\MinHook-BSD.txt')
$manifest = foreach ($file in Get-ChildItem -LiteralPath $package -File -Recurse) {
    [pscustomobject]@{ Path = $file.FullName.Substring($package.Length+1).Replace('\','/'); Bytes = $file.Length; SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $package 'files.json') -Encoding UTF8
$archive = $package + '.zip'
Compress-Archive -LiteralPath $package -DestinationPath $archive
[pscustomobject]@{ Package = $package; Archive = $archive; SHA256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() } | ConvertTo-Json

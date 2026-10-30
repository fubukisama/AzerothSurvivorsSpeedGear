#requires -Version 5.1
param([string]$Configuration = 'Release', [string]$CMake = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CMake) {
    $command = Get-Command cmake -ErrorAction SilentlyContinue
    if ($command) { $CMake = $command.Source }
    else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $CMake = @(& $vswhere -latest -products '*' -find 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' | Select-Object -First 1)[0]
        }
    }
}
if (-not $CMake -or -not (Test-Path -LiteralPath $CMake)) { throw 'CMake and the Visual C++ x64 toolchain are required.' }
& $CMake -S $root -B (Join-Path $root 'build') -A x64
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
& $CMake --build (Join-Path $root 'build') --config $Configuration --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Write-Output (Join-Path $root "build\$Configuration\dwmapi.dll")

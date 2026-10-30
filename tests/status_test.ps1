#requires -Version 5.1
[CmdletBinding()]
param()

# Remote-CI fixture test only. It never launches a game and writes only within
# its own newly-created temporary directory. Do not run against a real install.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$viewer = Join-Path $projectRoot 'scripts\Status.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $temporaryBase ('AZSSpeedGear-status-tests-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith($temporaryBase + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $fixtureRoot)) { throw 'Fixture must be a new child of the temporary directory.' }
$gameRoot = Join-Path $fixtureRoot 'game'
$gameExe = Join-Path $gameRoot 'AzerothSurvivors.exe'
$statusPath = Join-Path $gameRoot 'AZSSpeedGear-status.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$script:checks = 0

function Assert-StatusTest([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:checks++
}

function Write-Fixture([string]$Text) { [IO.File]::WriteAllText($script:statusPath, $Text, $script:utf8) }

function New-FixtureState {
    return [ordered]@{
        product = 'AzerothSurvivorsSpeedGear'; schema = 1; version = '0.4.0'
        updatedUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        backend = 'ready'; transport = 'console'; speed100 = 200; heartbeatAgeMs = 20
        fileReads = 3; consoleForwardDroppedBytes = 0
    }
}

function Read-Fixture {
    return (& $script:viewer -GamePath $script:gameExe -AsJson | ConvertFrom-Json)
}

function Assert-InvalidFixture($State, [string]$Reason, [string]$Label) {
    Write-Fixture ($State | ConvertTo-Json -Depth 5)
    $read = Read-Fixture
    Assert-StatusTest ($read.state -eq 'invalid' -and $read.reason -eq $Reason) $Label
}

try {
    New-Item -ItemType Directory -Path $gameRoot -Force | Out-Null
    [IO.File]::WriteAllBytes($gameExe, [byte[]]@(0x4d, 0x5a)) # Inert; never executed.
    $missing = Read-Fixture
    Assert-StatusTest ($missing.state -eq 'missing') 'missing status is reported'
    Assert-StatusTest ($missing.product -ceq 'AzerothSurvivorsSpeedGear') 'exact product name'

    Write-Fixture '{not JSON'
    $malformed = Read-Fixture
    Assert-StatusTest ($malformed.state -eq 'invalid' -and $malformed.reason -eq 'malformed_json') 'malformed JSON is rejected'

    $state = New-FixtureState
    Write-Fixture ($state | ConvertTo-Json)
    $console = Read-Fixture
    Assert-StatusTest ($console.state -eq 'ready' -and $console.transport -eq 'console') 'confirmed console state'
    Assert-StatusTest ($console.backendConfiguredMultiplier -eq 2) 'configured multiplier is normalized'
    Assert-StatusTest ($console.speedMeaning -ceq 'backend configured/applied setting; not measured game speed') 'speed is explicitly not a game measurement'
    Assert-StatusTest (@($console.warnings).Count -eq 0) 'no invented warning on zero dropped bytes'
    $byDirectory = & $viewer -GamePath $gameRoot -AsJson | ConvertFrom-Json
    Assert-StatusTest ($byDirectory.state -eq 'ready') 'GamePath accepts directory'
    $reordered = [ordered]@{}
    foreach ($key in @($state.Keys | Sort-Object -Descending)) { $reordered[$key] = $state[$key] }
    Write-Fixture ($reordered | ConvertTo-Json)
    Assert-StatusTest ((Read-Fixture).state -eq 'ready') 'native property order does not affect parsing'

    $state = New-FixtureState; $state.transport = 'file'; $state.heartbeatAgeMs = $null
    Write-Fixture ($state | ConvertTo-Json)
    $file = Read-Fixture
    Assert-StatusTest ($file.state -eq 'ready' -and $file.transport -eq 'file' -and $null -eq $file.heartbeatAgeMs) 'file fallback and nullable heartbeat'

    $state = New-FixtureState; $state.consoleForwardDroppedBytes = 4096
    Write-Fixture ($state | ConvertTo-Json)
    $drop = Read-Fixture
    Assert-StatusTest ($drop.consoleForwardDroppedBytes -eq 4096 -and @($drop.warnings).Count -eq 1) 'forwarded-log drop counter produces warning'
    Assert-StatusTest ($drop.transport -eq 'console') 'forward drops do not invent a different transport'

    $state = New-FixtureState; $state.fileReads = [uint64]::MaxValue
    Write-Fixture ($state | ConvertTo-Json)
    $largeCounter = Read-Fixture
    Assert-StatusTest ($largeCounter.state -eq 'ready' -and [decimal]$largeCounter.fileReads -eq [decimal][uint64]::MaxValue) 'full uint64 counter range'

    $state = New-FixtureState; $state.updatedUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 30
    Write-Fixture ($state | ConvertTo-Json)
    $stale = Read-Fixture
    Assert-StatusTest ($stale.state -eq 'offline' -and $stale.reason -eq 'status_expired') 'old snapshot is offline'
    $state = New-FixtureState; $state.updatedUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60
    Assert-InvalidFixture $state 'future_timestamp' 'future timestamp is invalid'

    foreach ($backend in @('unsupported', 'hooks_failed')) {
        $state = New-FixtureState; $state.backend = $backend; $state.transport = 'disabled'
        Write-Fixture ($state | ConvertTo-Json)
        $disabled = Read-Fixture
        Assert-StatusTest ($disabled.state -eq 'disabled' -and $disabled.reason -eq $backend) ('disabled explanation: ' + $backend)
    }
    foreach ($transport in @('waiting', 'degraded', 'stale', 'disabled')) {
        $state = New-FixtureState; $state.transport = $transport
        Write-Fixture ($state | ConvertTo-Json)
        $read = Read-Fixture
        Assert-StatusTest ($read.state -eq $transport) ('native transport state: ' + $transport)
    }
    $state = New-FixtureState; $state.backend = 'initializing'; $state.transport = 'waiting'
    Write-Fixture ($state | ConvertTo-Json)
    Assert-StatusTest ((Read-Fixture).state -eq 'initializing') 'initializing backend'

    $state = New-FixtureState; $state.schema = 2
    Assert-InvalidFixture $state 'unknown_schema' 'unknown schema is rejected'
    $state = New-FixtureState; $state.product = 'AnotherProduct'
    Assert-InvalidFixture $state 'unknown_product' 'foreign product is rejected'
    $state = New-FixtureState; $state.version = '0.5.0'
    Assert-InvalidFixture $state 'unknown_version' 'unknown version is rejected'
    $state = New-FixtureState; $state.backend = 'mystery'
    Assert-InvalidFixture $state 'unknown_backend' 'unknown backend is rejected'
    $state = New-FixtureState; $state.transport = 'maybe'
    Assert-InvalidFixture $state 'unknown_transport' 'unknown transport is rejected'
    foreach ($field in @('schema', 'updatedUnix', 'speed100', 'heartbeatAgeMs', 'fileReads', 'consoleForwardDroppedBytes')) {
        $state = New-FixtureState; $state[$field] = '1'
        Assert-InvalidFixture $state 'invalid_type' ('numeric string rejected: ' + $field)
    }
    $state = New-FixtureState; $state.fileReads = $true
    Assert-InvalidFixture $state 'invalid_type' 'boolean counter is rejected'
    $state = New-FixtureState; $state.fileReads = -1
    Assert-InvalidFixture $state 'invalid_number' 'negative counter is rejected'
    foreach ($speed in @(24, 1001)) {
        $state = New-FixtureState; $state.speed100 = $speed
        Assert-InvalidFixture $state 'invalid_speed' ('out-of-range speed rejected: ' + $speed)
    }
    $state = New-FixtureState; $state['extra'] = 1
    Assert-InvalidFixture $state 'invalid_fields' 'extra field is rejected'
    $state = New-FixtureState
    $json = $state | ConvertTo-Json
    Write-Fixture ($json -replace '"schema"\s*:\s*1', '"schema":1,"schema":1')
    Assert-StatusTest ((Read-Fixture).state -eq 'invalid') 'duplicate key is rejected'

    Write-Fixture (' ' * 16385)
    $huge = Read-Fixture
    Assert-StatusTest ($huge.state -eq 'invalid' -and $huge.reason -eq 'file_too_large') 'oversized file is rejected'
    [IO.File]::WriteAllBytes($statusPath, [byte[]]@(0xff, 0xfe, 0x00, 0x00))
    Assert-StatusTest ((Read-Fixture).state -eq 'invalid') 'non-UTF8 input is rejected'

    # A directory junction needs no symbolic-link privilege on Windows. Its
    # target stays in this fixture; no user directory or game install is used.
    if ($env:OS -eq 'Windows_NT') {
        $state = New-FixtureState; Write-Fixture ($state | ConvertTo-Json)
        $linkedRoot = Join-Path $fixtureRoot 'linked-game'
        New-Item -ItemType Junction -Path $linkedRoot -Target $gameRoot | Out-Null
        $linked = & $viewer -GamePath $linkedRoot -AsJson | ConvertFrom-Json
        Assert-StatusTest ($linked.state -eq 'invalid' -and $linked.reason -eq 'link_path') 'linked game path is rejected'
        [IO.Directory]::Delete($linkedRoot) # Remove only this junction itself.
    }

    [pscustomobject]@{ Passed = $true; Checks = $checks; RealGameTouched = $false } | ConvertTo-Json
} finally {
    # Never recursively remove a computed or linked parent. The only recursive
    # target is this exact, freshly-created fixture under the explicit TEMP root.
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).ProviderPath
        $item = Get-Item -LiteralPath $fixtureRoot -Force
        if ($resolved -ieq $fixtureRoot -and
            $resolved.StartsWith($temporaryBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        } else {
            Write-Warning 'Fixture cleanup refused an unexpected path.'
        }
    }
}

#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [string]$OutputPath = 'acceptance/report.json'
)

# Deliberately unusable on a developer workstation. No local test execution.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'Remote GitHub Windows runner only.' }
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$temporaryRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ('AZSG-real-game-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $fixtureRoot)) { throw 'Unsafe disposable fixture path.' }
$package = [IO.Path]::GetFullPath($PackagePath)
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not $output.StartsWith($projectRoot + '\acceptance\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Report must be under this checkout acceptance directory.' }
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$report = [ordered]@{ schema = 1; product = 'AzerothSurvivorsSpeedGear'; status = 'blocked'; reason = 'not_started'; phase = 'initialized'; exceptionType = $null
    checkedUtc = [DateTime]::UtcNow.ToString('o'); sourceCommit = $env:GITHUB_SHA; ciRunId = $env:GITHUB_RUN_ID
    gameVersion = $null; gameSha256 = $null; gameBytes = $null; officialAssetsSha256 = $null; candidateDllSha256 = $null; pluginVersion = $null
    renderingRequested = 'DX12 software fallback / Microsoft Basic Render Driver'; runs = @(); criteria = @(); metrics = $null; missingEvidence = @()
    scope = 'One official Windows build on a disposable software-rendered runner. No general gameplay or future-version certification.'
    clock = 'GetSystemTimePreciseAsFileTime in the unhooked parent process'
    skillCounterMeaning = 'Observed raw cooldown decay/resets and damage/stop events; not an authoritative successful-cast count.'
    nativeUpdater = 'Absent helper and receipt in disposable runtime prevent automatic replacement of the candidate DLL.' }
$exitCode = 2

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:utf8)
}

function Get-OfficialGame {
    # Reuse the bounded, same-origin, SHA/size-verified latest-EXE downloader.
    # The historical RAR supplies only MPQ assets; its old EXE is never executed.
    $python = @'
import hashlib,json,sys,time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import build_opener,HTTPRedirectHandler,Request
sys.path.insert(0,str(Path(sys.argv[1])/'tools'))
import check_game_compatibility as m
root=Path(sys.argv[2])
opener=build_opener(m.OfficialRedirects())
manifest=m.fetch_manifest(opener)
exe=m.download_exe(manifest,root,opener)
url='https://wow.aethus.pl/download/AzerothSurvivorsWindowsNew.rar'
class RarRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        p=urlsplit(newurl)
        if p.scheme!='https' or p.hostname!='wow.aethus.pl' or p.port not in (None,443) or p.path!='/download/AzerothSurvivorsWindowsNew.rar' or p.query or p.fragment or p.username or p.password:
            raise ValueError('official asset redirect left its fixed HTTPS URL')
        return super().redirect_request(req,fp,code,msg,headers,newurl)
digest=hashlib.sha256(); total=0; deadline=time.monotonic()+600
with build_opener(RarRedirect()).open(Request(url,headers={'Accept-Encoding':'identity'}),timeout=30) as r,(root/'official-assets.rar').open('wb') as f:
    if r.geturl()!=url: raise ValueError('unexpected final official assets URL')
    while True:
        if time.monotonic()>deadline: raise ValueError('official assets download deadline exceeded')
        chunk=getattr(r,'read1',r.read)(65536)
        if not chunk: break
        total+=len(chunk)
        if total>1024*1024*1024: raise ValueError('official assets archive exceeds 1 GiB')
        digest.update(chunk); f.write(chunk)
print(json.dumps({'version':manifest['version'],'sha256':manifest['sha256'],'size':manifest['size'],'assetsSha256':digest.hexdigest()}))
'@
    $lines = @(& python -c $python $script:projectRoot $script:fixtureRoot 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) { throw 'blocked_download' }
    return $lines[0] | ConvertFrom-Json
}

function Expand-OnlyOfficialAssets([string]$Destination) {
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not [IO.File]::Exists($sevenZip)) { throw 'blocked_archive_tool' }
    $archive = Join-Path $script:fixtureRoot 'official-assets.rar'
    $listing = (@(& $sevenZip l -slt $archive 2>$null) -join "`n").Replace("`r", '')
    if ($LASTEXITCODE -ne 0 -or $listing.Length -gt 2MB) { throw 'blocked_archive_listing' }
    $marker = $listing.IndexOf('----------', [StringComparison]::Ordinal)
    if ($marker -lt 0) { throw 'blocked_archive_listing' }
    $payload = $listing.Substring($marker + 10)
    $assets = [Collections.Generic.List[string]]::new()
    $assetRoot = $null; $entries = 0; [long]$total = 0
    foreach ($block in [regex]::Split($payload.Trim(), '\n\n+')) {
        $paths = [regex]::Matches($block, '(?m)^Path = ([^\n]+)$')
        if ($paths.Count -ne 1) { throw 'blocked_archive_entry' }
        $entries++
        if ($entries -gt 4096 -or $block -match '(?m)^(Symbolic Link|Hard Link|Reparse Point) = ') { throw 'blocked_archive_links_or_count' }
        $name = $paths[0].Groups[1].Value.Replace('/', '\')
        if ([IO.Path]::IsPathRooted($name) -or $name -match '[\x00-\x1f<>:"|?*]' -or
            @($name.Split('\') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_ -match '[. ]$' }).Count) { throw 'blocked_archive_path' }
        $size = [regex]::Match($block, '(?m)^Size = ([0-9]+)$')
        if (-not $size.Success) { throw 'blocked_archive_size' }
        $bytes = [long]::Parse($size.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        $total += $bytes
        if ($bytes -gt 4GB -or $total -gt 8GB) { throw 'blocked_archive_expansion' }
        if ($name -match '^(?<root>(?:[^\\]+\\)*Data)\\[^\\]+\.[mM][pP][qQ]$') {
            $parent = $Matches['root']
            if ($null -ne $assetRoot -and $parent -cne $assetRoot) { throw 'blocked_multiple_asset_roots' }
            $assetRoot = $parent; $assets.Add($name)
        }
    }
    if ($assets.Count -lt 1 -or $assets.Count -gt 128) { throw 'blocked_missing_assets' }
    $listPath = Join-Path $script:fixtureRoot 'selected-assets.txt'
    [IO.File]::WriteAllLines($listPath, $assets.ToArray(), $script:utf8)
    & $sevenZip x $archive ('-o' + $Destination) ('@' + $listPath) -y -bd -bso0 -bsp0 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'blocked_asset_extraction' }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Destination -Force -Recurse)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'blocked_extracted_link' }
    }
    return Join-Path $Destination $assetRoot
}

# Callbacks never publish raw game logs. Only our short numeric protocol enters
# the queue; GPU errors are reduced to flags. This process is not time-hooked.
$hostSource = @'
using System;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
public sealed class AZSGRemoteRow { public long FileTime; public string Payload; }
public sealed class AZSGRemoteGame : IDisposable {
  public readonly ConcurrentQueue<AZSGRemoteRow> Rows = new ConcurrentQueue<AZSGRemoteRow>();
  public Process Child; public bool GpuFailure, Panicked, SoftwareObserved; public int Dropped;
  [DllImport("kernel32.dll")] public static extern void GetSystemTimePreciseAsFileTime(out long time);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window,int command);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
  [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
  [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code,uint kind);
  [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra; }
  [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
  [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Keyboard Key; [FieldOffset(0)] public Mouse Mouse; }
  [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public Union Value; }
  public static long Wall() { long value; GetSystemTimePreciseAsFileTime(out value); return value; }
  void Line(object sender,DataReceivedEventArgs e) {
    var text=e.Data; if(text==null) return;
    if(text.IndexOf("Microsoft Basic Render Driver",StringComparison.OrdinalIgnoreCase)>=0 || text.IndexOf("device_type: Cpu",StringComparison.OrdinalIgnoreCase)>=0) SoftwareObserved=true;
    if(text.IndexOf("Unable to find a GPU",StringComparison.OrdinalIgnoreCase)>=0 || text.IndexOf("failed to create wgpu",StringComparison.OrdinalIgnoreCase)>=0 || text.IndexOf("RequestDeviceError",StringComparison.OrdinalIgnoreCase)>=0) GpuFailure=true;
    if(text.IndexOf("panicked at",StringComparison.Ordinal)>=0) Panicked=true;
    var at=text.IndexOf("AZSGT1|",StringComparison.Ordinal); if(at<0 || text.Length-at>2048) return;
    if(Rows.Count>=8192) { System.Threading.Interlocked.Increment(ref Dropped); return; }
    Rows.Enqueue(new AZSGRemoteRow {FileTime=Wall(),Payload=text.Substring(at)});
  }
  public void Start(ProcessStartInfo info) {
    Child=new Process(); Child.StartInfo=info; Child.OutputDataReceived+=Line; Child.ErrorDataReceived+=Line;
    if(!Child.Start()) throw new Exception("blocked_process_start");
    Child.BeginOutputReadLine(); Child.BeginErrorReadLine();
  }
  public bool Focus() {
    Child.Refresh(); var handle=Child.MainWindowHandle; if(handle==IntPtr.Zero) return false;
    ShowWindow(handle,9); SetForegroundWindow(handle); uint pid; GetWindowThreadProcessId(GetForegroundWindow(),out pid); return pid==(uint)Child.Id;
  }
  public bool Key(ushort key,bool down) {
    if(!Focus()) return false;
    var scan=MapVirtualKeyW(key,0); var input=new Input {Type=1};
    input.Value.Key=new Keyboard {Vk=scan==0?key:(ushort)0,Scan=(ushort)scan,Flags=(scan==0?0u:8u)|(down?0u:2u)};
    return SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))==1;
  }
  public bool Tap(ushort key) { var down=Key(key,true); System.Threading.Thread.Sleep(80); return Key(key,false)&&down; }
  public void Dispose() {
    if(Child==null) return;
    try { if(!Child.HasExited) { Key(0x57,false); Key(0x53,false); Child.CloseMainWindow(); if(!Child.WaitForExit(3000)) { Child.Kill(); Child.WaitForExit(3000); } } } catch {}
    Child.Dispose();
  }
}
'@

function Read-Telemetry($Row) {
    $match = [regex]::Match($Row.Payload, '^(?<protocol>AZSGT1\|[0-9]+\|[01]\|(?:100|200)\|[0-5]\|(?:unknown|ready|playing|choosing|paused|dead|victory)\|(?:-?[0-9]+(?:\.[0-9]+)?\|){16}[01])(?:[^0-9.]|$)')
    if (-not $match.Success) { return $null }
    $parts = $match.Groups['protocol'].Value.Split('|')
    if ($parts.Count -ne 23) { return $null }
    $numeric = @()
    for ($index = 6; $index -le 21; $index++) {
        [double]$value = 0
        if (-not [double]::TryParse($parts[$index], [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or -not [double]::IsFinite($value)) { return $null }
        $numeric += $value
    }
    return [pscustomobject]@{ fileTime = [long]$Row.FileTime; seq = [long]$parts[1]; mode = [int]$parts[2]
        target = [int]$parts[3]; stage = [int]$parts[4]; phase = $parts[5]; rawT = $numeric[0]; getTime = $numeric[1]
        gameWallUnix = $numeric[2]; mapX = $numeric[3]; mapY = $numeric[4]; mapContinent = $numeric[5]; mapZone = $numeric[6]
        spellId = $numeric[7]; cd = $numeric[8]; cdmax = $numeric[9]; cooldownResets = $numeric[10]
        spellcastStopEvents = $numeric[11]; selfDamageEvents = $numeric[12]; hp = $numeric[13]
        runPackets = $numeric[14]; spellPackets = $numeric[15]; requestAccepted = [int]$parts[22] }
}

function Invoke-GameRun([string]$Mode, [string]$GameRoot, [string]$Assets, [string]$OfficialExe) {
    New-Item -ItemType Directory -Path $GameRoot -Force | Out-Null
    $data = Join-Path $GameRoot 'Data'
    New-Item -ItemType Directory -Path $data | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $Assets -File)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $data $file.Name) }
    $exe = Join-Path $GameRoot 'AzerothSurvivors.exe'
    Copy-Item -LiteralPath $OfficialExe -Destination $exe
    $state = Join-Path $GameRoot 'benilla-config'
    $telemetry = Join-Path $state 'AddOns\AZSGAcceptance'
    Write-Text (Join-Path $telemetry 'AZSGAcceptance.toc') "## Interface: 11200`n## Title: AZSG remote acceptance`nMode.lua`nTelemetry.lua`n"
    Write-Text (Join-Path $telemetry 'Mode.lua') ('AZSGAcceptanceMode = "' + $Mode + '";' + "`n")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'remote_game_telemetry.lua') -Destination (Join-Path $telemetry 'Telemetry.lua')
    Write-Text (Join-Path $state 'config.toml') "[cvars]`ngxWindow = `"1`"`ngxResolution = `"640x480`"`ngxVSync = `"0`"`nfarclip = `"177`"`nshadowLevel = `"0`"`n"
    if ($Mode -ceq 'hooked') {
        $addon = Join-Path $state 'AddOns\AZSSpeedGear'
        New-Item -ItemType Directory -Path $addon | Out-Null
        foreach ($name in @('AZSSpeedGear.toc', 'NativeLocale.lua', 'Localization.lua', 'LocaleDetection.lua', 'AZSSpeedGear.lua')) {
            Copy-Item -LiteralPath (Join-Path $script:package ('AddOns\AZSSpeedGear\' + $name)) -Destination (Join-Path $addon $name)
        }
        Copy-Item -LiteralPath (Join-Path $script:package 'Native\dwmapi.dll') -Destination (Join-Path $GameRoot 'dwmapi.dll')
    }
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.WorkingDirectory = $GameRoot; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Environment['WGPU_BACKEND'] = 'dx12'
    $info.Environment['WGPU_FORCE_FALLBACK_ADAPTER'] = '1'
    $info.Environment['WGPU_ADAPTER_NAME'] = 'Microsoft Basic Render Driver'
    $info.Environment['WOW_WIN'] = '640x480'
    $info.Environment['BENILLA_HOME'] = $state
    $appData = Join-Path $GameRoot 'AppData'; New-Item -ItemType Directory -Path $appData | Out-Null
    $info.Environment['APPDATA'] = $appData; $info.Environment['LOCALAPPDATA'] = $appData
    $session = [AZSGRemoteGame]::new()
    $samples = [Collections.Generic.List[object]]::new()
    $start = [AZSGRemoteGame]::Wall(); $firstPlayingAt = $null; $lastEnter = 0L; $lastChoice = 0L
    $movementKey = 0; $moveStage = -1; $moveStart = 0L; $inputOkay = $true; $reason = 'blocked_no_playing'
    try {
        $session.Start($info)
        while (([AZSGRemoteGame]::Wall() - $start) / 1e7 -lt 150) {
            if ($session.Child.HasExited) { $reason = if ($session.GpuFailure) { 'blocked_renderer' } else { 'blocked_game_exited' }; break }
            $row = $null
            while ($session.Rows.TryDequeue([ref]$row)) {
                $sample = Read-Telemetry $row
                if ($null -ne $sample -and $samples.Count -lt 4000 -and ($samples.Count -eq 0 -or $sample.seq -gt $samples[$samples.Count - 1].seq)) { $samples.Add($sample) }
                $row = $null
            }
            $now = [AZSGRemoteGame]::Wall()
            if ($samples.Count -gt 0) {
                $latest = $samples[$samples.Count - 1]
                if ($latest.phase -ceq 'playing' -and $null -eq $firstPlayingAt) { $firstPlayingAt = $now }
                if ($latest.stage -eq 5) { $reason = 'observed'; break }
                if ($latest.phase -ceq 'choosing' -and ($now - $lastChoice) / 1e7 -gt 1) { $inputOkay = $session.Tap(0x31) -and $inputOkay; $lastChoice = $now }
                $desiredKey = 0
                if ($latest.phase -ceq 'playing' -and $latest.stage -in @(2,4)) {
                    if ($moveStage -ne $latest.stage) { $moveStage = $latest.stage; $moveStart = $now }
                    $desiredKey = if (($now - $moveStart) / 1e7 -lt 3) { 0x57 } else { 0x53 }
                }
                if ($desiredKey -ne $movementKey) {
                    if ($movementKey -ne 0) { $inputOkay = $session.Key([uint16]$movementKey, $false) -and $inputOkay }
                    $movementKey = $desiredKey
                    if ($movementKey -ne 0) { $inputOkay = $session.Key([uint16]$movementKey, $true) -and $inputOkay }
                }
            }
            if ($null -eq $firstPlayingAt -and ($now - $start) / 1e7 -gt 5 -and ($now - $lastEnter) / 1e7 -gt 5) {
                # Enter selects Play in the picker. Once the scene reports ready,
                # movement starts the run; Enter there can instead open chat.
                if ($samples.Count -eq 0 -or $samples[$samples.Count - 1].phase -ceq 'unknown') { $inputOkay = $session.Tap(0x0d) -and $inputOkay }
                $inputOkay = $session.Key(0x57, $true) -and $inputOkay
                Start-Sleep -Milliseconds 1500
                $inputOkay = $session.Key(0x57, $false) -and $inputOkay
                $lastEnter = $now
            }
            if ($null -eq $firstPlayingAt -and ($now - $start) / 1e7 -gt 90) { break }
            if (-not $inputOkay) { $reason = 'blocked_input_or_foreground'; break }
            Start-Sleep -Milliseconds 50
        }
        return [pscustomobject]@{ mode = $Mode; status = $reason; softwareAdapterObserved = $session.SoftwareObserved
            processExitCode = $(if ($session.Child.HasExited) { $session.Child.ExitCode } else { $null })
            gpuFailure = $session.GpuFailure; panicked = $session.Panicked; droppedTelemetry = $session.Dropped; samples = $samples.ToArray() }
    } finally {
        $session.Dispose()
        # Windows Known Folder APIs may ignore APPDATA environment overrides.
        # These exact directories were absent before this disposable job, so
        # retain only game-created state in RUNNER_TEMP between fresh runs.
        $index = 0
        foreach ($path in $script:knownGameStatePaths) {
            if (Test-Path -LiteralPath $path) {
                $index++
                if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'blocked_runner_state_link' }
                $destination = [IO.Path]::GetFullPath((Join-Path $GameRoot ('KnownFolderState-' + $index)))
                if (-not $destination.StartsWith($script:fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'blocked_runner_state_path' }
                Move-Item -LiteralPath $path -Destination $destination
            }
        }
    }
}

function Get-StageMetrics($Run, [int]$Stage) {
    $all = @($Run.samples | Where-Object { $_.stage -eq $Stage })
    if ($all.Count -eq 0) { return $null }
    # Give command delivery and transition effects two external, unhooked
    # seconds to settle before any measured window begins.
    $cutoff = $all[0].fileTime + 20000000L
    $all = @($all | Where-Object { $_.fileTime -ge $cutoff })
    $rows = @($all | Where-Object { $_.phase -ceq 'playing' -and $_.rawT -ge 0 })
    if ($rows.Count -lt 8 -or $rows.Count -ne $all.Count) { return $null }
    if ($Run.mode -ceq 'hooked' -and @($rows | Where-Object { $_.requestAccepted -ne 1 }).Count -gt 0) { return $null }
    $span = ($rows[-1].fileTime - $rows[0].fileTime) / 1e7
    if ($span -lt 3) { return $null }
    [double]$distance = 0; [double]$decay = 0; [double]$decaySpan = 0; [double]$maxGap = 0
    $validMap = $true; $validSpell = $true
    $lastPacket = $rows[0]
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $a = $rows[$i - 1]; $b = $rows[$i]; $dt = ($b.fileTime - $a.fileTime) / 1e7
        if ($dt -le 0) { continue }; $maxGap = [Math]::Max($maxGap, $dt)
        if ($a.mapX -lt 0 -or $a.mapY -lt 0 -or $b.mapX -lt 0 -or $b.mapY -lt 0 -or
            $a.mapContinent -ne $b.mapContinent -or $a.mapZone -ne $b.mapZone) { $validMap = $false }
        else { $distance += [Math]::Sqrt([Math]::Pow($b.mapX-$a.mapX,2) + [Math]::Pow($b.mapY-$a.mapY,2)) }
        if ($a.spellId -le 0 -or $a.spellId -ne $b.spellId -or $a.cdmax -ne $b.cdmax) { $validSpell = $false }
        if ($b.spellPackets -gt $lastPacket.spellPackets) {
            # Denominator spans distinct server snapshots, including intervening
            # UI samples. Otherwise a faster UI alone could inflate the result.
            $packetSpan = ($b.fileTime - $lastPacket.fileTime) / 1e7
            if ($packetSpan -gt 0 -and $lastPacket.spellId -eq $b.spellId -and
                $lastPacket.cdmax -eq $b.cdmax -and $lastPacket.cd -gt $b.cd -and $b.cd -ge 0) {
                $decay += $lastPacket.cd - $b.cd
                $decaySpan += $packetSpan
            }
            $lastPacket = $b
        }
    }
    return [pscustomobject]@{ count = $rows.Count; externalSeconds = $span; maxSampleGapSeconds = $maxGap
        rawRunRate = ($rows[-1].rawT-$rows[0].rawT)/$span; clientTimeRate = ($rows[-1].getTime-$rows[0].getTime)/$span
        mapUvRate = $(if ($validMap) { $distance/$span } else { $null })
        cooldownDecayRate = $(if ($validSpell -and $decaySpan -ge 1) { $decay/$decaySpan } else { $null })
        cooldownResets = $rows[-1].cooldownResets-$rows[0].cooldownResets
        selfDamageEvents = $rows[-1].selfDamageEvents-$rows[0].selfDamageEvents
        spellcastStopEvents = $rows[-1].spellcastStopEvents-$rows[0].spellcastStopEvents }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    Add-Type -TypeDefinition $hostSource
    $report.candidateDllSha256 = (Get-FileHash -LiteralPath (Join-Path $package 'Native\dwmapi.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    $packageToc = [IO.File]::ReadAllText((Join-Path $package 'AddOns\AZSSpeedGear\AZSSpeedGear.toc'), $utf8)
    $report.pluginVersion = [regex]::Match($packageToc, '(?m)^## Version: ([0-9]+\.[0-9]+\.[0-9]+)\r?$').Groups[1].Value
    $script:knownGameStatePaths = @()
    foreach ($folder in @([Environment+SpecialFolder]::ApplicationData, [Environment+SpecialFolder]::LocalApplicationData)) {
        $known = [IO.Path]::GetFullPath([Environment]::GetFolderPath($folder)).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($known)) { throw 'blocked_runner_state_path' }
        $path = [IO.Path]::GetFullPath((Join-Path $known 'wenilla-rogue'))
        if (-not $path.StartsWith($known + '\', [StringComparison]::OrdinalIgnoreCase) -or
            (Test-Path -LiteralPath $path)) { throw 'blocked_existing_runner_game_state' }
        $script:knownGameStatePaths += $path
    }
    $report.phase = 'download'
    $identity = Get-OfficialGame
    $report.gameVersion = $identity.version; $report.gameSha256 = $identity.sha256
    $report.gameBytes = $identity.size; $report.officialAssetsSha256 = $identity.assetsSha256
    $report.phase = 'assets'
    $assets = Expand-OnlyOfficialAssets (Join-Path $fixtureRoot 'assets')
    $officialExe = Join-Path $fixtureRoot 'official-game.exe'
    foreach ($mode in @('baseline','hooked')) {
        $report.phase = $mode
        $run = Invoke-GameRun $mode (Join-Path $fixtureRoot $mode) $assets $officialExe
        $report.runs += $run
        if ($run.status -cne 'observed') { throw $run.status }
        if (-not $run.softwareAdapterObserved) { throw 'blocked_unconfirmed_software_adapter' }
        if ($run.droppedTelemetry -gt 0) { throw 'blocked_telemetry_backpressure' }
    }
    $report.phase = 'metrics'
    $base = Get-StageMetrics $report.runs[0] 1
    $one = Get-StageMetrics $report.runs[1] 1
    $two = Get-StageMetrics $report.runs[1] 3
    $moveOne = Get-StageMetrics $report.runs[1] 2
    $moveTwo = Get-StageMetrics $report.runs[1] 4
    $report.metrics = [ordered]@{ unhooked = $base; hooked1x = $one; hooked2x = $two; movement1x = $moveOne; movement2x = $moveTwo }
    foreach ($name in $report.metrics.Keys) { if ($null -eq $report.metrics[$name]) { $report.missingEvidence += $name } }
    if ($report.missingEvidence.Count -gt 0) { throw 'blocked_incomplete_playing_windows' }
    if (@($base,$one,$two,$moveOne,$moveTwo | Where-Object { $_.maxSampleGapSeconds -gt 1 }).Count -gt 0) { throw 'blocked_software_rendering_cadence' }
    if ($null -eq $moveOne.mapUvRate -or $moveOne.mapUvRate -lt 0.00001) { $report.missingEvidence += 'movement1x.mapUvRate' }
    if ($null -eq $moveTwo.mapUvRate -or $moveTwo.mapUvRate -lt 0.00001) { $report.missingEvidence += 'movement2x.mapUvRate' }
    if ($null -eq $one.cooldownDecayRate -or $one.cooldownDecayRate -le 0) { $report.missingEvidence += 'hooked1x.cooldownDecayRate' }
    if ($null -eq $two.cooldownDecayRate -or $two.cooldownDecayRate -le 0) { $report.missingEvidence += 'hooked2x.cooldownDecayRate' }
    if ($one.selfDamageEvents -le 0) { $report.missingEvidence += 'hooked1x.selfDamageEvents' }
    if ($two.selfDamageEvents -le 0) { $report.missingEvidence += 'hooked2x.selfDamageEvents' }
    if ($report.missingEvidence.Count -gt 0) { throw 'blocked_missing_movement_or_combat_evidence' }
    $timerRatio = if ($one.rawRunRate -gt 0) { $two.rawRunRate/$one.rawRunRate } else { 0 }
    $movementRatio = $moveTwo.mapUvRate/$moveOne.mapUvRate
    $cooldownRatio = $two.cooldownDecayRate/$one.cooldownDecayRate
    $report.criteria = @(
        [pscustomobject]@{ name='unhooked_server_clock'; observed=$base.rawRunRate; minimum=0.75; maximum=1.25; passed=($base.rawRunRate -ge 0.75 -and $base.rawRunRate -le 1.25) },
        [pscustomobject]@{ name='hooked_1x_server_clock'; observed=$one.rawRunRate; minimum=0.75; maximum=1.25; passed=($one.rawRunRate -ge 0.75 -and $one.rawRunRate -le 1.25) },
        [pscustomobject]@{ name='2x_server_clock_ratio'; observed=$timerRatio; minimum=1.6; maximum=2.4; passed=($timerRatio -ge 1.6 -and $timerRatio -le 2.4) },
        [pscustomobject]@{ name='2x_map_uv_movement_ratio'; observed=$movementRatio; minimum=1.4; maximum=2.6; passed=($movementRatio -ge 1.4 -and $movementRatio -le 2.6) },
        [pscustomobject]@{ name='2x_raw_cooldown_decay_ratio'; observed=$cooldownRatio; minimum=1.4; maximum=2.6; passed=($cooldownRatio -ge 1.4 -and $cooldownRatio -le 2.6) }
    )
    $failed = @($report.criteria | Where-Object { -not $_.passed })
    $report.status = if ($failed.Count) { 'failed' } else { 'passed' }
    $report.reason = if ($failed.Count) { 'observed_metrics_outside_declared_bounds' } else { 'declared_timer_movement_and_cooldown_metrics_observed_on_this_runner' }
    $exitCode = if ($failed.Count) { 1 } else { 0 }
} catch {
    # Never copy exception text or the game log: either may contain asset data
    # or private paths. Publish only fixed diagnostic categories.
    $reason = [string]$_.Exception.Message
    $report.exceptionType = $_.Exception.GetType().FullName
    $report.reason = if ($reason -cmatch '^blocked_[a-z_]{1,80}$') { $reason } else { 'blocked_harness_or_environment' }
    $report.status = 'blocked'; $exitCode = 2
} finally {
    # Keep only this report outside RUNNER_TEMP. Hosted-runner teardown removes
    # all downloaded files, process-created settings and unredistributed assets.
    Write-Text $output ($report | ConvertTo-Json -Depth 9)
}
Write-Output ($report | Select-Object schema,product,status,reason,gameVersion | ConvertTo-Json -Compress)
exit $exitCode

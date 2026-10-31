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
$report = [ordered]@{ schema = 1; product = 'AzerothSurvivorsSpeedGear'; status = 'blocked'; reason = 'not_started'; phase = 'initialized'; exceptionType = $null; downloadDiagnostic = $null
    checkedUtc = [DateTime]::UtcNow.ToString('o'); sourceCommit = $null; ciRunId = $env:GITHUB_RUN_ID; workflowRepository = $env:GITHUB_REPOSITORY
    gameVersion = $null; gameSha256 = $null; gameBytes = $null; officialAssetsSha256 = $null; candidateDllSha256 = $null; pluginVersion = $null
    gameSource = 'official_download'; privateBundleSha256 = $null; privateBundleBytes = $null
    runtimeProfile = 'system'; runtimeFiles = @()
    machine = [ordered]@{ logicalProcessors = $null; totalPhysicalMemoryBytes = $null }
    startupSeconds = 90
    viewport = '640x480'
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

function Initialize-RemoteRuntime {
    $script:runtimeDllSources = @()
    if ([string]::IsNullOrWhiteSpace($env:AZSG_REMOTE_RUNTIME_DLL_DIR)) { return }
    $directory = [IO.Path]::GetFullPath($env:AZSG_REMOTE_RUNTIME_DLL_DIR).TrimEnd('\')
    if (-not $directory.StartsWith($script:temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'blocked_runtime_profile_path' }
    $relative = $directory.Substring($script:temporaryRoot.Length + 1)
    if (@($relative.Split('\') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_ -match '[. ]$' }).Count) { throw 'blocked_runtime_profile_path' }
    $cursor = Get-Item -LiteralPath $directory -Force
    while (-not $cursor.FullName.TrimEnd('\').Equals($script:temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -eq $cursor.Parent) { throw 'blocked_runtime_profile_link' }
        $cursor = $cursor.Parent
    }
    if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'blocked_runtime_profile_link' }
    foreach ($name in @('dxcompiler.dll', 'dxil.dll', 'd3d10warp.dll')) {
        $path = Join-Path $directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'blocked_runtime_profile_file' }
        $file = Get-Item -LiteralPath $path -Force
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -le 0) { throw 'blocked_runtime_profile_link' }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:runtimeDllSources += [pscustomobject]@{ name = $name; path = $file.FullName; sha256 = $hash }
        $script:report.runtimeFiles += [pscustomobject]@{ name = $name; bytes = $file.Length; sha256 = $hash }
    }
    # These identify app-local staged files, not proof of module loading.
    $script:report.runtimeProfile = 'updated_warp'
}

function Get-OfficialGame {
    # Reuse the bounded, same-origin, SHA/size-verified latest-EXE downloader.
    # The historical RAR supplies only MPQ assets; its old EXE is never executed.
    $python = @'
import hashlib,json,os,re,sys,threading,time
from http.client import HTTPException
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import build_opener,HTTPRedirectHandler,Request
from urllib.error import HTTPError,URLError
stage='import_monitor'; identity=None; total=0
attempts=0; resumes=0; restarts=0; expected_total=None; watchdog=None
emit_lock=threading.Lock(); emitted=False
def emit_result(value):
    global emitted
    with emit_lock:
        if emitted: return False
        emitted=True
        print(json.dumps(value),flush=True)
        return True
def download_deadline():
    diagnostic={'stage':'assets_download','category':'timeout','exceptionType':'TimeoutError','causeTypes':['TimeoutError'],'httpStatus':None,'assetsBytes':total,'assetsAttempts':attempts,'rangeResumes':resumes,'rangeRestarts':restarts,'expectedAssetsBytes':expected_total}
    if emit_result({'ok':False,'identity':identity,'diagnostic':diagnostic}): os._exit(2)
try:
    sys.path.insert(0,str(Path(sys.argv[1])/'tools'))
    import check_game_compatibility as m
    root=Path(sys.argv[2])
    opener=build_opener(m.OfficialRedirects())
    stage='manifest_fetch'
    manifest=m.fetch_manifest(opener)
    identity={'version':manifest['version'],'sha256':manifest['sha256'],'size':manifest['size'],'assetsSha256':None}
    stage='exe_download'
    exe=m.download_exe(manifest,root,opener)
    url='https://wow.aethus.pl/download/AzerothSurvivorsWindowsNew.rar'
    class AssetPolicyError(ValueError): pass
    class RarRedirect(HTTPRedirectHandler):
        def redirect_request(self,req,fp,code,msg,headers,newurl):
            p=urlsplit(newurl)
            if p.scheme!='https' or p.hostname!='wow.aethus.pl' or p.port not in (None,443) or p.path!='/download/AzerothSurvivorsWindowsNew.rar' or p.query or p.fragment or p.username or p.password:
                raise AssetPolicyError('redirect_policy')
            return super().redirect_request(req,fp,code,msg,headers,newurl)
    digest=hashlib.sha256(); deadline=time.monotonic()+600; validator=None
    maximum=1024*1024*1024; archive=root/'official-assets.rar'
    # A blocked read may otherwise exceed the overall deadline by its socket
    # timeout. The watchdog emits only safe JSON, then ends this downloader.
    watchdog=threading.Timer(600,download_deadline); watchdog.daemon=True; watchdog.start()
    complete=False
    for attempt in range(1,4):
        attempts=attempt
        requested=total
        headers={'Accept-Encoding':'identity','User-Agent':m.PRODUCT+'-remote-acceptance/1','Range':f'bytes={requested}-'}
        if requested and validator: headers['If-Range']=validator
        try:
            stage='assets_open'
            remaining=deadline-time.monotonic()
            if remaining<=0: raise TimeoutError('download_deadline')
            with build_opener(RarRedirect()).open(Request(url,headers=headers),timeout=min(90,remaining)) as r:
                if r.geturl()!=url: raise AssetPolicyError('final_url_policy')
                if r.headers.get('Content-Encoding','identity').lower()!='identity': raise AssetPolicyError('content_encoding')
                status=r.status; content_range=r.headers.get('Content-Range'); length=r.headers.get('Content-Length')
                if length is not None and re.fullmatch(r'[0-9]+',length) is None: raise AssetPolicyError('content_length')
                declared=int(length) if length is not None else None
                etag=r.headers.get('ETag')
                current_validator=etag if etag and not etag.startswith('W/') else r.headers.get('Last-Modified')
                if status==206:
                    span=re.fullmatch(r'bytes ([0-9]+)-([0-9]+)/([0-9]+)',content_range or '')
                    if span is None: raise AssetPolicyError('content_range')
                    start,end,full=map(int,span.groups())
                    if start!=requested or not 0<=start<=end<full<=maximum: raise AssetPolicyError('range_bounds')
                    if expected_total is not None and full!=expected_total: raise AssetPolicyError('range_total_changed')
                    if validator and current_validator and validator!=current_validator: raise AssetPolicyError('range_identity_changed')
                    response_bytes=end-start+1
                    if declared is not None and declared!=response_bytes: raise AssetPolicyError('range_length')
                    expected_total=full
                    if requested: resumes+=1
                    mode='ab' if requested else 'wb'
                elif status==200:
                    if content_range is not None: raise AssetPolicyError('unexpected_content_range')
                    if declared is not None and not 1<=declared<=maximum: raise AssetPolicyError('content_length_bounds')
                    # A server may ignore Range or fail If-Range. Its full body
                    # can only restart at offset zero; never append a 200 body.
                    if requested: restarts+=1
                    total=0; digest=hashlib.sha256(); expected_total=declared
                    response_bytes=declared; mode='wb'
                else: raise AssetPolicyError('unexpected_response_status')
                validator=current_validator
                stage='assets_download'; received=0
                with archive.open(mode) as f:
                    while response_bytes is None or received<response_bytes:
                        if time.monotonic()>=deadline: raise TimeoutError('download_deadline')
                        capacity=65536 if response_bytes is None else min(65536,response_bytes-received)
                        chunk=getattr(r,'read1',r.read)(capacity)
                        if not chunk: break
                        if total+len(chunk)>maximum: raise m.IntegrityError('asset_size_limit')
                        f.write(chunk); digest.update(chunk); total+=len(chunk); received+=len(chunk)
                if response_bytes is not None and received!=response_bytes: raise ConnectionError('incomplete_response')
                if expected_total is None or total==expected_total: complete=True; break
                # A valid shorter 206 segment may need one further range.
                if total>expected_total: raise AssetPolicyError('response_exceeds_total')
                if attempt==3: raise ConnectionError('incomplete_archive')
        except (TimeoutError,URLError,ConnectionError,HTTPException) as retry_error:
            if isinstance(retry_error,HTTPError) and retry_error.code not in (408,429,500,502,503,504): raise
            if attempt==3 or time.monotonic()>=deadline: raise
            time.sleep(min(2*attempt,max(0,deadline-time.monotonic())))
    if not complete or total<=0 or (expected_total is not None and total!=expected_total): raise m.IntegrityError('incomplete_archive')
    watchdog.cancel()
    identity['assetsSha256']=digest.hexdigest()
    emit_result({'ok':True,'identity':identity,'diagnostic':{'stage':'complete','category':'none','exceptionType':None,'causeTypes':[],'httpStatus':None,'assetsBytes':total,'assetsAttempts':attempts,'rangeResumes':resumes,'rangeRestarts':restarts,'expectedAssetsBytes':expected_total}})
except Exception as error:
    if watchdog is not None: watchdog.cancel()
    # No exception messages, URLs, tracebacks, response bodies or local paths.
    # Preserve wrapped HTTP causes from the existing monitor, at most 8 nodes.
    pending=[error]; seen=set(); types=[]; status=None
    while pending and len(seen)<8:
        node=pending.pop(0)
        if id(node) in seen: continue
        seen.add(id(node)); name=type(node).__name__[:64]
        if name not in types: types.append(name)
        if isinstance(node,HTTPError) and isinstance(node.code,int) and 100<=node.code<=599: status=node.code
        for nested in (node.__cause__,node.__context__,getattr(node,'reason',None)):
            if isinstance(nested,BaseException): pending.append(nested)
    category='unexpected'
    if status is not None: category='http'
    elif any('SSL' in name or 'Certificate' in name for name in types): category='tls'
    elif any('Timeout' in name for name in types): category='timeout'
    elif any(name in ('IntegrityError','BadGzipFile') for name in types): category='integrity'
    elif 'ManifestError' in types: category='manifest'
    elif 'AssetPolicyError' in types: category='origin_policy'
    elif any(name in ('PermissionError','FileNotFoundError','IsADirectoryError') for name in types): category='filesystem'
    elif any(name in ('URLError','OSError','ConnectionError','ConnectionResetError') for name in types): category='network'
    emit_result({'ok':False,'identity':identity,'diagnostic':{'stage':stage,'category':category,'exceptionType':type(error).__name__[:64],'causeTypes':types,'httpStatus':status,'assetsBytes':total,'assetsAttempts':attempts,'rangeResumes':resumes,'rangeRestarts':restarts,'expectedAssetsBytes':expected_total}})
    sys.exit(2)
'@
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& python -c $python $script:projectRoot $script:fixtureRoot 2>$null)
    $pythonExit = $LASTEXITCODE
    $script:report.downloadDiagnostic = [ordered]@{ stage = 'python_host'; category = 'no_bounded_json'; pythonExitCode = $pythonExit }
    if ($lines.Count -ne 1 -or ([string]$lines[0]).Length -gt 2048) { throw 'blocked_download' }
    try { $result = $lines[0] | ConvertFrom-Json } catch { throw 'blocked_download' }
    if ($null -eq $result.PSObject.Properties['ok'] -or $result.ok -isnot [bool] -or
        $null -eq $result.PSObject.Properties['diagnostic']) { throw 'blocked_download' }
    $script:report.downloadDiagnostic = $result.diagnostic
    $script:report.downloadDiagnostic | Add-Member -NotePropertyName pythonExitCode -NotePropertyValue $pythonExit
    if ($null -ne $result.identity) {
        $script:report.gameVersion = $result.identity.version
        $script:report.gameSha256 = $result.identity.sha256
        $script:report.gameBytes = $result.identity.size
    }
    if ($pythonExit -ne 0 -or -not $result.ok) { throw 'blocked_download' }
    return $result.identity
}

function Get-PrivateGameBundle {
    # A private repository may download its own asset with its scoped job token
    # and pass the RUNNER_TEMP file path. An optional URL is a short-lived secret;
    # never put it in an argument, report, exception message or console output.
    $python = @'
import hashlib,json,os,re,stat,sys,threading,time,zipfile
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import build_opener,HTTPRedirectHandler,Request
from urllib.error import HTTPError,URLError
stage='private_bundle_metadata'; total=0; attempts=0; identity=None
emitted=False; emit_lock=threading.Lock(); watchdog=None
def emit(value):
    global emitted
    with emit_lock:
        if emitted: return False
        emitted=True; print(json.dumps(value),flush=True); return True
def diagnostic(category,error=None,http=None):
    return {'stage':stage,'category':category,'exceptionType':type(error).__name__[:64] if error else 'TimeoutError','httpStatus':http,'bundleBytesReceived':total,'bundleAttempts':attempts}
def expired():
    if emit({'ok':False,'identity':identity,'diagnostic':diagnostic('timeout')}): os._exit(2)
class BundlePolicyError(ValueError): pass
def checked_url(value):
    p=urlsplit(value)
    if len(value)>16384 or p.scheme!='https' or p.hostname not in ('release-assets.githubusercontent.com','objects.githubusercontent.com') or p.port not in (None,443) or p.username or p.password or p.fragment or not p.path.startswith('/'):
        raise BundlePolicyError('URL policy')
    return value
class BundleRedirects(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        return super().redirect_request(req,fp,code,msg,headers,checked_url(newurl))
def pairs(values):
    result={}
    for key,value in values:
        if key in result: raise BundlePolicyError('duplicate JSON key')
        result[key]=value
    return result
def integer(value,minimum,maximum):
    return type(value) is int and minimum<=value<=maximum
def game_file(value):
    return type(value) is str and (value=='AzerothSurvivors.exe' or re.fullmatch(r'Data/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.mpq',value,re.I) is not None)
try:
    maximum=4*1024*1024*1024; maximum_bundle=2*1024*1024*1024-1
    expected=os.environ.get('AZSG_GAME_BUNDLE_SHA256','')
    byte_text=os.environ.get('AZSG_GAME_BUNDLE_BYTES','')
    if re.fullmatch(r'[a-f0-9]{64}',expected) is None or re.fullmatch(r'[0-9]{1,10}',byte_text) is None: raise BundlePolicyError('missing bundle identity')
    expected_bytes=int(byte_text)
    if not 1<=expected_bytes<=maximum_bundle: raise BundlePolicyError('bundle byte limit')
    root=Path(sys.argv[1]); archive=root/'private-game-bundle.zip'
    deadline=time.monotonic()+600
    watchdog=threading.Timer(600,expired); watchdog.daemon=True; watchdog.start()
    local=os.environ.get('AZSG_GAME_BUNDLE_PATH','')
    if local:
        stage='private_bundle_local_verify'
        supplied=Path(local).absolute(); temporary=Path(os.environ['RUNNER_TEMP']).resolve()
        archive=supplied.resolve()
        if not archive.is_relative_to(temporary) or not archive.is_file(): raise BundlePolicyError('local bundle outside temporary root')
        cursor=supplied
        while cursor!=temporary:
            if cursor.is_symlink() or cursor.is_junction(): raise BundlePolicyError('linked local bundle')
            if cursor.parent==cursor: raise BundlePolicyError('local bundle ancestry')
            cursor=cursor.parent
        if archive.stat().st_size!=expected_bytes: raise BundlePolicyError('local bundle size')
        digest=hashlib.sha256()
        with archive.open('rb') as incoming:
            while True:
                if time.monotonic()>=deadline: raise TimeoutError('deadline')
                chunk=incoming.read(65536)
                if not chunk: break
                total+=len(chunk)
                if total>expected_bytes: raise BundlePolicyError('excess local bundle')
                digest.update(chunk)
        if total!=expected_bytes or digest.hexdigest()!=expected: raise BundlePolicyError('local archive digest')
    else:
        url=checked_url(os.environ.get('AZSG_GAME_BUNDLE_URL',''))
        opener=build_opener(BundleRedirects())
        for attempt in range(1,4):
            attempts=attempt; total=0; digest=hashlib.sha256()
            try:
                stage='private_bundle_download'
                remaining=deadline-time.monotonic()
                if remaining<=0: raise TimeoutError('deadline')
                request=Request(url,headers={'Accept-Encoding':'identity','User-Agent':'AzerothSurvivorsSpeedGear-private-acceptance/1'})
                with opener.open(request,timeout=min(45,remaining)) as response,archive.open('wb') as output:
                    checked_url(response.geturl())
                    if response.status!=200 or response.headers.get('Content-Encoding','identity').lower()!='identity': raise BundlePolicyError('response policy')
                    declared=response.headers.get('Content-Length')
                    if declared is not None and (re.fullmatch(r'[0-9]+',declared) is None or int(declared)!=expected_bytes): raise BundlePolicyError('response size')
                    read=getattr(response,'read1',response.read)
                    while True:
                        if time.monotonic()>=deadline: raise TimeoutError('deadline')
                        chunk=read(65536)
                        if not chunk: break
                        total+=len(chunk)
                        if total>expected_bytes: raise BundlePolicyError('excess response')
                        digest.update(chunk); output.write(chunk)
                if total!=expected_bytes: raise ConnectionError('incomplete response')
                if digest.hexdigest()!=expected: raise BundlePolicyError('archive digest')
                break
            except (TimeoutError,URLError,ConnectionError) as error:
                if isinstance(error,HTTPError) and error.code not in (408,429,500,502,503,504): raise
                if attempt==3 or time.monotonic()>=deadline: raise
                time.sleep(min(2*attempt,max(0,deadline-time.monotonic())))
    stage='private_bundle_extract'
    destination=root/'private-bundle'; destination.mkdir()
    with zipfile.ZipFile(archive) as source:
        entries={}; seen=set(); expanded=0
        for entry in source.infolist():
            name=entry.filename
            if name.lower() in seen or entry.flag_bits&1: raise BundlePolicyError('duplicate or encrypted entry')
            seen.add(name.lower())
            kind=stat.S_IFMT(entry.external_attr>>16)
            if kind not in (0,stat.S_IFREG,stat.S_IFDIR) or entry.external_attr&0x400: raise BundlePolicyError('linked entry')
            if entry.is_dir():
                if name!='Data/' or entry.file_size!=0: raise BundlePolicyError('directory entry')
                continue
            if kind==stat.S_IFDIR or (name!='bundle.json' and not game_file(name)): raise BundlePolicyError('entry path')
            if entry.file_size<0 or entry.file_size>maximum: raise BundlePolicyError('entry size')
            expanded+=entry.file_size
            if expanded>maximum or len(entries)>=130: raise BundlePolicyError('expanded bounds')
            entries[name]=entry
        if 'bundle.json' not in entries or entries['bundle.json'].file_size>65536: raise BundlePolicyError('manifest bounds')
        manifest=json.loads(source.read(entries['bundle.json']).decode('utf-8-sig'),object_pairs_hook=pairs,parse_constant=lambda value: (_ for _ in ()).throw(BundlePolicyError('nonfinite JSON')))
        allowed_keys={'schema','product','gameVersion','gameSha256','gameBytes','files','createdUtc'}
        if type(manifest) is not dict or not set(manifest)<=allowed_keys or type(manifest.get('schema')) is not int or manifest.get('schema')!=1 or manifest.get('product')!='AzerothSurvivorsPrivateTestBundle': raise BundlePolicyError('manifest identity')
        version=manifest.get('gameVersion'); game_sha=manifest.get('gameSha256'); game_bytes=manifest.get('gameBytes'); files=manifest.get('files')
        if type(version) is not str or re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version) is None or type(game_sha) is not str or re.fullmatch(r'[a-f0-9]{64}',game_sha) is None or not integer(game_bytes,1,512*1024*1024): raise BundlePolicyError('game identity')
        if type(files) is not list or not 2<=len(files)<=129: raise BundlePolicyError('manifest file count')
        expected_files={}
        for item in files:
            if type(item) is not dict or set(item)!=set(('path','bytes','sha256')): raise BundlePolicyError('manifest entry shape')
            name=item['path']; size=item['bytes']; sha=item['sha256']
            if not game_file(name) or name in expected_files or not integer(size,1,maximum) or type(sha) is not str or re.fullmatch(r'[a-f0-9]{64}',sha) is None: raise BundlePolicyError('manifest file identity')
            expected_files[name]=(size,sha)
        if set(expected_files)!=set(entries)-{'bundle.json'} or expected_files.get('AzerothSurvivors.exe')!=(game_bytes,game_sha): raise BundlePolicyError('exact manifest file set')
        for name,(size,sha) in expected_files.items():
            entry=entries[name]
            if entry.file_size!=size: raise BundlePolicyError('ZIP entry size')
            target=destination.joinpath(*name.split('/')); target.parent.mkdir(parents=True,exist_ok=True)
            actual=hashlib.sha256(); count=0
            with source.open(entry) as incoming,target.open('xb') as outgoing:
                while True:
                    if time.monotonic()>=deadline: raise TimeoutError('deadline')
                    chunk=incoming.read(65536)
                    if not chunk: break
                    count+=len(chunk)
                    if count>size: raise BundlePolicyError('expanded file bounds')
                    actual.update(chunk); outgoing.write(chunk)
            if count!=size or actual.hexdigest()!=sha: raise BundlePolicyError('expanded file digest')
        if not any(name.startswith('Data/') for name in expected_files): raise BundlePolicyError('missing MPQs')
    identity={'version':version,'sha256':game_sha,'size':game_bytes,'assetsSha256':None,'bundleSha256':expected,'bundleBytes':expected_bytes}
    watchdog.cancel()
    emit({'ok':True,'identity':identity,'diagnostic':{'stage':'complete','category':'none','exceptionType':None,'httpStatus':None,'bundleBytesReceived':total,'bundleAttempts':attempts,'fileCount':len(expected_files)}})
except Exception as error:
    if watchdog is not None: watchdog.cancel()
    status=error.code if isinstance(error,HTTPError) and 100<=error.code<=599 else None
    category='timeout' if isinstance(error,TimeoutError) else 'http' if status is not None else 'network' if isinstance(error,(URLError,ConnectionError)) else 'integrity' if isinstance(error,(BundlePolicyError,zipfile.BadZipFile)) else 'unexpected'
    emit({'ok':False,'identity':identity,'diagnostic':diagnostic(category,error,status)})
    sys.exit(2)
'@
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& python -c $python $script:fixtureRoot 2>$null)
    $pythonExit = $LASTEXITCODE
    $script:report.downloadDiagnostic = [ordered]@{ stage = 'private_bundle_host'; category = 'no_bounded_json'; pythonExitCode = $pythonExit }
    if ($lines.Count -ne 1 -or ([string]$lines[0]).Length -gt 2048) { throw 'blocked_private_bundle' }
    try { $result = $lines[0] | ConvertFrom-Json } catch { throw 'blocked_private_bundle' }
    if ($null -eq $result.PSObject.Properties['ok'] -or $result.ok -isnot [bool] -or
        $null -eq $result.PSObject.Properties['diagnostic']) { throw 'blocked_private_bundle' }
    $script:report.downloadDiagnostic = $result.diagnostic
    $script:report.downloadDiagnostic | Add-Member -NotePropertyName pythonExitCode -NotePropertyValue $pythonExit
    if ($pythonExit -ne 0 -or -not $result.ok) { throw 'blocked_private_bundle' }
    return $result.identity
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

# Callbacks publish only our numeric protocol and fixed startup categories by
# default. A private diagnostic run can opt into four bounded, redacted panic
# lines; whole logs are never retained. This process is not time-hooked.
$hostSource = @'
using System;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
public sealed class AZSGRemoteRow { public long FileTime; public string Payload; }
public sealed class AZSGLoadingSnapshot {
  public long observedFileTime,ready,total,placementsPending,collidersPending,mergesPending;
  public double seconds; public bool awaitingSnap,settling,warm,uiPending;
}
public sealed class AZSGRemoteGame : IDisposable {
  public readonly ConcurrentQueue<AZSGRemoteRow> Rows = new ConcurrentQueue<AZSGRemoteRow>();
  public Process Child; public bool GpuFailure, Panicked, SoftwareObserved; public int Dropped;
  readonly bool capturePanic=Environment.GetEnvironmentVariable("AZSG_CAPTURE_PANIC")=="1";
  readonly object panicLock=new object();
  readonly List<string> panicExcerpt=new List<string>();
  readonly ConcurrentDictionary<string,byte> startupCategories=new ConcurrentDictionary<string,byte>();
  bool panicStarted; int panicRemaining;
  readonly object loadingLock=new object(); readonly List<AZSGLoadingSnapshot> loadingSnapshots=new List<AZSGLoadingSnapshot>();
  bool loadingKnown,loadingWaiting,warmTimedOut; int loadingClears; long? warmPending;
  static readonly Regex loadingWaitPattern=new Regex(@"loading screen: waiting (?<seconds>[0-9]{1,9}(?:\.[0-9]{1,3})?)s\s+(?:\u2014|-)\s+(?<ready>[0-9]{1,10})/(?<total>[0-9]{1,10}) resident,\s*(?<placements>[0-9]{1,10}) placements pending,\s*(?<colliders>[0-9]{1,10}) colliders pending,\s*(?<merges>[0-9]{1,10}) merges pending,\s*awaiting_snap=(?<snap>true|false),\s*settling=(?<settling>true|false),\s*warm=(?<warm>true|false),\s*ui_pending=(?<ui>true|false)");
  static readonly Regex loadingClearPattern=new Regex(@"loading screen: cleared \((?<ready>[0-9]{1,10})/(?<total>[0-9]{1,10}) resident, (?<seconds>[0-9]{1,9}(?:\.[0-9]{1,3})?)s\)");
  static readonly Regex warmTimeoutPattern=new Regex(@"pipeline warm: TIMED OUT with (?<pending>[0-9]{1,10}) pipelines pending");
  public bool PanicCaptureEnabled { get { return capturePanic; } }
  public string[] PanicExcerpt { get { lock(panicLock) { return panicExcerpt.ToArray(); } } }
  public string[] StartupCategories { get { var values=new List<string>(startupCategories.Keys); values.Sort(StringComparer.Ordinal); return values.ToArray(); } }
  public AZSGLoadingSnapshot[] LoadingSnapshots { get { lock(loadingLock) { return loadingSnapshots.ToArray(); } } }
  public bool LoadingCoverObserved { get { lock(loadingLock) { return loadingKnown; } } }
  public bool LoadingCoverWaiting { get { lock(loadingLock) { return loadingKnown && loadingWaiting; } } }
  public int LoadingClearObserved { get { lock(loadingLock) { return loadingClears; } } }
  public bool PipelineWarmTimedOut { get { lock(loadingLock) { return warmTimedOut; } } }
  public long? PipelineWarmPending { get { lock(loadingLock) { return warmPending; } } }
  [DllImport("kernel32.dll")] public static extern void GetSystemTimePreciseAsFileTime(out long time);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window,int command);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
  [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
  [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code,uint kind);
  [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra; }
  [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
  [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Keyboard Key; [FieldOffset(0)] public Mouse Mouse; }
  [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public Union Value; }
  public static long Wall() { long value; GetSystemTimePreciseAsFileTime(out value); return value; }
  static bool Has(string value,string needle) { return value.IndexOf(needle,StringComparison.OrdinalIgnoreCase)>=0; }
  static long Count(Match match,string name) { return long.Parse(match.Groups[name].Value,CultureInfo.InvariantCulture); }
  void ObserveLoading(string text) {
    var wait=loadingWaitPattern.Match(text);
    if(wait.Success) {
      var snapshot=new AZSGLoadingSnapshot {observedFileTime=Wall(),seconds=double.Parse(wait.Groups["seconds"].Value,CultureInfo.InvariantCulture),
        ready=Count(wait,"ready"),total=Count(wait,"total"),placementsPending=Count(wait,"placements"),collidersPending=Count(wait,"colliders"),mergesPending=Count(wait,"merges"),
        awaitingSnap=wait.Groups["snap"].Value=="true",settling=wait.Groups["settling"].Value=="true",warm=wait.Groups["warm"].Value=="true",uiPending=wait.Groups["ui"].Value=="true"};
      lock(loadingLock) { loadingKnown=true; loadingWaiting=true; loadingSnapshots.Add(snapshot); if(loadingSnapshots.Count>6) loadingSnapshots.RemoveAt(0); }
    }
    if(loadingClearPattern.IsMatch(text)) { lock(loadingLock) { loadingKnown=true; loadingWaiting=false; if(loadingClears<int.MaxValue) ++loadingClears; } }
    var timeout=warmTimeoutPattern.Match(text);
    if(timeout.Success) { lock(loadingLock) { warmTimedOut=true; warmPending=Count(timeout,"pending"); } }
  }
  static string RedactedLine(string value) {
    if(value.Length>16384) value=value.Substring(0,16384);
    value=Regex.Replace(value,@"\x1B\[[0-?]*[ -/]*[@-~]","");
    value=Regex.Replace(value,@"(?i)\b[a-z][a-z0-9+.-]*://[^\s""'<>]+","<url>");
    value=Regex.Replace(value,@"(?i)\b(?:[a-z0-9_]*(?:token|secret|password)|authorization|proxy-authorization|auth|api[_-]?key|sig)\s*[:=]\s*(?:(?:bearer|basic|token)\s+)?(?:""[^""]*""|'[^']*'|[^\s,;]+)","<credential>");
    value=Regex.Replace(value,@"(?i)\b(?:gh[pousr]_[a-z0-9_]+|github_pat_[a-z0-9_]+|bearer\s+[^\s,;]+)\b","<credential>");
    value=Regex.Replace(value,@"(?i)[""'][a-z]:[\\/][^""'\r\n]*[""']","<path>");
    value=Regex.Replace(value,@"(?i)\b[a-z]:[\\/][^\s""'<>]*","<path>");
    value=Regex.Replace(value,@"/(?:home|Users|tmp|runner|__w|a|opt|usr|rustc)/[^\s""'<>]*","<path>");
    value=Regex.Replace(value,@"[\x00-\x08\x0B-\x1F\x7F]","");
    value=Regex.Replace(value,@"\s+"," ").Trim();
    return value.Length>400?value.Substring(0,400):value;
  }
  void ObserveStartup(string text,bool panic) {
    if(Has(text,"Unable to find a GPU") || Has(text,"no suitable adapter")) startupCategories.TryAdd("adapter_unavailable",0);
    if(Has(text,"RequestDeviceError") || Has(text,"failed to create wgpu")) startupCategories.TryAdd("device_request_failed",0);
    if(Has(text,"DeviceLost") || Has(text,"device lost") || Has(text,"device is lost")) startupCategories.TryAdd("device_lost",0);
    if(Has(text,"Surface::present") && (Has(text,"Validation Error") || Has(text,"error"))) startupCategories.TryAdd("surface_present_validation_failed",0);
    if(Has(text,"MissingFeatures") || Has(text,"UnsupportedFeatures") || (Has(text,"features") && (Has(text,"not support") || Has(text,"not enabled")))) startupCategories.TryAdd("gpu_features_unavailable",0);
    if(Has(text,"shader") && (Has(text,"error") || Has(text,"failed") || Has(text,"validation"))) startupCategories.TryAdd("shader_validation_failed",0);
    if((Has(text,"DX12") || Has(text,"D3D12")) && (Has(text,"error") || Has(text,"failed"))) startupCategories.TryAdd("dx12_runtime_error",0);
    if(Has(text,"MPQ") && (Has(text,"failed") || Has(text,"missing") || Has(text,"unable") || Has(text,"not found"))) startupCategories.TryAdd("asset_open_failed",0);
    if(Has(text,"DLL") && (Has(text,"missing") || Has(text,"not found") || Has(text,"could not"))) startupCategories.TryAdd("native_dependency_missing",0);
    if(!capturePanic) return;
    lock(panicLock) {
      if(panic && !panicStarted) { panicStarted=true; panicRemaining=4; }
      if(panicRemaining>0) { var line=RedactedLine(text); if(line.Length>0) { panicExcerpt.Add(line); --panicRemaining; } }
    }
  }
  void Line(object sender,DataReceivedEventArgs e) {
    var text=e.Data; if(text==null) return;
    if(text.IndexOf("Microsoft Basic Render Driver",StringComparison.OrdinalIgnoreCase)>=0 || text.IndexOf("device_type: Cpu",StringComparison.OrdinalIgnoreCase)>=0) SoftwareObserved=true;
    if(text.IndexOf("Unable to find a GPU",StringComparison.OrdinalIgnoreCase)>=0 || text.IndexOf("failed to create wgpu",StringComparison.OrdinalIgnoreCase)>=0 || text.IndexOf("RequestDeviceError",StringComparison.OrdinalIgnoreCase)>=0) GpuFailure=true;
    var panic=text.IndexOf("panicked at",StringComparison.Ordinal)>=0;
    if(panic) Panicked=true;
    ObserveStartup(text,panic);
    if(Has(text,"loading screen:") || Has(text,"pipeline warm:")) ObserveLoading(text);
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
    if(IsIconic(handle)) ShowWindow(handle,9);
    uint pid; GetWindowThreadProcessId(GetForegroundWindow(),out pid);
    if(pid==(uint)Child.Id) return true;
    SetForegroundWindow(handle); GetWindowThreadProcessId(GetForegroundWindow(),out pid); return pid==(uint)Child.Id;
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
    $match = [regex]::Match($Row.Payload, '^(?<protocol>AZSGT1\|[0-9]+\|[01]\|(?:100|200)\|[0-5]\|(?:unknown|ready|playing|choosing|paused|dead|victory)\|(?:-?[0-9]+(?:\.[0-9]+)?\|){16}[01]\|(?:-1|[01])\|(?:-1|[01])\|[0-9]{1,16})(?:[^0-9.|]|$)')
    if (-not $match.Success) { return $null }
    $parts = $match.Groups['protocol'].Value.Split('|')
    if ($parts.Count -ne 26) { return $null }
    [long]$instance = 0
    if (-not [long]::TryParse($parts[25], [ref]$instance) -or $instance -lt 1 -or $instance -gt 9007199254740991L) { return $null }
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
        runPackets = $numeric[14]; spellPackets = $numeric[15]; requestAccepted = [int]$parts[22]
        chatOpen = [int]$parts[23]; gameMenuShown = [int]$parts[24]; instance = $instance }
}

function Capture-BlockedFrame($Session, [string]$Mode) {
    $result = [ordered]@{ requested = $false; screenshotCaptured = $false; code = 'not_requested'; width = 0; height = 0; progressStage = 'none' }
    if ($env:AZSG_CAPTURE_FRAME -cne '1') { return [pscustomobject]$result }
    $result.requested = $true
    if ($Session.Child.HasExited) { $result.code = 'game_exited'; return [pscustomobject]$result }
    $helper = Join-Path $PSScriptRoot 'remote_game_screenshot.ps1'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { $result.code = 'helper_missing'; return [pscustomobject]$result }
    $process = $null
    try {
        $framePath = Join-Path $script:projectRoot ('acceptance\frame-' + $Mode + '.png')
        $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helper,
            '-GameProcessId', [string]$Session.Child.Id, '-OutputPath', $framePath)) { $info.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            $process.Kill(); [void]$process.WaitForExit(1000)
            $progressPath = $framePath + '.progress.json'
            if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
                try {
                    $progressFile = Get-Item -LiteralPath $progressPath -Force
                    if ($progressFile.Length -le 256 -and ($progressFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $progress = [IO.File]::ReadAllText($progressPath) | ConvertFrom-Json
                        if ($progress.schema -eq 1 -and $progress.stage -cin @('started', 'assemblies', 'window', 'copy', 'save', 'done')) {
                            $result.progressStage = [string]$progress.stage
                        }
                    }
                } catch { }
            }
            $result.code = 'helper_timeout'; return [pscustomobject]$result
        }
        $text = $stdout.GetAwaiter().GetResult()
        if ($text.Length -gt 2048) { $result.code = 'helper_report_bounds'; return [pscustomobject]$result }
        $captured = $text | ConvertFrom-Json
        if ($captured.screenshotCaptured -isnot [bool] -or $captured.code -cnotmatch '^[a-z_]{1,60}$' -or
            ($captured.width -isnot [long] -and $captured.width -isnot [int]) -or
            ($captured.height -isnot [long] -and $captured.height -isnot [int]) -or
            $captured.width -lt 0 -or $captured.width -gt 1920 -or $captured.height -lt 0 -or $captured.height -gt 1080) {
            $result.code = 'helper_report_invalid'; return [pscustomobject]$result
        }
        $result.screenshotCaptured = $captured.screenshotCaptured -and $process.ExitCode -eq 0
        $result.code = [string]$captured.code; $result.width = $captured.width; $result.height = $captured.height
    } catch { $result.code = 'helper_failed' }
    finally { if ($null -ne $process) { $process.Dispose() } }
    return [pscustomobject]$result
}

function Invoke-GameRun([string]$Mode, [string]$GameRoot, [string]$Assets, [string]$OfficialExe) {
    New-Item -ItemType Directory -Path $GameRoot -Force | Out-Null
    $data = Join-Path $GameRoot 'Data'
    New-Item -ItemType Directory -Path $data | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $Assets -File)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $data $file.Name) }
    $exe = Join-Path $GameRoot 'AzerothSurvivors.exe'
    Copy-Item -LiteralPath $OfficialExe -Destination $exe
    foreach ($runtimeFile in $script:runtimeDllSources) {
        $destination = [IO.Path]::GetFullPath((Join-Path $GameRoot $runtimeFile.name))
        if (-not $destination.StartsWith($script:fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'blocked_runtime_profile_destination' }
        Copy-Item -LiteralPath $runtimeFile.path -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $runtimeFile.sha256) { throw 'blocked_runtime_profile_copy' }
    }
    $state = Join-Path $GameRoot 'benilla-config'
    $telemetry = Join-Path $state 'AddOns\AZSGAcceptance'
    Write-Text (Join-Path $telemetry 'AZSGAcceptance.toc') "## Interface: 11200`n## Title: AZSG remote acceptance`nMode.lua`nTelemetry.lua`n"
    Write-Text (Join-Path $telemetry 'Mode.lua') ('AZSGAcceptanceMode = "' + $Mode + '";' + "`n")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'remote_game_telemetry.lua') -Destination (Join-Path $telemetry 'Telemetry.lua')
    Write-Text (Join-Path $state 'config.toml') "[cvars]`ngxWindow = `"1`"`ngxResolution = `"$script:viewport`"`ngxVSync = `"0`"`nfarclip = `"177`"`nshadowLevel = `"0`"`n"
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
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($credential in @('AZSG_GAME_BUNDLE_URL', 'GH_TOKEN', 'GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN')) { [void]$info.Environment.Remove($credential) }
    $info.Environment['WGPU_BACKEND'] = 'dx12'
    $info.Environment['WGPU_FORCE_FALLBACK_ADAPTER'] = '1'
    $info.Environment['WGPU_ADAPTER_NAME'] = 'Microsoft Basic Render Driver'
    $info.Environment['RUST_LOG'] = 'info,wgpu_core=warn,wgpu_hal=warn,naga=warn'
    $info.Environment['WOW_WIN'] = $script:viewport
    $info.Environment['BENILLA_HOME'] = $state
    $appData = Join-Path $GameRoot 'AppData'; New-Item -ItemType Directory -Path $appData | Out-Null
    $info.Environment['APPDATA'] = $appData; $info.Environment['LOCALAPPDATA'] = $appData
    $session = [AZSGRemoteGame]::new()
    $samples = [Collections.Generic.List[object]]::new()
    $start = [AZSGRemoteGame]::Wall(); $firstPlayingAt = $null; $lastEnter = 0L; $lastChoice = 0L
    $movementKey = 0; $moveStage = -1; $moveStart = 0L; $inputOkay = $true; $reason = 'blocked_no_playing'
    $startupHeld = $false; $startupHoldUntil = 0L; $lastEscapeSeq = -1L; $initialEnterSent = $false
    $frameAttempted = $false; $earlyCapture = $null
    $telemetryInstance = 0L; $instanceSequences = @{}; $telemetryReloaded = $false; $playingInstance = 0L
    try {
        $session.Start($info)
        while (([AZSGRemoteGame]::Wall() - $start) / 1e7 -lt ($script:startupSeconds + 60)) {
            if ($session.Child.HasExited) {
                # Complete already-exited process output callbacks before taking
                # the bounded diagnostic snapshot, including lines after panic.
                $session.Child.WaitForExit()
                $reason = if ($session.GpuFailure) { 'blocked_renderer' } else { 'blocked_game_exited' }
                break
            }
            $row = $null
            while ($session.Rows.TryDequeue([ref]$row)) {
                $sample = Read-Telemetry $row
                if ($null -ne $sample -and $samples.Count -lt 4000) {
                    $instanceKey = [string]$sample.instance
                    if ($sample.instance -ne $telemetryInstance) {
                        # Ignore delayed lines from an already retired VM. A
                        # genuinely new VM may reset its sequence before play.
                        if ($instanceSequences.ContainsKey($instanceKey)) { $row = $null; continue }
                        if ($null -ne $firstPlayingAt -or $playingInstance -ne 0) {
                            $telemetryReloaded = $true; $reason = 'blocked_telemetry_reload'; break
                        }
                        $telemetryInstance = $sample.instance; $lastEscapeSeq = -1L
                    }
                    if (-not $instanceSequences.ContainsKey($instanceKey) -or $sample.seq -gt $instanceSequences[$instanceKey]) {
                        $instanceSequences[$instanceKey] = $sample.seq; $samples.Add($sample)
                        if ($sample.phase -ceq 'playing') { $playingInstance = $sample.instance }
                    }
                }
                $row = $null
            }
            if ($telemetryReloaded) { break }
            $now = [AZSGRemoteGame]::Wall()
            if ($samples.Count -gt 0) {
                $latest = $samples[$samples.Count - 1]
                if ($latest.phase -ceq 'playing' -and $null -eq $firstPlayingAt) {
                    $firstPlayingAt = $now
                    if ($startupHeld) { $inputOkay = $session.Key(0x57, $false) -and $inputOkay; $startupHeld = $false }
                }
                if ($startupHeld -and ($latest.chatOpen -eq 1 -or $latest.gameMenuShown -eq 1)) {
                    $inputOkay = $session.Key(0x57, $false) -and $inputOkay; $startupHeld = $false
                }
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
            if ($startupHeld -and $now -ge $startupHoldUntil) {
                $inputOkay = $session.Key(0x57, $false) -and $inputOkay; $startupHeld = $false
            }
            if ($null -eq $firstPlayingAt -and ($now - $start) / 1e7 -gt 5 -and ($now - $lastEnter) / 1e7 -gt 5) {
                # Loading assets or software shaders can leave no usable window
                # yet. Retry focus only every five seconds, within the existing
                # startup deadline; never send keys to an unavailable window.
                $lastEnter = $now
                if ($session.Focus() -and -not $startupHeld) {
                    if ($samples.Count -gt 0 -and ($latest.chatOpen -eq 1 -or $latest.gameMenuShown -eq 1)) {
                        # Escape only after a newly observed open overlay. An old
                        # flag must not toggle a now-closed menu back open.
                        if ($latest.seq -gt $lastEscapeSeq) {
                            $inputOkay = $session.Tap(0x1b) -and $inputOkay
                            $lastEscapeSeq = $latest.seq
                        }
                    } elseif ($samples.Count -gt 0 -and $latest.phase -ceq 'ready') {
                        $readyInputAllowed = -not $session.LoadingCoverWaiting
                        if ($env:AZSG_CAPTURE_FRAME -ceq '1' -and -not $frameAttempted) {
                            if ($latest.mapContinent -gt 0 -and $latest.mapZone -gt 0 -and $latest.mapX -ge 0 -and $latest.mapY -ge 0) {
                                $frameAttempted = $true
                                $earlyCapture = Capture-BlockedFrame $session $Mode
                                $earlyCapture | Add-Member -NotePropertyName timing -NotePropertyValue 'ready_before_input'
                            } else { $readyInputAllowed = $false }
                        }
                        # Hold across slow rendered frames while this loop keeps
                        # draining telemetry; the playing observation releases W.
                        if ($readyInputAllowed) {
                            $inputOkay = $session.Key(0x57, $true) -and $inputOkay
                            $startupHeld = $inputOkay; $startupHoldUntil = [AZSGRemoteGame]::Wall() + 40000000L
                        }
                    } elseif (-not $initialEnterSent -and ($samples.Count -eq 0 -or $latest.phase -ceq 'unknown')) {
                        $inputOkay = $session.Tap(0x0d) -and $inputOkay
                        $initialEnterSent = $true
                    }
                }
            }
            if ($null -eq $firstPlayingAt -and ($now - $start) / 1e7 -gt $script:startupSeconds) { break }
            if (-not $inputOkay) {
                if ($session.Child.HasExited) {
                    $session.Child.WaitForExit()
                    $reason = 'blocked_game_exited'
                } else { $reason = 'blocked_input_or_foreground' }
                break
            }
            Start-Sleep -Milliseconds 50
        }
        if ($startupHeld -and -not $session.Child.HasExited) { [void]$session.Key(0x57, $false); $startupHeld = $false }
        $capture = if ($frameAttempted) { $earlyCapture }
            elseif ($reason -cne 'observed') { Capture-BlockedFrame $session $Mode }
            else { [pscustomobject]@{ requested = $false; screenshotCaptured = $false; code = 'not_needed'; width = 0; height = 0; progressStage = 'none' } }
        $peakWorkingSet = $null; $responding = $null
        try {
            $session.Child.Refresh()
            $peak = [long]$session.Child.PeakWorkingSet64
            if ($peak -ge 0) { $peakWorkingSet = $peak }
        } catch { }
        try { if (-not $session.Child.HasExited) { $responding = [bool]$session.Child.Responding } } catch { }
        return [pscustomobject]@{ mode = $Mode; status = $reason; softwareAdapterObserved = $session.SoftwareObserved
            processExitCode = $(if ($session.Child.HasExited) { $session.Child.ExitCode } else { $null })
            gpuFailure = $session.GpuFailure; panicked = $session.Panicked
            startupCategories = @($session.StartupCategories); panicCaptureEnabled = $session.PanicCaptureEnabled; panicExcerpt = @($session.PanicExcerpt)
            frameCapture = $capture
            telemetryInstanceCount = $instanceSequences.Count; telemetryReloaded = $telemetryReloaded
            peakWorkingSetBytes = $peakWorkingSet; responding = $responding
            startupSeconds = $script:startupSeconds; loadingCoverObserved = $session.LoadingCoverObserved; loadingCoverWaiting = $session.LoadingCoverWaiting
            loadingClearObserved = $session.LoadingClearObserved; loadingSnapshots = @($session.LoadingSnapshots)
            pipelineWarmTimedOut = $session.PipelineWarmTimedOut; pipelineWarmPending = $session.PipelineWarmPending
            droppedTelemetry = $session.Dropped; samples = $samples.ToArray() }
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
    $script:startupSeconds = 90
    if (-not [string]::IsNullOrWhiteSpace($env:AZSG_STARTUP_SECONDS)) {
        [int]$requestedStartup = 0
        if ($env:AZSG_STARTUP_SECONDS -cnotmatch '^[0-9]{2,3}$' -or
            -not [int]::TryParse($env:AZSG_STARTUP_SECONDS, [ref]$requestedStartup) -or
            $requestedStartup -lt 90 -or $requestedStartup -gt 300) { throw 'blocked_startup_limit' }
        $script:startupSeconds = $requestedStartup
    }
    $report.startupSeconds = $script:startupSeconds
    $script:viewport = '640x480'
    if (-not [string]::IsNullOrWhiteSpace($env:AZSG_GAME_VIEWPORT)) {
        if ($env:AZSG_GAME_VIEWPORT -cnotin @('640x480', '320x240')) { throw 'blocked_viewport' }
        $script:viewport = $env:AZSG_GAME_VIEWPORT
    }
    $report.viewport = $script:viewport
    try {
        $machine = @(Get-CimInstance -ClassName Win32_ComputerSystem -Property NumberOfLogicalProcessors,TotalPhysicalMemory -OperationTimeoutSec 5 -ErrorAction Stop)
        if ($machine.Count -eq 1) {
            $processors = [long]$machine[0].NumberOfLogicalProcessors
            $memory = [long]$machine[0].TotalPhysicalMemory
            if ($processors -ge 1 -and $processors -le 1024) { $report.machine.logicalProcessors = $processors }
            if ($memory -ge 1 -and $memory -le 17592186044416L) { $report.machine.totalPhysicalMemoryBytes = $memory }
        }
    } catch { }
    # A private asset repository can check out this plugin at a pinned commit;
    # its workflow GITHUB_SHA names that other repository, not the plugin code.
    $sourceIdentity = @(& git -C $projectRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $sourceIdentity.Count -ne 1 -or
        $sourceIdentity[0] -cnotmatch '^[a-f0-9]{40}$') { throw 'blocked_source_identity' }
    $report.sourceCommit = [string]$sourceIdentity[0]
    Add-Type -TypeDefinition $hostSource
    Initialize-RemoteRuntime
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
    $privateRequested = -not [string]::IsNullOrWhiteSpace($env:AZSG_GAME_BUNDLE_SHA256) -or
        -not [string]::IsNullOrWhiteSpace($env:AZSG_GAME_BUNDLE_BYTES)
    if ($privateRequested) {
        $report.gameSource = 'private_local_bundle'
        if ([string]::IsNullOrWhiteSpace($env:AZSG_GAME_BUNDLE_PATH) -and
            [string]::IsNullOrWhiteSpace($env:AZSG_GAME_BUNDLE_URL)) { throw 'blocked_private_bundle_secret' }
        $identity = Get-PrivateGameBundle
        $report.privateBundleSha256 = $identity.bundleSha256; $report.privateBundleBytes = $identity.bundleBytes
        $assets = Join-Path $fixtureRoot 'private-bundle\Data'
        $officialExe = Join-Path $fixtureRoot 'private-bundle\AzerothSurvivors.exe'
    } else {
        $identity = Get-OfficialGame
        $report.phase = 'assets'
        $assets = Expand-OnlyOfficialAssets (Join-Path $fixtureRoot 'assets')
        $officialExe = Join-Path $fixtureRoot 'official-game.exe'
    }
    $report.gameVersion = $identity.version; $report.gameSha256 = $identity.sha256
    $report.gameBytes = $identity.size; $report.officialAssetsSha256 = $identity.assetsSha256
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
Write-Output ([pscustomobject]$report | Select-Object schema,product,status,reason,phase,gameVersion,downloadDiagnostic | ConvertTo-Json -Compress -Depth 5)
exit $exitCode

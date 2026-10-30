#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Human')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Human')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Watch')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Json')]
    [ValidateNotNullOrEmpty()]
    [string]$GamePath,
    [Parameter(ParameterSetName = 'Watch')]
    [switch]$Watch,
    [Parameter(ParameterSetName = 'Json')]
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Stop-StatusRead([string]$Reason, [string]$Message) {
    $statusException = [IO.InvalidDataException]::new($Message)
    $statusException.Data['StatusReason'] = $Reason
    throw $statusException
}

function Assert-NoStatusLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        # Get-Item can identify a dangling link that Test-Path reports absent.
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $link = $item.PSObject.Properties['LinkType']
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($null -ne $link -and -not [string]::IsNullOrEmpty([string]$link.Value))) {
                Stop-StatusRead 'link_path' '拒绝读取链接或重解析路径中的状态文件。'
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Read-SmallStatusFile([string]$Path) {
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 16384) { Stop-StatusRead 'file_too_large' '状态文件超过 16 KiB 限制。' }
        # Read at most one byte beyond the limit, including if a file grows
        # between the length check and the read. Never allocate from its length.
        $buffer = New-Object byte[] 16385
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt 16384) { Stop-StatusRead 'file_too_large' '状态文件超过 16 KiB 限制。' }
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        try { $text = $utf8.GetString($buffer, 0, $count) }
        catch { Stop-StatusRead 'malformed_json' '状态文件不是有效 UTF-8 JSON。' }
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) { $text = $text.Substring(1) }
        return $text
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Convert-StatusUInt64($Value, [string]$Field) {
    if ($null -eq $Value -or $Value -is [bool]) {
        Stop-StatusRead 'invalid_type' ("字段 {0} 必须是 uint64 数字。" -f $Field)
    }
    $numericTypes = @('System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16',
        'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64',
        'System.Decimal', 'System.Numerics.BigInteger')
    if ($numericTypes -cnotcontains $Value.GetType().FullName) {
        Stop-StatusRead 'invalid_type' ("字段 {0} 必须是 uint64 数字；不接受字符串或不支持的数值类型。" -f $Field)
    }
    try { $number = [decimal]$Value }
    catch { Stop-StatusRead 'invalid_number' ("字段 {0} 超出 uint64 范围。" -f $Field) }
    if ($number -lt 0 -or $number -gt [decimal][uint64]::MaxValue -or
        [decimal]::Truncate($number) -ne $number) {
        Stop-StatusRead 'invalid_number' ("字段 {0} 超出 uint64 范围或不是整数。" -f $Field)
    }
    return [uint64]$number
}

function Get-BackendStatus([string]$SelectedPath) {
    $result = [ordered]@{
        product = 'AzerothSurvivorsSpeedGear'
        state = 'invalid'
        reason = $null
        statusFile = $null
        schema = $null
        version = $null
        updatedUnix = $null
        ageSeconds = $null
        backend = $null
        transport = $null
        speed100 = $null
        backendConfiguredMultiplier = $null
        speedMeaning = 'backend configured/applied setting; not measured game speed'
        heartbeatAgeMs = $null
        fileReads = $null
        consoleForwardDroppedBytes = $null
        warnings = @()
        message = ''
    }
    try {
        $selected = [IO.Path]::GetFullPath($SelectedPath)
        Assert-NoStatusLinks $selected
        if (Test-Path -LiteralPath $selected -PathType Container) {
            $root = $selected
        } elseif ((Test-Path -LiteralPath $selected -PathType Leaf) -and
            [IO.Path]::GetExtension($selected) -ieq '.exe') {
            $root = Split-Path -Parent $selected
        } else {
            Stop-StatusRead 'invalid_game_path' 'GamePath 必须指向现有游戏 EXE 或游戏目录。'
        }
        $statusFile = Join-Path $root 'AZSSpeedGear-status.json'
        $result.statusFile = $statusFile
        Assert-NoStatusLinks $statusFile
        if (-not (Test-Path -LiteralPath $statusFile)) {
            $result.state = 'missing'
            $result.reason = 'status_missing'
            $result.message = '没有找到原生后端状态文件；本查看器不会启动游戏。'
            return [pscustomobject]$result
        }
        if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) {
            Stop-StatusRead 'invalid_file' '状态路径不是普通文件。'
        }
        $text = Read-SmallStatusFile $statusFile
        try { $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
        catch { Stop-StatusRead 'malformed_json' '状态文件不是有效 JSON；可能正在更新，请稍后重试。' }
        if ($null -eq $data -or $data -isnot [pscustomobject]) {
            Stop-StatusRead 'invalid_type' '状态 JSON 的根必须是对象。'
        }
        $fields = @('product', 'schema', 'version', 'updatedUnix', 'backend', 'transport', 'speed100',
            'heartbeatAgeMs', 'fileReads', 'consoleForwardDroppedBytes')
        $names = @($data.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -ne $fields.Count) { Stop-StatusRead 'invalid_fields' '状态字段数量不符合 schema 1。' }
        foreach ($name in $fields) {
            if ($names -cnotcontains $name) { Stop-StatusRead 'invalid_fields' ("状态缺少字段 {0}。" -f $name) }
        }
        # Native schema-1 keys are fixed ASCII. Also reject duplicate/escaped
        # property keys rather than accepting ConvertFrom-Json's last value.
        $keyMatches = [regex]::Matches($text, '"([^"\\]*)"\s*:')
        $seen = @{}
        foreach ($match in $keyMatches) {
            $key = $match.Groups[1].Value
            if ($fields -cnotcontains $key -or $seen.ContainsKey($key)) {
                Stop-StatusRead 'invalid_fields' '状态包含未知、重复或不规范的字段。'
            }
            $seen[$key] = $true
        }
        if ($seen.Count -ne $fields.Count -or $keyMatches.Count -ne $fields.Count) {
            Stop-StatusRead 'invalid_fields' '状态包含不规范的字段名。'
        }
        if ($data.product -isnot [string] -or $data.product -cne 'AzerothSurvivorsSpeedGear') {
            Stop-StatusRead 'unknown_product' '状态文件不属于 AzerothSurvivorsSpeedGear。'
        }
        $schema = Convert-StatusUInt64 $data.schema 'schema'
        if ($schema -ne 1) { Stop-StatusRead 'unknown_schema' '不支持此状态文件 schema。' }
        if ($data.version -isnot [string] -or $data.version -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
            Stop-StatusRead 'unknown_version' '状态文件必须包含有效的正式版本号。'
        }
        $backends = @('initializing', 'ready', 'unsupported', 'hooks_failed')
        $transports = @('waiting', 'console', 'file', 'degraded', 'stale', 'disabled')
        if ($data.backend -isnot [string] -or $backends -cnotcontains $data.backend) {
            Stop-StatusRead 'unknown_backend' '状态包含未知 backend。'
        }
        if ($data.transport -isnot [string] -or $transports -cnotcontains $data.transport) {
            Stop-StatusRead 'unknown_transport' '状态包含未知 transport。'
        }
        $updated = Convert-StatusUInt64 $data.updatedUnix 'updatedUnix'
        $speed = Convert-StatusUInt64 $data.speed100 'speed100'
        if ($speed -lt 25 -or $speed -gt 1000) { Stop-StatusRead 'invalid_speed' '后端设定倍率不在 0.25–10 范围。' }
        $reads = Convert-StatusUInt64 $data.fileReads 'fileReads'
        $dropped = Convert-StatusUInt64 $data.consoleForwardDroppedBytes 'consoleForwardDroppedBytes'
        $heartbeat = $null
        if ($null -ne $data.heartbeatAgeMs) { $heartbeat = Convert-StatusUInt64 $data.heartbeatAgeMs 'heartbeatAgeMs' }
        $result.schema = $schema
        $result.version = $data.version
        $result.updatedUnix = $updated
        $result.backend = $data.backend
        $result.transport = $data.transport
        $result.speed100 = $speed
        $result.backendConfiguredMultiplier = [double]$speed / 100
        $result.heartbeatAgeMs = $heartbeat
        $result.fileReads = $reads
        $result.consoleForwardDroppedBytes = $dropped
        if ($dropped -gt 0) {
            $result.warnings = @("原日志转发累计丢弃 $dropped 字节；这不是控制命令丢失计数。")
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ([decimal]$updated -gt [decimal]$now + 2) {
            Stop-StatusRead 'future_timestamp' '状态时间比当前真实时间超前超过两秒，数据无效。'
        }
        $result.ageSeconds = $now - [long]$updated
        if ($result.ageSeconds -gt 5) {
            $result.state = 'offline'
            $result.reason = 'status_expired'
            $result.message = '后端状态超过五秒未更新：offline；下面的字段只代表旧快照。'
        } elseif ($data.backend -eq 'unsupported') {
            $result.state = 'disabled'
            $result.reason = 'unsupported'
            $result.message = '游戏结构不受支持，原生后端已禁用变速。'
        } elseif ($data.backend -eq 'hooks_failed') {
            $result.state = 'disabled'
            $result.reason = 'hooks_failed'
            $result.message = '原生时钟钩子初始化失败，后端已禁用变速。'
        } elseif ($data.backend -eq 'initializing') {
            $result.state = 'initializing'
            $result.message = '原生后端正在初始化，尚未就绪。'
        } elseif ($data.transport -eq 'disabled') {
            $result.state = 'disabled'
            $result.message = '原生后端报告控制通道已禁用。'
        } elseif ($data.transport -eq 'waiting') {
            $result.state = 'waiting'
            $result.message = '原生后端已就绪，正在等待确认控制命令。'
        } elseif ($data.transport -eq 'stale') {
            $result.state = 'stale'
            $result.message = '原生后端报告控制心跳已过期。'
        } elseif ($data.transport -eq 'degraded') {
            $result.state = 'degraded'
            $result.message = '原生后端报告通道降级；不要把发送请求视为确认。'
        } else {
            $result.state = 'ready'
            $result.message = if ($data.transport -eq 'console') { '即时通道：原生后端已确认。' } else { '文件后备：原生后端已确认。' }
        }
    } catch {
        $result.state = 'invalid'
        if ($_.Exception.Data.Contains('StatusReason')) {
            $result.reason = [string]$_.Exception.Data['StatusReason']
            $result.message = $_.Exception.Message
        } else {
            $result.reason = 'status_unreadable'
            $result.message = '状态无法安全读取；请检查所选路径和读取权限。'
        }
    }
    return [pscustomobject]$result
}

function Write-StatusText($Status) {
    Write-Output ('AzerothSurvivorsSpeedGear | {0:yyyy-MM-dd HH:mm:ss zzz}' -f [DateTimeOffset]::Now)
    Write-Output ('状态：{0} — {1}' -f $Status.state, $Status.message)
    if ($null -ne $Status.backend) {
        Write-Output ('后端：{0}；通道：{1}；快照年龄：{2} 秒' -f $Status.backend, $Status.transport, $Status.ageSeconds)
        Write-Output ('后端设定倍率：x{0:0.00}（配置/应用设定，非游戏实测）' -f $Status.backendConfiguredMultiplier)
        $age = if ($null -eq $Status.heartbeatAgeMs) { '未收到' } else { [string]$Status.heartbeatAgeMs + ' ms' }
        Write-Output ('心跳年龄：{0}；文件读取次数：{1}' -f $age, $Status.fileReads)
    }
    foreach ($warning in @($Status.warnings)) { Write-Output ('提示：' + $warning) }
    Write-Output ('状态文件：' + $Status.statusFile)
}

if ($AsJson) {
    Get-BackendStatus $GamePath | ConvertTo-Json -Depth 5
    return
}
do {
    Write-StatusText (Get-BackendStatus $GamePath)
    if ($Watch) {
        # This separate PowerShell process uses its own real clock; the game's
        # injected timing hooks do not change this one-second refresh interval.
        Start-Sleep -Milliseconds 1000
        Write-Output ''
    }
} while ($Watch)

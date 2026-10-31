#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

# Private, disposable Windows CI diagnostic only. The caller must bound this
# helper's lifetime: PrintWindow can wait for an unresponsive rendering surface.
# This script never starts, activates or changes the game window.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$result = [ordered]@{ screenshotCaptured = $false; code = 'capture_failed'; width = 0; height = 0; mode = 'none' }
$failureCode = 'capture_failed'
$bitmap = $null
$graphics = $null
$temporaryOutput = $null
$progressOutput = $null

function Stop-Capture([string]$Code) {
    $script:failureCode = $Code
    throw 'Capture unavailable.'
}

function Assert-NoLinkedAncestor([string]$Path) {
    $cursor = Get-Item -LiteralPath $Path -Force
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Capture 'linked_output_path' }
        $cursor = $cursor.Parent
    }
}

function Write-CaptureProgress([string]$Stage) {
    if ($null -eq $script:progressOutput -or $Stage -cnotin @('started', 'assemblies', 'window', 'copy', 'save', 'done')) { return }
    # Fixed, small status only. This sidecar remains useful if the parent ends a
    # blocked native capture call; no window text, path or image data is written.
    try {
        $value = [ordered]@{ schema = 1; stage = $Stage } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($script:progressOutput, $value, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

try {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
        [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { Stop-Capture 'remote_ci_required' }
    if ($env:AZSG_CAPTURE_FRAME -cne '1') { Stop-Capture 'capture_disabled' }
    if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) { Stop-Capture 'windows_powershell_required' }
    if ($GameProcessId -lt 1 -or $GameProcessId -eq $PID) { Stop-Capture 'invalid_game_process' }

    $projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
    $workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')
    if (-not $projectRoot.Equals($workspace, [StringComparison]::OrdinalIgnoreCase) -and
        -not $projectRoot.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-Capture 'checkout_required' }
    Assert-NoLinkedAncestor $projectRoot
    $captureRoot = Join-Path $projectRoot 'acceptance'
    $output = [IO.Path]::GetFullPath($OutputPath)
    if (-not [IO.Path]::GetDirectoryName($output).Equals($captureRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($output) -cnotmatch '^frame-(baseline|hooked)\.png$') { Stop-Capture 'invalid_output_path' }
    if (Test-Path -LiteralPath $output) { Stop-Capture 'output_already_exists' }
    if (Test-Path -LiteralPath $captureRoot) { Assert-NoLinkedAncestor $captureRoot }
    else { New-Item -ItemType Directory -Path $captureRoot | Out-Null }
    $progressOutput = $output + '.progress.json'
    if (Test-Path -LiteralPath $progressOutput) {
        $existingProgress = Get-Item -LiteralPath $progressOutput -Force
        if (($existingProgress.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $existingProgress.PSIsContainer -or $existingProgress.Length -gt 1024) { Stop-Capture 'invalid_progress_path' }
    }
    Write-CaptureProgress 'started'

    $game = Get-Process -Id $GameProcessId -ErrorAction Stop
    if ($game.ProcessName -ine 'AzerothSurvivors') { Stop-Capture 'unexpected_process_name' }
    $game.Refresh()
    $window = $game.MainWindowHandle
    if ($game.HasExited -or $window -eq [IntPtr]::Zero) { Stop-Capture 'game_window_unavailable' }

    Write-CaptureProgress 'assemblies'
    Add-Type -AssemblyName System.Drawing
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class AZSGPrivateWindowCapture {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window,out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window,out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window,ref Point point);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window,IntPtr dc,uint flags);
    public static bool HasVisibleContent(Bitmap bitmap) {
        var first=bitmap.GetPixel(0,0);
        for(int y=0;y<bitmap.Height;y+=Math.Max(1,bitmap.Height/12))
            for(int x=0;x<bitmap.Width;x+=Math.Max(1,bitmap.Width/16)) {
                var value=bitmap.GetPixel(x,y);
                if(Math.Abs(value.R-first.R)+Math.Abs(value.G-first.G)+Math.Abs(value.B-first.B)>24) return true;
            }
        return false;
    }
}
'@
    Write-CaptureProgress 'window'
    [uint32]$owner = 0
    [void][AZSGPrivateWindowCapture]::GetWindowThreadProcessId($window, [ref]$owner)
    if ($owner -ne [uint32]$GameProcessId -or [AZSGPrivateWindowCapture]::IsIconic($window)) { Stop-Capture 'game_window_not_visible' }
    $windowRect = New-Object AZSGPrivateWindowCapture+Rect
    $client = New-Object AZSGPrivateWindowCapture+Rect
    $origin = New-Object AZSGPrivateWindowCapture+Point
    if (-not [AZSGPrivateWindowCapture]::GetWindowRect($window, [ref]$windowRect) -or
        -not [AZSGPrivateWindowCapture]::GetClientRect($window, [ref]$client) -or
        -not [AZSGPrivateWindowCapture]::ClientToScreen($window, [ref]$origin)) { Stop-Capture 'window_bounds_unavailable' }
    $clientLeft = [long]$origin.X + $client.Left
    $clientTop = [long]$origin.Y + $client.Top
    $clientRight = [long]$origin.X + $client.Right
    $clientBottom = [long]$origin.Y + $client.Bottom
    $screenLeft = [long][AZSGPrivateWindowCapture]::GetSystemMetrics(76)
    $screenTop = [long][AZSGPrivateWindowCapture]::GetSystemMetrics(77)
    $screenWidth = [long][AZSGPrivateWindowCapture]::GetSystemMetrics(78)
    $screenHeight = [long][AZSGPrivateWindowCapture]::GetSystemMetrics(79)
    if ($screenWidth -le 0 -or $screenHeight -le 0) { Stop-Capture 'display_unavailable' }
    $left = [Math]::Max($clientLeft, $screenLeft)
    $top = [Math]::Max($clientTop, $screenTop)
    $right = [Math]::Min([Math]::Min($clientRight, $screenLeft + $screenWidth), $left + 1920)
    $bottom = [Math]::Min([Math]::Min($clientBottom, $screenTop + $screenHeight), $top + 1080)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if ($width -lt 64 -or $height -lt 64) { Stop-Capture 'game_window_offscreen' }
    $bitmap = New-Object Drawing.Bitmap($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    [uint32]$foregroundOwner = 0
    [void][AZSGPrivateWindowCapture]::GetWindowThreadProcessId([AZSGPrivateWindowCapture]::GetForegroundWindow(), [ref]$foregroundOwner)
    Write-CaptureProgress 'copy'
    if ($foregroundOwner -eq [uint32]$GameProcessId) {
        # DX12 windows can block in PrintWindow. The visible owned game client
        # can be copied directly without sending a synchronous window message.
        $graphics.CopyFromScreen([int]$left, [int]$top, 0, 0, (New-Object Drawing.Size($width, $height)), [Drawing.CopyPixelOperation]::SourceCopy)
        $result.mode = 'visible_game_client'
    } else {
        # An occluded window may only be captured through its own HWND. Never
        # copy pixels belonging to an unrelated foreground application.
        if ($left -ne $clientLeft -or $top -ne $clientTop -or $right -ne $clientRight -or $bottom -ne $clientBottom) { Stop-Capture 'game_not_foreground' }
        $dc = $graphics.GetHdc()
        try { $printed = [AZSGPrivateWindowCapture]::PrintWindow($window, $dc, 3) }
        finally { $graphics.ReleaseHdc($dc) }
        if (-not $printed -or -not [AZSGPrivateWindowCapture]::HasVisibleContent($bitmap)) { Stop-Capture 'owned_window_unavailable' }
        $result.mode = 'owned_window'
    }
    Write-CaptureProgress 'save'
    $temporaryOutput = $output + '.tmp-' + [guid]::NewGuid().ToString('N')
    $bitmap.Save($temporaryOutput, [Drawing.Imaging.ImageFormat]::Png)
    if ((Get-Item -LiteralPath $temporaryOutput).Length -gt 4MB) { Stop-Capture 'image_size_limit' }
    [IO.File]::Move($temporaryOutput, $output)
    $temporaryOutput = $null
    $result.screenshotCaptured = $true
    $result.code = 'captured'
    $result.width = $width
    $result.height = $height
    Write-CaptureProgress 'done'
} catch {
    $result.code = $failureCode
} finally {
    if ($null -ne $graphics) { $graphics.Dispose() }
    if ($null -ne $bitmap) { $bitmap.Dispose() }
    if ($null -ne $temporaryOutput -and [IO.File]::Exists($temporaryOutput)) { [IO.File]::Delete($temporaryOutput) }
}
[pscustomobject]$result | ConvertTo-Json -Compress
if ($result.screenshotCaptured) { exit 0 }
exit 2

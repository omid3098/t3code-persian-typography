[CmdletBinding()]
param(
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "T3CodePersianTypography"),
    [switch]$WaitForExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "T3CodePersianTypography"))
$target = [IO.Path]::GetFullPath($StateRoot)
if ($target -ne $expected) { throw "Refusing to remove an unexpected path: $target" }

$statePath = Join-Path $target "state.json"
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "T3 Code Persian Typography is not installed."
    exit 0
}

# Stop-ScheduledTask ends conhost only; stop the watcher's PowerShell too.
function Stop-Watcher {
    if (Get-ScheduledTask -TaskName "T3CodePersianTypography" -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName "T3CodePersianTypography"
        Unregister-ScheduledTask -TaskName "T3CodePersianTypography" -Confirm:$false
    }
    $watch = Join-Path $target "watch.ps1"
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($watch) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Remove-StateRoot {
    if ([IO.Path]::GetFullPath($PSScriptRoot) -eq $target) {
        $escaped = $target.Replace("'", "''")
        $command = "Start-Sleep -Seconds 1; Remove-Item -LiteralPath '$escaped' -Recurse -Force"
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-Command", $command) -WindowStyle Hidden
    } else {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json

# Install requested while T3 Code was busy and never applied: nothing to restore.
if ($state.PSObject.Properties["pending"] -and $state.pending) {
    Stop-Watcher
    Remove-StateRoot
    Write-Host "Removed the pending T3 Code Persian Typography install; T3 Code was never patched."
    exit 0
}

$prefix = (Split-Path -Parent $state.t3Exe).TrimEnd("\") + "\"
function Test-T3Running {
    [bool](Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}
if ($WaitForExit) {
    while (Test-T3Running) { Start-Sleep -Seconds 2 }
    Start-Sleep -Seconds 1
} elseif (Test-T3Running) {
    throw "Close T3 Code before uninstalling, or rerun with -WaitForExit."
}

Stop-Watcher

if (-not (Test-Path -LiteralPath $state.serverAsar -PathType Leaf)) { throw "T3 Code server.asar is missing." }
if (-not (Test-Path -LiteralPath $state.backup -PathType Leaf)) { throw "Original server.asar backup is missing." }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $state.backup).Hash -ne $state.originalSha256) {
    throw "Original server.asar backup hash does not match state.json."
}

$currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $state.serverAsar).Hash
if ($currentHash -eq $state.patchedSha256) {
    Copy-Item -LiteralPath $state.backup -Destination $state.serverAsar -Force
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $state.serverAsar).Hash -ne $state.originalSha256) {
        throw "Restoring the original server.asar failed. The backup remains at $($state.backup)."
    }
} elseif ($currentHash -ne $state.originalSha256) {
    throw "T3 Code changed after installation. Refusing to restore a backup from a different build."
}

Remove-StateRoot

Write-Host "Restored the original T3 Code server.asar and removed the typography patch."

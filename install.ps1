[CmdletBinding()]
param(
    [string]$T3Exe,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "T3CodePersianTypography"),
    # Kept for compatibility: when T3 Code is running the installer always
    # hands the patch to the watcher, which applies it once T3 Code closes.
    [switch]$WaitForExit,
    [switch]$Launch,
    # Used by watch.ps1: never waits or prompts; exits 3 when T3 Code or its
    # updater still holds server.asar, 0 when already patched or done.
    [switch]$Unattended,
    # Skip registering the logon task that re-patches after T3 Code updates.
    [switch]$NoAutoRepatch,
    # Only for tests: register the watcher under a different task name.
    [string]$TaskName = "T3CodePersianTypography"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExitBusy = 3
$script:transcribing = $false

function Stop-InstallTranscript {
    if ($script:transcribing) {
        Stop-Transcript | Out-Null
        $script:transcribing = $false
    }
}
# Close install.log on any error, then let the error surface.
trap {
    Stop-InstallTranscript
    break
}

function Find-T3Code {
    if ($T3Exe -and (Test-Path -LiteralPath $T3Exe -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $T3Exe).Path
    }
    $dirs = @(
        $(if ($env:T3CODE_EXE) { Split-Path -Parent $env:T3CODE_EXE }),
        (Join-Path $env:LOCALAPPDATA "Programs\t3code"),
        (Join-Path $env:LOCALAPPDATA "Programs\T3 Code")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
    foreach ($dir in $dirs) {
        $exe = Get-ChildItem -LiteralPath $dir -Filter "T3 Code*.exe" -File |
            Where-Object { $_.Name -notlike "Uninstall*" } | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

function Get-T3Processes([string]$InstallDir) {
    $prefix = $InstallDir.TrimEnd("\") + "\"
    Get-Process | Where-Object {
        $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            -not ([IO.Path]::GetFileName($_.Path) -like "Uninstall*")
    }
}

# The T3 Code updater's installer runs from its cache folder, named in
# resources\app-update.yml. Recorded in state.json for the watcher.
function Get-UpdaterDir([string]$InstallDir) {
    $name = "t3code-updater"
    $yml = Join-Path $InstallDir "resources\app-update.yml"
    if (Test-Path -LiteralPath $yml) {
        $match = Select-String -LiteralPath $yml -Pattern '^\s*updaterCacheDirName:\s*(\S+)' | Select-Object -First 1
        if ($match) { $name = $match.Matches[0].Groups[1].Value }
    }
    return Join-Path $env:LOCALAPPDATA $name
}

# Never touch server.asar while the updater's installer runs.
function Test-UpdaterRunning {
    $prefix = $updaterDir.TrimEnd("\") + "\"
    return [bool](Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# Runs the patcher with Node.js, or with T3 Code's own Electron in Node mode.
function Invoke-Patcher([string]$T3, [string[]]$Arguments) {
    $script = Join-Path $PSScriptRoot "tools\asar-patch.mjs"
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node -and [int]((& $node.Source --version).TrimStart("v").Split(".")[0]) -ge 18) {
        $output = & $node.Source $script @Arguments
    } else {
        $env:ELECTRON_RUN_AS_NODE = "1"
        try { $output = & $T3 $script @Arguments } finally { Remove-Item Env:ELECTRON_RUN_AS_NODE }
    }
    if ($LASTEXITCODE) { throw "asar-patch.mjs $($Arguments[0]) failed." }
    return ($output -join "`n") | ConvertFrom-Json
}

function Copy-Payload {
    if ([IO.Path]::GetFullPath($PSScriptRoot) -eq [IO.Path]::GetFullPath($StateRoot)) { return }
    foreach ($item in @("install.ps1", "doctor.ps1", "uninstall.ps1", "watch.ps1", "package.json", "README.md", "LICENSE", "AGENTS.md", "runtime", "fonts", "tools", "tests")) {
        $source = Join-Path $PSScriptRoot $item
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $StateRoot -Recurse -Force }
    }
}

# T3 Code or its updater is busy. The watcher applies the patch safely as soon
# as both have exited, so an interactive install never has to wait or fail.
function Exit-Busy([string]$Message) {
    if ($Unattended) {
        Write-Host "busy: $Message"
        exit $ExitBusy
    }
    if ($NoAutoRepatch) { throw "$Message Close T3 Code and rerun install.ps1." }
    Copy-Payload
    $statePath = Join-Path $StateRoot "state.json"
    if (-not (Test-Path -LiteralPath $statePath)) {
        [ordered]@{
            pending = $true
            requestedAt = [DateTime]::UtcNow.ToString("o")
            t3Exe = $t3
            serverAsar = $serverAsar
            updaterDir = $updaterDir
            backup = Join-Path $StateRoot "server.asar.backup"
            originalSha256 = $null
            patchedSha256 = $null
            autoRepatch = $true
        } | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -LiteralPath $statePath
    }
    Register-AutoRepatch $StateRoot
    Write-Host "T3 Code is busy: $Message"
    Write-Host "Nothing to do: the patch is applied automatically as soon as T3 Code is fully closed,"
    Write-Host "and again after every T3 Code update (scheduled task '$TaskName')."
    Stop-InstallTranscript
    exit 0
}

# Stop-ScheduledTask ends conhost only; stop the watcher's PowerShell too.
function Stop-Watcher([string]$Root) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName }
    $watch = Join-Path $Root "watch.ps1"
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($watch) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Register-AutoRepatch([string]$Root) {
    $watch = Join-Path $Root "watch.ps1"
    $arguments = "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$watch`" -Root `"$Root`""
    $action = New-ScheduledTaskAction -Execute "conhost.exe" -Argument $arguments -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Stop-Watcher $Root
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description "Re-applies T3 Code Persian Typography after T3 Code updates." | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}

$t3 = Find-T3Code
if (-not $t3) { throw "T3 Code was not found. Pass -T3Exe or set T3CODE_EXE and retry." }
$installDir = Split-Path -Parent $t3
$resources = Join-Path $installDir "resources"
$serverAsar = Join-Path $resources "server.asar"
# The watcher runs this with -StateRoot; reuse the updater folder it recorded.
$recorded = Join-Path $StateRoot "state.json"
$updaterDir = if ((Test-Path -LiteralPath $recorded) -and
    (Get-Content -Raw -LiteralPath $recorded | ConvertFrom-Json).PSObject.Properties["updaterDir"]) {
    (Get-Content -Raw -LiteralPath $recorded | ConvertFrom-Json).updaterDir
} else {
    Get-UpdaterDir $installDir
}

foreach ($item in @(
    "runtime\runtime.js", "runtime\runtime.css", "fonts\Vazirmatn[wght].woff2", "tools\asar-patch.mjs",
    "doctor.ps1", "uninstall.ps1", "watch.ps1", "tests\runtime.test.cjs", "tests\asar.test.mjs", "package.json"
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $item))) { throw "Missing: $item" }
}

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
if (-not $Unattended) {
    # Keep a record even when the window closes on an error.
    Start-Transcript -LiteralPath (Join-Path $StateRoot "install.log") -Force | Out-Null
    $script:transcribing = $true
}

if (-not (Test-Path -LiteralPath $serverAsar -PathType Leaf)) { Exit-Busy "T3 Code server.asar was not found (update in progress?)." }
if (Get-T3Processes $installDir) { Exit-Busy "T3 Code is running." }
if (Test-UpdaterRunning) { Exit-Busy "the T3 Code updater is installing an update." }
$backup = Join-Path $StateRoot "server.asar.backup"
$statePath = Join-Path $StateRoot "state.json"
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } else { $null }
$autoRepatch = if ($Unattended) {
    -not ($state -and $state.PSObject.Properties["autoRepatch"] -and -not $state.autoRepatch)
} else {
    -not $NoAutoRepatch
}

# Deny writers while we read: this fails while the T3 Code updater is still
# writing server.asar, so a half-written build is never patched.
try {
    $lock = [IO.File]::Open($serverAsar, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
} catch {
    Exit-Busy "server.asar is in use (T3 Code or its updater)."
}

$temp = Join-Path $resources "server.asar.t3pt-$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $serverAsar).Hash
    if ($Unattended -and $state -and $state.patchedSha256 -and $currentHash -eq $state.patchedSha256) {
        Write-Host "already patched"
        exit 0
    }

    $current = Invoke-Patcher $t3 @("inspect", "--asar", $serverAsar)
    if ($current.patched) {
        # Reinstall over our own patch: start again from the recorded original.
        if (-not $state -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            throw "server.asar is patched but the original backup or state.json is missing."
        }
        if ($currentHash -ne $state.patchedSha256) {
            throw "server.asar is patched but does not match state.json. Reinstall T3 Code, then rerun install.ps1."
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash -ne $state.originalSha256) {
            throw "Original server.asar backup hash does not match state.json."
        }
    } else {
        # Fresh install or a T3 Code update: this build is the new original.
        Copy-Item -LiteralPath $serverAsar -Destination $backup -Force
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash -ne $currentHash) {
            throw "Backing up server.asar failed."
        }
    }
    $originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash

    $result = Invoke-Patcher $t3 @("patch", "--source", $backup, "--output", $temp)
    $lock.Dispose()
    $lock = $null
    if ((Get-T3Processes $installDir) -or (Test-UpdaterRunning)) {
        Exit-Busy "T3 Code or its updater started while patching."
    }
    # Atomic swap on the same volume. Windows refuses it while any process has
    # server.asar open, so a running T3 Code never sees a partial file.
    Add-Type -Namespace T3pt -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string existing, string replacement, int flags);
'@
    # MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH: one rename, so the
    # path always holds a complete build.
    try {
        if (-not [T3pt.Native]::MoveFileEx($temp, $serverAsar, 0x1 -bor 0x8)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
    } catch {
        # Usually T3 Code starting, or antivirus scanning a freshly written build.
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Exit-Busy "server.asar is open elsewhere, so it cannot be swapped yet ($($_.Exception.Message))."
    }
} finally {
    if ($lock) { $lock.Dispose() }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
}

$installed = Invoke-Patcher $t3 @("inspect", "--asar", $serverAsar)
if (-not $installed.patched -or $installed.runtimeVersion -ne $result.runtimeVersion) {
    throw "Installed server.asar verification failed. The original is at $backup."
}
$patchedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $serverAsar).Hash
if ($patchedHash -eq $originalHash) { throw "Patched server.asar unexpectedly matches the original." }

$state = [ordered]@{
    installedAt = [DateTime]::UtcNow.ToString("o")
    runtimeVersion = $installed.runtimeVersion
    t3Version = (Get-Item -LiteralPath $t3).VersionInfo.ProductVersion
    t3Exe = $t3
    serverAsar = $serverAsar
    updaterDir = $updaterDir
    backup = $backup
    originalSha256 = $originalHash
    patchedSha256 = $patchedHash
    autoRepatch = $autoRepatch
}
$state | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -LiteralPath $statePath
Copy-Payload

if (-not $Unattended) {
    if ($state.autoRepatch) {
        Register-AutoRepatch $StateRoot
        Write-Host "Auto re-patch after T3 Code updates: enabled (scheduled task '$TaskName')."
    } else {
        Stop-Watcher $StateRoot
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
}

Write-Host "Patched T3 Code $($state.t3Version) with Persian typography $($state.runtimeVersion)."
Write-Host "Original server.asar backup: $backup"
Stop-InstallTranscript
if ($Launch) { Start-Process -FilePath $t3 }

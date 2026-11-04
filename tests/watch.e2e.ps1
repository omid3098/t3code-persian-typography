# End-to-end check of install.ps1, watch.ps1, and uninstall.ps1 against a
# throwaway copy of the installed T3 Code. It never touches the real install;
# its scheduled task is a separate test task, removed at the end.
#   powershell -ExecutionPolicy Bypass -File tests\watch.e2e.ps1
[CmdletBinding()]
param([string]$T3Dir = (Join-Path $env:LOCALAPPDATA "Programs\t3code"))

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$realExe = Get-ChildItem -LiteralPath $T3Dir -Filter "T3 Code*.exe" -File | Where-Object { $_.Name -notlike "Uninstall*" } | Select-Object -First 1
if (-not $realExe) { throw "T3 Code was not found in $T3Dir." }

$fake = Join-Path ([IO.Path]::GetTempPath()) "t3pt-watch-e2e"
if (Test-Path -LiteralPath $fake) { Remove-Item -LiteralPath $fake -Recurse -Force }
$install = Join-Path $fake "Programs\t3code"
$resources = New-Item -ItemType Directory -Force (Join-Path $install "resources")
# Stand-in executables are copies of PING.EXE: Electron cannot run outside its
# own folder, and ping really stays alive. A distinct name keeps a running
# real T3 Code from counting as "running".
$standIn = Join-Path $env:SystemRoot "System32\PING.EXE"
$fakeExe = Join-Path $install "T3 Code (E2E).exe"
Copy-Item -LiteralPath $standIn -Destination $fakeExe
$serverAsar = Join-Path $resources "server.asar"
$pristine = Join-Path $fake "pristine.asar"
# The pristine build: the real server.asar, or its recorded original when the
# real install is already patched.
$realAsar = Join-Path $T3Dir "resources\server.asar"
$inspect = (& node (Join-Path $repo "tools\asar-patch.mjs") inspect --asar $realAsar) | ConvertFrom-Json
if ($inspect.patched) { $realAsar = Join-Path $env:LOCALAPPDATA "T3CodePersianTypography\server.asar.backup" }
Copy-Item -LiteralPath $realAsar -Destination $pristine
Copy-Item -LiteralPath $pristine -Destination $serverAsar
$pristineHash = (Get-FileHash -LiteralPath $pristine).Hash

$realLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $fake
$stateRoot = Join-Path $fake "T3CodePersianTypography"
$testTask = "T3CodePersianTypography-E2E"

function Get-Watcher {
    $watch = Join-Path $stateRoot "watch.ps1"
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($watch) }
}

function Get-State { Get-Content -Raw -LiteralPath (Join-Path $stateRoot "state.json") | ConvertFrom-Json }
$script:repatches = 0
# Re-patched and the watcher's install run has fully finished.
function Wait-Repatched([string]$What) {
    $script:repatches++
    Wait-Until { (Test-Patched) -and @(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "re-patched").Count -ge $script:repatches } 60 $What
}
# Reads with full sharing like the watcher, so checking never blocks a swap.
function Get-Sha([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]"ReadWrite, Delete")
    } catch {
        return $null
    }
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") } finally { $sha.Dispose() }
    } finally {
        $stream.Dispose()
    }
}
function Test-Patched {
    $hash = Get-Sha $serverAsar
    return $hash -and $hash -eq (Get-State).patchedSha256
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds, [string]$What) {
    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out: $What"
}
# Mimics the updater: the new build appears under the final name.
function Invoke-FakeUpdate {
    $staging = "$serverAsar.update"
    Copy-Item -LiteralPath $pristine -Destination $staging
    Move-Item -LiteralPath $staging -Destination $serverAsar -Force
}

# A process that stays alive for about $Seconds at the given path, standing
# in for T3 Code or its updater.
function Start-FakeProcess([string]$Path, [int]$Seconds) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
        Copy-Item -LiteralPath $standIn -Destination $Path
    }
    $process = Start-Process -FilePath $Path -ArgumentList @("-n", ($Seconds + 1), "127.0.0.1") -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) { throw "Stand-in process $Path exited early." }
    return $process
}

# Holds server.asar open the way Electron does (read, sharing read and write
# but not delete), standing in for a running T3 Code that has loaded it.
function Start-Holder([int]$Seconds, [int]$DelayMs = 0) {
    $code = "Start-Sleep -Milliseconds $DelayMs; `$f = [IO.File]::Open('$serverAsar', 'Open', 'Read', 'ReadWrite'); Start-Sleep -Seconds $Seconds; `$f.Dispose()"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    return Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) -WindowStyle Hidden -PassThru
}

# Long enough to cover every quiet period plus an install run.
function Assert-NotPatchedFor([int]$Seconds, [string]$What) {
    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        $hash = Get-Sha $serverAsar
        if ($hash -and $hash -ne $pristineHash) { throw $What }
        Start-Sleep -Milliseconds 500
    }
}

try {
    Write-Host "0. install while T3 Code is running (hand-off to the watcher)"
    $running = Start-FakeProcess $fakeExe 40
    $holder = Start-Holder 38
    $output = & (Join-Path $repo "install.ps1") -TaskName $testTask *>&1 | Out-String
    if ($output -notmatch "applied automatically") { throw "Install did not hand off to the watcher: $output" }
    if (-not (Get-State).pending) { throw "State is not pending." }
    if ((Get-ScheduledTask -TaskName $testTask).State -ne "Running") { throw "Watcher task is not running." }
    if (-not (Test-Path -LiteralPath (Join-Path $stateRoot "install.log"))) { throw "install.log was not written." }
    Wait-Until { (Test-Path (Join-Path $stateRoot "watch.log")) -and (Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "watcher started" -Quiet) } 20 "watcher start"
    Assert-NotPatchedFor 25 "Swapped server.asar while T3 Code had it open."
    $holder.WaitForExit()
    $running.WaitForExit()
    $closed = [DateTime]::Now
    Wait-Repatched "patch after T3 Code closed"
    Write-Host "   patched $([int]([DateTime]::Now - $closed).TotalSeconds) s after T3 Code closed"
    if ((Get-State).PSObject.Properties["pending"]) { throw "State is still pending." }

    Write-Host "1. update while T3 Code is closed"
    $started = [DateTime]::Now
    Invoke-FakeUpdate
    Wait-Repatched "re-patch after update"
    Write-Host "   re-patched after $([int]([DateTime]::Now - $started).TotalSeconds) s (quiet period included)"
    if ((Get-Sha (Get-State).backup) -ne $pristineHash) { throw "Backup is not the new original." }

    Write-Host "2. 'Restart to update': installer exits and relaunches T3 Code"
    $updater = Start-FakeProcess (Join-Path $fake "t3code-updater\pending\T3-Code-Setup.exe") 25
    Invoke-FakeUpdate
    # Prepared meanwhile, but never written while the installer runs.
    Assert-NotPatchedFor 18 "Touched server.asar while the updater was running."
    if (-not (Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "updater is installing" -Quiet)) { throw "Updater was not detected." }
    $updater.WaitForExit()
    $exited = [DateTime]::Now
    # The relaunched T3 Code opens server.asar about a second later.
    $running = Start-FakeProcess $fakeExe 10
    $holder = Start-Holder 8 200
    Wait-Repatched "swap as the installer exits"
    $line = @(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "re-patched")[-1].Line
    $swapped = [DateTime]::ParseExact($line.Substring(1, 23), "yyyy-MM-dd HH:mm:ss.fff", $null)
    Write-Host "   swapped $([int]($swapped - $exited).TotalMilliseconds) ms after the installer exited, before T3 Code opened it"
    $holder.WaitForExit()
    $running.WaitForExit()

    Write-Host "3. 'Restart to update' where T3 Code opens the new build first, and a helper outlives it"
    $updater = Start-FakeProcess (Join-Path $fake "t3code-updater\pending\T3-Code-Setup.exe") 20
    Invoke-FakeUpdate
    Start-Sleep -Seconds 12
    $holder = Start-Holder 30
    # Like T3 Code's device daemon: T3 Code's executable, alive after T3 Code
    # closed, without server.asar open.
    $running = Start-FakeProcess $fakeExe 70
    $updater.WaitForExit()
    Assert-NotPatchedFor 12 "Swapped server.asar while T3 Code had it open."
    Wait-Until { Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "opened the new build first" -Quiet } 10 "deferred until T3 Code closes"
    $holder.WaitForExit()
    Wait-Repatched "patch after T3 Code closed"
    if ($running.HasExited) { throw "Waited for the helper instead of retrying the swap." }
    Stop-Process -Id $running.Id -Force
    Write-Host "   left alone while T3 Code had it open, patched once it closed although a helper still ran"

    Write-Host "4. unknown writer still writing server.asar"
    $bytes = [IO.File]::ReadAllBytes($pristine)
    $stream = [IO.File]::Open($serverAsar, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $half = [int]($bytes.Length / 2)
        $stream.Write($bytes, 0, $half)
        $stream.Flush()
        $before = @(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "re-patched").Count
        Start-Sleep -Seconds 4
        $after = @(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "re-patched").Count
        if ($after -ne $before) { throw "Patched a half-written server.asar." }
        $stream.Write($bytes, $half, $bytes.Length - $half)
    } finally {
        $stream.Dispose()
    }
    Wait-Repatched "re-patch after the writer closed"
    Write-Host "   waited for the writer, then re-patched"

    Write-Host "5. newer runtime installed while T3 Code has server.asar open"
    $running = Start-FakeProcess $fakeExe 30
    $holder = Start-Holder 28
    Start-Sleep -Seconds 2
    foreach ($file in @("package.json", "runtime\runtime.js")) {
        $path = Join-Path $stateRoot $file
        $text = [IO.File]::ReadAllText($path) -replace '"1\.\d+\.\d+"', '"9.9.9"'
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    }
    # install.ps1 restarts the watcher after copying a new runtime; do the same.
    Stop-ScheduledTask -TaskName $testTask
    Get-Watcher | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-ScheduledTask -TaskName $testTask
    Wait-Until { Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "runtime 9.9.9 prepared" -Quiet } 30 "upgrade prepared"
    $before = Get-Sha $serverAsar
    Start-Sleep -Seconds 5
    if ((Get-Sha $serverAsar) -ne $before) { throw "Swapped the runtime while T3 Code had server.asar open." }
    $holder.WaitForExit()
    $running.WaitForExit()
    Wait-Repatched "runtime upgrade after T3 Code closed"
    if ((Get-State).runtimeVersion -ne "9.9.9") { throw "Runtime version was not updated." }
    if ((Get-Sha (Get-State).backup) -ne $pristineHash) { throw "Backup changed during the runtime upgrade." }
    Write-Host "   waited for T3 Code to release server.asar, then swapped in the new runtime"

    Write-Host "6. update prepared ahead from the downloaded installer"
    # A stand-in for the NSIS installer: the app as an embedded 7z archive.
    $stage = New-Item -ItemType Directory -Force (Join-Path $fake "installer-stage\resources")
    Copy-Item -LiteralPath $pristine -Destination (Join-Path $stage "server.asar")
    $sevenZip = Join-Path $fake "app.7z"
    & (Join-Path $env:SystemRoot "System32\tar.exe") -c --format 7zip --options 7zip:compression=store -f $sevenZip -C (Split-Path -Parent $stage) resources/server.asar
    if ($LASTEXITCODE) { throw "Could not build the stand-in installer." }
    $pending = Join-Path $fake "t3code-updater\pending"
    $out = [IO.File]::Create((Join-Path $pending "T3-Code-Next.exe"))
    try {
        $out.Write([byte[]](0x4D, 0x5A), 0, 2)
        $out.Write((New-Object byte[] 65536), 0, 65536)
        $in = [IO.File]::OpenRead($sevenZip)
        try { $in.CopyTo($out) } finally { $in.Dispose() }
        $out.Write((New-Object byte[] 4096), 0, 4096)
    } finally {
        $out.Dispose()
    }
    Set-Content -LiteralPath (Join-Path $pending "update-info.json") -Value '{"fileName":"T3-Code-Next.exe"}'
    Wait-Until { Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "patched build is ready" -Quiet } 60 "update prepared ahead"
    $opened = @(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "opened the new build first").Count
    # The installer exits about two seconds after writing server.asar, too
    # soon to patch the new server.asar itself; T3 Code opens it right away.
    $updater = Start-FakeProcess (Join-Path $pending "T3-Code-Setup.exe") 3
    Invoke-FakeUpdate
    $updater.WaitForExit()
    $exited = [DateTime]::Now
    $holder = Start-Holder 8
    Wait-Repatched "swap of the update prepared ahead"
    if (-not (Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "update prepared ahead; ready to swap" -Quiet)) { throw "The update prepared ahead was not used." }
    if (@(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "opened the new build first").Count -ne $opened) { throw "T3 Code opened the new build first." }
    $line = @(Select-String -LiteralPath (Join-Path $stateRoot "watch.log") -Pattern "re-patched")[-1].Line
    $swapped = [DateTime]::ParseExact($line.Substring(1, 23), "yyyy-MM-dd HH:mm:ss.fff", $null)
    Write-Host "   swapped $([int]($swapped - $exited).TotalMilliseconds) ms after the installer exited"
    $holder.WaitForExit()

    Write-Host "7. uninstall stops the watcher and restores the original"
    $finalLog = Get-Content -LiteralPath (Join-Path $stateRoot "watch.log")
    & (Join-Path $repo "uninstall.ps1") | Out-Null
    Wait-Until { -not (Get-Watcher) } 10 "uninstall stops the watcher"
    if ((Get-Sha $serverAsar) -ne $pristineHash) { throw "Uninstall did not restore the original." }

    Write-Host "Watch end-to-end checks passed."
    Write-Host "--- watch.log"
    $finalLog | Write-Host
} catch {
    $log = Join-Path $stateRoot "watch.log"
    if (Test-Path -LiteralPath $log) { Write-Host "--- watch.log"; Get-Content -LiteralPath $log | Write-Host }
    throw
} finally {
    if (Get-ScheduledTask -TaskName $testTask -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $testTask
        Unregister-ScheduledTask -TaskName $testTask -Confirm:$false
    }
    Get-Watcher | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $realLocalAppData
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
}

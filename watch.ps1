# Started at logon by the T3CodePersianTypography scheduled task. Re-applies
# the patch after a T3 Code update replaces server.asar.
#
# "Restart to update" relaunches T3 Code right after the updater's installer
# exits, so the watcher has the patched build ready before that: as soon as
# the updater has downloaded an update, it builds the patch from the server.asar
# inside the downloaded installer. While the installer runs, it only checks
# that the new server.asar has exactly that build's SHA-256 (reading with full
# sharing, which never blocks the installer); without a build prepared ahead
# it patches the new server.asar itself. It swaps the prepared build in the
# instant the installer exits. The swap is a single MoveFileEx that Windows
# refuses while any process has server.asar open: if T3 Code opened the new
# build first, nothing changes and the watcher retries until T3 Code closes.
# The watcher never writes server.asar while the installer runs and never
# closes T3 Code.
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA "T3CodePersianTypography"),
    # Without a running installer, seconds the install folder must stay
    # unchanged before an unknown writer is assumed finished.
    [int]$QuietSeconds = 10,
    # Seconds a new server.asar must keep the same size and time before it is read.
    [int]$StableSeconds = 2,
    # Seconds between swap attempts while T3 Code may hold server.asar open.
    [int]$RetrySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$statePath = Join-Path $Root "state.json"
$logPath = Join-Path $Root "watch.log"

function Write-Log([string]$Message) {
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 256KB) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
    }
    Add-Content -LiteralPath $logPath -Encoding utf8 -Value "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff'))] $Message"
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    return Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
}

# Metadata only: never opens server.asar.
function Get-Stamp([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    return "$($item.Length)|$($item.LastWriteTimeUtc.Ticks)|$($item.CreationTimeUtc.Ticks)"
}

# Full sharing: never blocks the updater from writing or deleting the file.
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

function Get-UpdaterDir([string]$InstallDir) {
    $name = "t3code-updater"
    $yml = Join-Path $InstallDir "resources\app-update.yml"
    if (Test-Path -LiteralPath $yml) {
        $match = Select-String -LiteralPath $yml -Pattern '^\s*updaterCacheDirName:\s*(\S+)' | Select-Object -First 1
        if ($match) { $name = $match.Matches[0].Groups[1].Value }
    }
    return Join-Path $env:LOCALAPPDATA $name
}

function Get-ProcessesUnder([string]$Prefix, [string[]]$Names) {
    $processes = if ($Names) { Get-Process -Name $Names -ErrorAction SilentlyContinue } else { Get-Process }
    foreach ($process in $processes) {
        $path = $null
        try { $path = $process.Path } catch { }
        if ($path -and $path.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -and
            -not ([IO.Path]::GetFileName($path) -like "Uninstall*")) { $process }
    }
}

function Invoke-Prepare([string]$Source = $serverAsar) {
    return Invoke-Patcher @("prepare", "--source", $Source, "--out-dir", $prepDir)
}

function Invoke-Patcher([string[]]$Command) {
    $arguments = @(Join-Path $Root "tools\asar-patch.mjs") + $Command
    $ErrorActionPreference = "Continue"
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $output = & $node.Source @arguments 2>&1 | ForEach-Object { "$_" }
    } else {
        $env:ELECTRON_RUN_AS_NODE = "1"
        try { $output = & $state.t3Exe @arguments 2>&1 | ForEach-Object { "$_" } } finally { Remove-Item Env:ELECTRON_RUN_AS_NODE }
    }
    if ($LASTEXITCODE) { throw ($output -join " ") }
    return ($output | Where-Object { $_.StartsWith("{") } | Select-Object -Last 1) | ConvertFrom-Json
}

Add-Type -Namespace T3pt -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string existing, string replacement, int flags);
'@
# MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH: one atomic rename.
$MoveReplace = 0x1 -bor 0x8

# $Expected: the content server.asar must still have, normally the source the
# prepared build was made from (for a runtime upgrade, our previous patch).
function Invoke-Commit([bool]$Verified, [string]$Expected = $prepMeta.sourceSha256) {
    $key = "$(Get-Stamp $serverAsar)|$Expected"
    if (-not $Verified -and $key -ne $script:hashedKey) {
        if ((Get-Sha $serverAsar) -ne $Expected) { return "stale" }
        # Retries on the same file skip the hash.
        $script:hashedKey = $key
    }
    if (-not [T3pt.Native]::MoveFileEx((Join-Path $prepDir "prepared.asar"), $serverAsar, $MoveReplace)) { return "busy" }
    $script:swappedAt = [DateTime]::Now
    [void][T3pt.Native]::MoveFileEx((Join-Path $prepDir "original.asar"), $backup, $MoveReplace)
    [ordered]@{
        installedAt = [DateTime]::UtcNow.ToString("o")
        runtimeVersion = $prepMeta.runtimeVersion
        t3Version = (Get-Item -LiteralPath $state.t3Exe).VersionInfo.ProductVersion
        t3Exe = $state.t3Exe
        serverAsar = $serverAsar
        updaterDir = $updaterDir
        backup = $backup
        originalSha256 = $prepMeta.sourceSha256
        patchedSha256 = $prepMeta.preparedSha256
        autoRepatch = $true
    } | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -LiteralPath $statePath
    Remove-Item -LiteralPath (Join-Path $prepDir "prepared.json") -Force -ErrorAction SilentlyContinue
    return "done"
}

# The updater downloaded an update: build its patch from the installer now,
# long before "Restart to update" runs it.
function Invoke-PrepareNext {
    try {
        $name = [string](Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json).fileName
        if (-not $name -or $name -ne [IO.Path]::GetFileName($name)) { return $null }
        $installer = Join-Path (Split-Path -Parent $infoPath) $name
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { return $null }
        $result = Invoke-Patcher @("prepare-installer", "--installer", $installer, "--out-dir", $nextDir)
        Write-Log "update $name downloaded; its patched build is ready"
        return $result
    } catch {
        Write-Log "could not prepare the downloaded update ahead; it is patched after it installs: $($_.Exception.Message)"
        return $null
    }
}

# server.asar has exactly the build prepared ahead: make it the prepared build.
function Use-NextBuild {
    New-Item -ItemType Directory -Force -Path $prepDir | Out-Null
    foreach ($name in @("original.asar", "prepared.asar", "prepared.json")) {
        if (-not [T3pt.Native]::MoveFileEx((Join-Path $nextDir $name), (Join-Path $prepDir $name), $MoveReplace)) { return $false }
    }
    return $true
}

# Waiting for T3 Code to release server.asar: a cheap by-name check, and every
# $RetrySeconds a real swap attempt. A helper run with T3 Code's executable
# (such as its device daemon) can outlive T3 Code without opening server.asar,
# so only the refused rename shows that T3 Code still holds it.
function Test-Waiting {
    return $blockedByT3 -and [DateTime]::Now -lt $retrySwapAt -and [bool]@(Get-ProcessesUnder $installPrefix $t3Names)
}

# One watcher per state folder.
$rootKey = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash(
    [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant()))).Replace("-", "").Substring(0, 16)
$created = $false
$mutex = New-Object Threading.Mutex($true, "Local\T3CodePersianTypographyWatcher-$rootKey", [ref]$created)
if (-not $created) { exit 0 }

$state = Read-State
if (-not $state -or ($state.PSObject.Properties["autoRepatch"] -and -not $state.autoRepatch)) { exit 0 }

$serverAsar = $state.serverAsar
$backup = Join-Path $Root "server.asar.backup"
$installDir = Split-Path -Parent (Split-Path -Parent $serverAsar)
$installPrefix = $installDir.TrimEnd("\") + "\"
$updaterDir = if ($state.PSObject.Properties["updaterDir"]) { $state.updaterDir } else { Get-UpdaterDir $installDir }
$updaterPrefix = $updaterDir.TrimEnd("\") + "\"
$t3Names = @([IO.Path]::GetFileNameWithoutExtension($state.t3Exe), "t3-resource-monitor")
# MoveFileEx is atomic only within one volume.
$prepDir = Join-Path $Root "prepared"
if ([IO.Path]::GetPathRoot($prepDir) -ne [IO.Path]::GetPathRoot($serverAsar)) {
    $prepDir = Join-Path (Split-Path -Parent $serverAsar) ".t3pt-prepared"
}
# The next update's build, prepared from its downloaded installer.
$nextDir = "$prepDir-next"
$infoPath = Join-Path $updaterDir "pending\update-info.json"

# Watch the parent of the install folder (the updater may recreate the folder
# itself) with no name filter: .NET Framework misses a rename onto
# server.asar when a filter is set.
$watchRoot = Split-Path -Parent $installDir
$watcher = New-Object IO.FileSystemWatcher($watchRoot, "*")
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [IO.NotifyFilters]"FileName, DirectoryName, LastWrite, Size, CreationTime"
function Test-InInstall([string]$Name) {
    return $Name -and ([IO.Path]::Combine($watchRoot, $Name) + "\").StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)
}

Write-Log "watcher started for $serverAsar"
$patchedStamp = $null   # stamp of a server.asar known to be our patched build
$checkedStamp = $null   # stamp already compared against state.patchedSha256
$lastStamp = $null
$stampSince = [DateTime]::Now
$prepMeta = $null
$prepStamp = $null      # stamp the prepared build was made from
$swappedAt = [DateTime]::MinValue
$upgradeMeta = $null    # prepared build for a newer runtime on an unchanged T3 Code
$sawUpdater = $false
$blockedByT3 = $false
$announced = $false
$lastFolderChange = [DateTime]::MinValue
$retryAt = [DateTime]::MinValue
$retrySwapAt = [DateTime]::MinValue
$hashedKey = $null      # "<stamp>|<sha>" of a server.asar already hashed
$nextMeta = $null       # the next update's prepared build
if (Test-Path -LiteralPath (Join-Path $nextDir "prepared.json") -PathType Leaf) {
    $nextMeta = Get-Content -Raw -LiteralPath (Join-Path $nextDir "prepared.json") | ConvertFrom-Json
}
# A download from before the watcher started is not prepared again.
$nextSeen = "$(Get-Stamp $infoPath)|$((Get-Content -Raw -LiteralPath (Join-Path $Root "package.json") | ConvertFrom-Json).version)"
$nextTriedAt = [DateTime]::MinValue

try {
    while ($true) {
        $state = Read-State
        if (-not $state) {
            Write-Log "state.json removed; watcher exiting"
            break
        }

        # Short enough to notice a finished download before "Restart to update".
        $sleep = 5000
        $stamp = Get-Stamp $serverAsar
        if ($stamp -ne $lastStamp) {
            $lastStamp = $stamp
            $stampSince = [DateTime]::Now
            $blockedByT3 = $false
            $upgradeMeta = $null
        }
        $wantVersion = (Get-Content -Raw -LiteralPath (Join-Path $Root "package.json") | ConvertFrom-Json).version

        $infoStamp = Get-Stamp $infoPath
        if ($infoStamp -and "$infoStamp|$wantVersion" -ne $nextSeen -and -not @(Get-ProcessesUnder $updaterPrefix $null)) {
            $nextSeen = "$infoStamp|$wantVersion"
            $nextMeta = Invoke-PrepareNext
            continue
        }

        if ($stamp -and $stamp -eq $patchedStamp) {
            $sawUpdater = $false
            $announced = $false
            # A newer runtime was installed while T3 Code had server.asar open:
            # rebuild from the recorded original and swap it in once T3 Code
            # releases the file.
            $haveVersion = if ($state.PSObject.Properties["runtimeVersion"]) { $state.runtimeVersion } else { $null }
            $canUpgrade = $haveVersion -and $state.PSObject.Properties["originalSha256"] -and $state.originalSha256 -and
                (Test-Path -LiteralPath $backup -PathType Leaf)
            if ($canUpgrade -and $haveVersion -ne $wantVersion -and [DateTime]::Now -ge $retryAt) {
                $sleep = 2000
                if (-not (Test-Waiting)) {
                    if (-not $upgradeMeta) {
                        $result = $null
                        try { $result = Invoke-Prepare $backup } catch { $result = $null }
                        if ($result -and -not $result.PSObject.Properties["incomplete"] -and
                            -not $result.PSObject.Properties["alreadyPatched"] -and $result.sourceSha256 -eq $state.originalSha256 -and
                            $result.runtimeVersion -eq $wantVersion) {
                            $upgradeMeta = $result
                            Write-Log "runtime $wantVersion prepared; it replaces $haveVersion once T3 Code releases server.asar"
                        } else {
                            Write-Log "could not prepare runtime $wantVersion from the backup; retrying in 10 minutes"
                            $retryAt = [DateTime]::Now.AddMinutes(10)
                        }
                    }
                    if ($upgradeMeta) {
                        $prepMeta = $upgradeMeta
                        $outcome = Invoke-Commit $false $state.patchedSha256
                        if ($outcome -eq "done") {
                            Write-Log "re-patched: runtime updated to $wantVersion."
                            $patchedStamp = Get-Stamp $serverAsar
                            $checkedStamp = $patchedStamp
                            $lastStamp = $patchedStamp
                            $upgradeMeta = $null
                            $blockedByT3 = $false
                            continue
                        } elseif ($outcome -eq "stale") {
                            $upgradeMeta = $null
                            $patchedStamp = $null
                        } elseif (@(Get-ProcessesUnder $installPrefix $t3Names)) {
                            $blockedByT3 = $true
                            $retrySwapAt = [DateTime]::Now.AddSeconds($RetrySeconds)
                        } else {
                            $sleep = 1000
                        }
                    }
                }
            } else {
                $blockedByT3 = $false
            }
        } elseif (-not $stamp) {
            $lastFolderChange = [DateTime]::Now
            $sleep = 500
        } elseif ($stamp -ne $checkedStamp -and $state.patchedSha256 -and
            ([DateTime]::Now - $stampSince).TotalSeconds -ge $StableSeconds -and
            (Get-Sha $serverAsar) -eq $state.patchedSha256) {
            $checkedStamp = $stamp
            $patchedStamp = $stamp
            continue
        } elseif (Test-Waiting) {
            $sleep = 2000
        } else {
            $sleep = 500
            # The update prepared ahead: once server.asar has exactly that
            # build, it is ready to swap, with no stability wait.
            if ($nextMeta -and $prepStamp -ne $stamp -and $nextMeta.runtimeVersion -eq $wantVersion -and
                $stamp.StartsWith("$($nextMeta.sourceSize)|") -and [DateTime]::Now -ge $nextTriedAt) {
                $nextTriedAt = [DateTime]::Now.AddMilliseconds(500)
                if ((Get-Sha $serverAsar) -eq $nextMeta.sourceSha256 -and (Get-Stamp $serverAsar) -eq $stamp) {
                    if (Use-NextBuild) {
                        $prepMeta = $nextMeta
                        $prepStamp = $stamp
                        $hashedKey = "$stamp|$($nextMeta.sourceSha256)"
                        Write-Log "the new server.asar is the update prepared ahead; ready to swap"
                    } else {
                        Write-Log "could not use the update prepared ahead; patching the new server.asar instead"
                    }
                    $nextMeta = $null
                } elseif (([DateTime]::Now - $stampSince).TotalSeconds -ge $StableSeconds) {
                    # A different build: patch it from server.asar instead.
                    $nextMeta = $null
                }
            }
            if ($stamp -ne $checkedStamp -and ([DateTime]::Now - $stampSince).TotalSeconds -ge $StableSeconds) { $checkedStamp = $stamp }
            if (-not $announced -and $checkedStamp -eq $stamp -and $prepStamp -ne $stamp) {
                Write-Log "new server.asar detected; preparing the patch"
                $announced = $true
            }
            $updaters = @(Get-ProcessesUnder $updaterPrefix $null)

            # Prepare as soon as the new build is stable, even while the
            # installer still runs: reading never blocks it.
            if ($checkedStamp -eq $stamp -and $prepStamp -ne $stamp -and [DateTime]::Now -ge $retryAt) {
                try {
                    $result = Invoke-Prepare
                    if ($result.PSObject.Properties["alreadyPatched"] -and $result.alreadyPatched) {
                        $patchedStamp = $stamp
                        continue
                    }
                    if ($result.PSObject.Properties["incomplete"]) {
                        # Still being written; read it again shortly.
                        $retryAt = [DateTime]::Now.AddSeconds(2)
                    } else {
                        $prepMeta = $result
                        $prepStamp = $stamp
                    }
                } catch {
                    Write-Log "preparing the patch failed; retrying in 10 minutes: $($_.Exception.Message)"
                    $retryAt = [DateTime]::Now.AddMinutes(10)
                }
            }

            if ($updaters) {
                # Installer running: never write; wait for it to exit.
                if (-not $sawUpdater) { Write-Log "T3 Code updater is installing; waiting for it to finish" }
                $sawUpdater = $true
                if ($prepStamp -ne $stamp) {
                    [void]$updaters[0].WaitForExit(250)
                    continue
                }
                # Prepared and verified against the build's own hashes: block
                # until the installer exits, then swap at once, before the
                # relaunched T3 Code opens server.asar.
                while (-not $updaters[0].WaitForExit(1000)) {
                    if ((Get-Stamp $serverAsar) -ne $prepStamp) { break }
                }
                $exitedAt = [DateTime]::Now
                if (-not @($updaters | Where-Object { -not $_.HasExited }) -and (Get-Stamp $serverAsar) -eq $prepStamp) {
                    $outcome = Invoke-Commit $true
                    if ($outcome -eq "done") {
                        Write-Log "re-patched: Patched T3 Code $((Read-State).t3Version) with Persian typography $($prepMeta.runtimeVersion) (swapped $([int]($script:swappedAt - $exitedAt).TotalMilliseconds) ms after the installer exited)."
                        $patchedStamp = Get-Stamp $serverAsar
                        $checkedStamp = $patchedStamp
                        $prepStamp = $null
                    }
                }
                continue
            }

            if (-not $sawUpdater -and ([DateTime]::Now - $lastFolderChange).TotalSeconds -lt $QuietSeconds) {
                # Something else changed the install folder; let it settle.
            } elseif ($prepStamp -eq $stamp -and [DateTime]::Now -ge $retryAt) {
                $outcome = Invoke-Commit $false
                if ($outcome -eq "done") {
                    Write-Log "re-patched: Patched T3 Code $((Read-State).t3Version) with Persian typography $($prepMeta.runtimeVersion)."
                    $patchedStamp = Get-Stamp $serverAsar
                    $checkedStamp = $patchedStamp
                    $prepStamp = $null
                    continue
                } elseif ($outcome -eq "stale") {
                    $prepStamp = $null
                    continue
                } elseif (@(Get-ProcessesUnder $installPrefix $t3Names)) {
                    if (-not $blockedByT3) { Write-Log "T3 Code opened the new build first; the patch applies when T3 Code closes" }
                    $blockedByT3 = $true
                    $retrySwapAt = [DateTime]::Now.AddSeconds($RetrySeconds)
                } else {
                    # Briefly held elsewhere, e.g. by antivirus; retry shortly.
                    $sleep = 1000
                }
            }
        }

        try {
            $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, $sleep)
            if (-not $change.TimedOut -and ((Test-InInstall $change.Name) -or (Test-InInstall $change.OldName))) {
                $lastFolderChange = [DateTime]::Now
            }
        } catch {
            Start-Sleep -Seconds 1
        }
    }
} catch {
    Write-Log "watcher stopped by an error (the scheduled task restarts it): $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    throw
} finally {
    $watcher.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

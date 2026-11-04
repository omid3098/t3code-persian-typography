[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA "T3CodePersianTypography")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$statePath = Join-Path $Root "state.json"
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "No installation state found. Run install.ps1 first."
}
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
if ($state.PSObject.Properties["pending"] -and $state.pending) {
    $task = Get-ScheduledTask -TaskName "T3CodePersianTypography" -ErrorAction SilentlyContinue
    if (-not $task -or $task.State -ne "Running") { throw "Install is pending but the auto re-patch watcher is not running. Rerun install.ps1." }
    Write-Host "Pending: the watcher applies the patch as soon as T3 Code is fully closed."
    exit 0
}

foreach ($item in @(
    "runtime\runtime.js", "runtime\runtime.css", "fonts\Vazirmatn[wght].woff2", "tools\asar-patch.mjs",
    "tests\runtime.test.cjs", "tests\asar.test.mjs", "install.ps1", "uninstall.ps1", "watch.ps1", "package.json"
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $item))) { throw "Missing: $item" }
}

function Invoke-Node([string[]]$Arguments) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $output = & $node.Source @Arguments
    } else {
        $env:ELECTRON_RUN_AS_NODE = "1"
        # The pipe makes PowerShell wait for this GUI executable and set $LASTEXITCODE.
        try { $output = & $state.t3Exe @Arguments | ForEach-Object { "$_" } } finally { Remove-Item Env:ELECTRON_RUN_AS_NODE }
    }
    if ($LASTEXITCODE) { throw "Check failed: $($Arguments -join ' ')" }
    return $output
}

Invoke-Node @((Join-Path $Root "tests\runtime.test.cjs")) | Write-Host
Invoke-Node @((Join-Path $Root "tests\asar.test.mjs")) | Write-Host

if (-not (Test-Path -LiteralPath $state.serverAsar -PathType Leaf)) { throw "T3 Code server.asar is missing." }
if (-not (Test-Path -LiteralPath $state.backup -PathType Leaf)) { throw "Original server.asar backup is missing." }

$patchedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $state.serverAsar).Hash
if ($patchedHash -ne $state.patchedSha256) {
    throw "T3 Code server.asar changed, probably after an update. Close T3 Code and rerun install.ps1."
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $state.backup).Hash -ne $state.originalSha256) {
    throw "Original server.asar backup hash does not match state.json."
}

$inspect = (Invoke-Node @((Join-Path $Root "tools\asar-patch.mjs"), "inspect", "--asar", $state.serverAsar)) -join "`n" | ConvertFrom-Json
if (-not $inspect.patched) { throw "server.asar index.html does not load the runtime." }
foreach ($payload in @("runtime.js", "runtime.css", "Vazirmatn.woff2")) {
    if ($inspect.payload -notcontains $payload) { throw "Patched server.asar is missing $payload." }
}
$version = (Get-Content -Raw -LiteralPath (Join-Path $Root "package.json") | ConvertFrom-Json).version
if ($inspect.runtimeVersion -ne $version) {
    throw "Installed runtime $($inspect.runtimeVersion) differs from $version. Rerun install.ps1."
}

if (-not $state.PSObject.Properties["autoRepatch"] -or $state.autoRepatch) {
    $task = Get-ScheduledTask -TaskName "T3CodePersianTypography" -ErrorAction SilentlyContinue
    if (-not $task) { throw "Auto re-patch task is missing. Rerun install.ps1." }
    if ($task.State -ne "Running") { throw "Auto re-patch task is $($task.State), not Running. Rerun install.ps1." }
    Write-Host "Auto re-patch watcher is running."
}

$signature = Get-AuthenticodeSignature -LiteralPath $state.t3Exe
if ($signature.Status -ne "Valid") { throw "T3 Code executable signature is not valid: $($signature.Status)" }

Write-Host "Doctor passed: T3 Code $($state.t3Version) is patched; backup, payload, tests, and executable signature are valid."

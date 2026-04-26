# reset.ps1 — wipe codetainyrrr Docker volumes and start fresh
#
# USAGE:
#   .\reset.ps1              # full reset — wipes the home volume
#   .\reset.ps1 -PluginsOnly # plugins only — clears plugin sentinels, keeps tools
#
# Your SOURCE CODE and PROJECT FILES are NOT touched.

param(
    [Alias("Plugins")]
    [switch]$PluginsOnly,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Ignored = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Write-Warn($msg)  { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "  x $msg" -ForegroundColor Red }
function Write-Info($msg)  { Write-Host "  > $msg" -ForegroundColor Cyan }
function Write-Dim($msg)   { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Banner($msg){ Write-Host $msg -ForegroundColor Red }

# ── auto-detect project names from volumes ────────────────────────────────────
$AllVols = docker volume ls -q 2>$null
$DetectedNames = @(
    $AllVols | Where-Object { $_ -match "_ct_home$" } |
    ForEach-Object { $_ -replace "_ct_home$", "" } |
    Sort-Object -Unique
)

if ($DetectedNames.Count -eq 0) {
    Write-Host "No codetainyrrr volumes found. Nothing to reset."
    exit 0
}

# If multiple projects found, let user pick
$ProjectName = ""
if ($DetectedNames.Count -gt 1) {
    Write-Host ""
    Write-Host "Multiple codetainyrrr installations found:" -ForegroundColor White
    for ($i = 0; $i -lt $DetectedNames.Count; $i++) {
        $name = $DetectedNames[$i]
        Write-Host ("  {0}) " -f ($i + 1)) -NoNewline
        Write-Host $name -ForegroundColor Cyan
    }
    Write-Host ""
    $choice = Read-Host "  Which installation to reset? [1]"
    if ($choice -eq "") { $choice = "1" }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $DetectedNames.Count) {
        Write-Err "Invalid choice."; exit 1
    }
    $ProjectName = $DetectedNames[$idx]
} else {
    $ProjectName = $DetectedNames[0]
}

# ── gather target info ────────────────────────────────────────────────────────
$ImageName = "codetainyrrr:local"

if ($PluginsOnly) {
    docker volume inspect "${ProjectName}_ct_home" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "No volume '${ProjectName}_ct_home' to clean. Nothing to reset."
        exit 0
    }
    $TargetVols = @()
    $ResetLabel = "plugins only"
} else {
    $TargetVols = @($AllVols | Where-Object { $_ -match "^${ProjectName}_ct_home$" })
    $ResetLabel = "full"
    if ($TargetVols.Count -eq 0) {
        Write-Host "No matching volume found for '${ProjectName}'. Nothing to reset."
        exit 0
    }
}

# ── show warning screen ───────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Banner "  +============================================================+"
Write-Banner "  |        !   WARNING - PERMANENT DATA LOSS   !               |"
Write-Banner "  |               THIS CANNOT BE UNDONE                        |"
Write-Banner "  +============================================================+"
Write-Host ""

Write-Host "  Reset type: " -NoNewline; Write-Host $ResetLabel -ForegroundColor Yellow
Write-Host "  Project:    " -NoNewline; Write-Host $ProjectName -ForegroundColor Cyan
Write-Host ""

if (-not $PluginsOnly) {
    Write-Warn "The following volume will be PERMANENTLY DELETED:"
    foreach ($v in $TargetVols) { Write-Dim "  docker volume rm $v" }
    Write-Host ""
    Write-Host "  This will erase:" -ForegroundColor White
    Write-Warn "All installed tool versions (Node, Python, Go, Rust, Java, etc.)"
    Write-Warn "All installed plugins, MCP servers, and their configurations"
    Write-Warn "Claude memories, slash commands, and settings (if using named volume)"
    Write-Warn "Shell history, zsh config, starship prompt, ccstatusline config"
    Write-Warn "Any data stored inside the container home directory"
    Write-Host ""
    Write-Host "  This will NOT affect:" -ForegroundColor Cyan
    Write-Info "Your source code and project files (bind-mounted from host)"
    Write-Info "Your host ~/.claude directory (if you set CLAUDE_DIR in .env)"
    Write-Info "Your .env configuration file"
} else {
    Write-Info "Plugin sentinels will be cleared from ${ProjectName}_ct_home"
    Write-Host ""
    Write-Host "  This will:" -ForegroundColor White
    Write-Warn "Remove all plugin install sentinels — plugins re-install on next start"
    Write-Host ""
    Write-Host "  This will NOT affect:" -ForegroundColor Cyan
    Write-Info "Installed tool versions (Node, Python, Go, Rust, etc.)"
    Write-Info "Claude memories and settings"
    Write-Info "Your source code and project files"
}

Write-Host ""
Write-Host "    Container '$ProjectName' will be stopped if running." -ForegroundColor DarkGray
Write-Host ""

# ── first confirmation ────────────────────────────────────────────────────────
$first = Read-Host "  Are you sure you want to proceed? [y/N]"
if ($first -notmatch "^[yY]") {
    Write-Host ""; Write-Host "  Aborted. Nothing was changed."
    exit 0
}

# ── second confirmation (type RESET) ─────────────────────────────────────────
Write-Host ""
Write-Host "  This is your final warning." -ForegroundColor Red -BackgroundColor Black
Write-Host "  Type " -NoNewline
Write-Host "RESET" -ForegroundColor Red -NoNewline
if ($PluginsOnly) {
    Write-Host " to clear plugin sentinels, or anything else to abort:"
} else {
    Write-Host " to permanently delete the home volume, or anything else to abort:"
}
$final = Read-Host "  >"
if ($final -cne "RESET") {
    Write-Host ""; Write-Host "  Aborted. Nothing was changed."
    exit 0
}

# ── stop container ────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Stopping container '$ProjectName' if running..."
docker stop $ProjectName 2>$null | Out-Null
Write-Info "Container stopped (or was not running)."

# ── plugins-only mode: clear sentinels via temp container ─────────────────────
if ($PluginsOnly) {
    $imgExists = docker image inspect $ImageName 2>$null
    if (-not $imgExists) {
        Write-Err "Image '$ImageName' not found. Build it first with: .\run.ps1 -Build"
        exit 1
    }
    Write-Info "Clearing plugin sentinels..."
    docker run --rm `
        --volume "${ProjectName}_ct_home:/home/dev" `
        --user root `
        --entrypoint /bin/sh `
        $ImageName `
        -c "rm -rf /home/dev/.local/share/codetainyrrr/plugins/"
    Write-Host ""
    Write-Host "  Plugin reset complete." -ForegroundColor Cyan
    Write-Dim "Plugins will re-install on next start."
    Write-Dim "Run .\run.ps1 to start."
    Write-Host ""
    exit 0
}

# ── delete home volume ────────────────────────────────────────────────────────
Write-Info "Deleting $($TargetVols.Count) volume(s)..."
$failed = 0
foreach ($v in $TargetVols) {
    docker volume rm $v 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Dim "removed: $v"
    } else {
        Write-Err "Failed to remove: $v  (still in use?)"
        $failed++
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  Reset complete." -ForegroundColor Cyan
    Write-Dim "All tool installs will be re-downloaded on next start."
    Write-Dim "Run .\run.ps1 to start fresh."
} else {
    Write-Err "$failed volume(s) could not be removed. Try: docker stop $ProjectName; then .\reset.ps1"
    exit 1
}
Write-Host ""

# run.ps1 - codetainyrrr wrapper for Windows PowerShell
# Same behaviour as run.sh but without requiring Git Bash.
#
# USAGE:
#   .\run.ps1                                        # interactive zsh
#   .\run.ps1 -Detach                                # start in background (daemon mode)
#   .\run.ps1 connect                                # attach a new shell to running container
#   .\run.ps1 stop                                   # stop the running container
#   .\run.ps1 --dangerously-skip-permissions         # run claude
#   .\run.ps1 -Cli codex                             # run codex (one-off, no default change)
#   .\run.ps1 -Network my_project_default            # attach extra network
#   .\run.ps1 -Build                                 # rebuild image first

param(
    [string]$Cli = "",
    [string[]]$Network = @(),
    [switch]$Build,
    [switch]$Detach,
    # All remaining args are forwarded to the container entrypoint
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ContainerArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ---------------------------------------------------------------------------
# Load .env early so CONTAINER_NAME is available for subcommands
# ---------------------------------------------------------------------------
$EnvFile = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                if (-not [Environment]::GetEnvironmentVariable($key)) {
                    [Environment]::SetEnvironmentVariable($key, $val)
                }
            }
        }
    }
}

$ContainerName = if ($env:CONTAINER_NAME) { $env:CONTAINER_NAME } else { "codetainyrrr" }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# `docker ps --filter "name=^X$"` is unreliable on Docker Desktop for Windows;
# use container inspect instead.
function Get-ContainerStatus($name) {
    $s = docker container inspect $name --format '{{.State.Status}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return "" } else { return $s }
}
function Test-ContainerRunning($name) { (Get-ContainerStatus $name) -eq "running" }

# Whitelist for CLI / plugin names written into .env.
function Test-ValidId($s) { $s -match '^[a-zA-Z0-9_/:.\-]+$' }

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
$sub = if ($ContainerArgs.Count -gt 0) { $ContainerArgs[0] } else { "" }

if ($sub -in @("help", "--help", "-h")) {
    Write-Host "Usage: .\run.ps1 [subcommand|flags]"
    Write-Host ""
    Write-Host "Subcommands:"
    Write-Host "  (none)                 Start daemon + connect (default)"
    Write-Host "  connect                Attach a new shell to running container"
    Write-Host "  stop                   Stop the running container"
    Write-Host "  restart                Stop and restart, then connect"
    Write-Host "  status                 Show container and volume state"
    Write-Host "  version                Print codetainyrrr version"
    Write-Host "  switch <cli>           Change default CLI in .env, restart if running"
    Write-Host "  plugins list           Show installed plugins"
    Write-Host "  plugins add <name>     Install plugin(s) into running container"
    Write-Host "  plugins remove <name>  Remove plugin sentinel"
    Write-Host ""
    Write-Host "Flags:"
    Write-Host "  -Build                 Rebuild image before starting"
    Write-Host "  -Detach                Start daemon without connecting"
    Write-Host "  -Cli <name>            Override CLI for this session"
    Write-Host "  -Network <name>        Attach extra Docker network"
    Write-Host "  --dangerously-skip-permissions  Passed to claude"
    Write-Host ""
    Write-Host "CLIs: claude | codex | gemini | opencode | pi | goose | aider | kilo | cn"
    exit 0
}
if ($sub -in @("version", "--version", "-V")) {
    $verFile = Join-Path $ScriptDir "VERSION"
    if (Test-Path $verFile) { Get-Content -Raw $verFile } else { Write-Host "unknown" }
    exit 0
}
if ($sub -eq "connect") {
    if (-not (Test-ContainerRunning $ContainerName)) {
        Write-Host "[run.ps1] Container '$ContainerName' is not running. Start it with: .\run.ps1"
        exit 1
    }
    & docker exec -it $ContainerName /bin/zsh -l
    exit $LASTEXITCODE
}
if ($sub -eq "restart") {
    docker stop $ContainerName 2>$null | Out-Null
    $forward = if ($ContainerArgs.Count -gt 1) { $ContainerArgs[1..($ContainerArgs.Count - 1)] } else { @() }
    & "$PSCommandPath" @forward
    exit $LASTEXITCODE
}
if ($sub -eq "status") {
    Write-Host "Container: $ContainerName"
    $st = docker container inspect $ContainerName --format '{{.State.Status}}' 2>$null
    Write-Host "  State:  $(if ($st) { $st } else { 'not found' })"
    Write-Host "Volume:   ${ContainerName}_ct_home"
    $vi = docker volume inspect "${ContainerName}_ct_home" --format '  Created: {{.CreatedAt}}' 2>$null
    Write-Host $(if ($vi) { $vi } else { "  not found" })
    exit 0
}
if ($sub -eq "stop") {
    if (Test-ContainerRunning $ContainerName) {
        docker stop $ContainerName | Out-Null
        Write-Host "[run.ps1] Stopped."
    } else {
        Write-Host "[run.ps1] Container '$ContainerName' is not running."
    }
    exit 0
}
if ($ContainerArgs.Count -gt 0 -and $ContainerArgs[0] -eq "switch") {
    $NewCli = if ($ContainerArgs.Count -gt 1) { $ContainerArgs[1] } else { "" }
    if (-not $NewCli) { Write-Host "Usage: .\run.ps1 switch <cli>"; exit 1 }
    if (-not (Test-ValidId $NewCli)) { Write-Host "[run.ps1] Invalid CLI name: $NewCli"; exit 1 }
    $EnvLines = if (Test-Path .env) { Get-Content .env } else { @() }
    if ($EnvLines -match "^CODING_CLI=") {
        $EnvLines = $EnvLines -replace "^CODING_CLI=.*", "CODING_CLI=$NewCli"
    } else {
        $EnvLines += "CODING_CLI=$NewCli"
    }
    $EnvLines | Set-Content .env -Encoding utf8
    Write-Host "[run.ps1] CODING_CLI=$NewCli saved to .env"
    if (Test-ContainerRunning $ContainerName) {
        Write-Host "[run.ps1] Stopping container..."
        docker stop $ContainerName | Out-Null
        Write-Host "[run.ps1] Restarting with CLI: $NewCli"
        # note: original flags are intentionally not forwarded — switch is
        # "save and restart with the saved CLI".
        & "$PSCommandPath"
        exit $LASTEXITCODE
    } else {
        Write-Host "[run.ps1] Container not running — new CLI takes effect on next start."
        exit 0
    }
}
if ($ContainerArgs.Count -gt 0 -and $ContainerArgs[0] -eq "plugins") {
    $Sub = if ($ContainerArgs.Count -gt 1) { $ContainerArgs[1] } else { "list" }
    $Arg = if ($ContainerArgs.Count -gt 2) { $ContainerArgs[2] } else { "" }
    switch ($Sub) {
        "list" {
            $EnvVal = (Get-Content .env -ErrorAction SilentlyContinue | Where-Object { $_ -match "^INSTALL_PLUGINS=" }) -replace "^INSTALL_PLUGINS=",""
            Write-Host "INSTALL_PLUGINS (.env): $(if ($EnvVal) { $EnvVal } else { '<none>' })"
            Write-Host "Installed sentinels:"
            $result = docker exec $ContainerName ls /home/dev/.local/share/codetainyrrr/plugins/ 2>$null
            if ($result) { $result -replace "\.installed$","" } else { Write-Host "  (container not running or no plugins installed)" }
        }
        "add" {
            if (-not $Arg) { Write-Host "Usage: .\run.ps1 plugins add <name>[,name,...]"; exit 1 }
            foreach ($n in ($Arg -split ",")) {
                if (-not (Test-ValidId $n)) { Write-Host "[run.ps1] Invalid plugin name: $n"; exit 1 }
            }
            $Cur = (Get-Content .env -ErrorAction SilentlyContinue | Where-Object { $_ -match "^INSTALL_PLUGINS=" }) -replace "^INSTALL_PLUGINS=",""
            $New = if ($Cur) { "$Cur,$Arg" } else { $Arg }
            $EnvLines = if (Test-Path .env) { Get-Content .env } else { @() }
            if ($EnvLines -match "^INSTALL_PLUGINS=") {
                $EnvLines = $EnvLines -replace "^INSTALL_PLUGINS=.*", "INSTALL_PLUGINS=$New"
            } else {
                $EnvLines += "INSTALL_PLUGINS=$New"
            }
            $EnvLines | Set-Content .env -Encoding utf8
            Write-Host "[run.ps1] INSTALL_PLUGINS=$New"
            if (Test-ContainerRunning $ContainerName) {
                $cli = if ($env:CODING_CLI) { $env:CODING_CLI } else { 'claude' }
                docker exec -e "INSTALL_PLUGINS=$Arg" -e "CODING_CLI=$cli" $ContainerName /entrypoint.sh --plugins
            } else {
                Write-Host "[run.ps1] Container not running — plugins install on next start."
            }
        }
        "remove" {
            if (-not $Arg) { Write-Host "Usage: .\run.ps1 plugins remove <name>"; exit 1 }
            if (-not (Test-ValidId $Arg)) { Write-Host "[run.ps1] Invalid plugin name: $Arg"; exit 1 }
            $Cur = (Get-Content .env -ErrorAction SilentlyContinue | Where-Object { $_ -match "^INSTALL_PLUGINS=" }) -replace "^INSTALL_PLUGINS=",""
            $New = ($Cur -split "," | Where-Object { $_ -ne $Arg }) -join ","
            $EnvLines = if (Test-Path .env) { Get-Content .env -ErrorAction SilentlyContinue } else { @() }
            if ($EnvLines -match "^INSTALL_PLUGINS=") {
                $EnvLines = $EnvLines -replace "^INSTALL_PLUGINS=.*", "INSTALL_PLUGINS=$New"
                $EnvLines | Set-Content .env -Encoding utf8
            }
            Write-Host "[run.ps1] Removed '$Arg'. INSTALL_PLUGINS=$(if ($New) { $New } else { '<none>' })"
            $Sentinel = "/home/dev/.local/share/codetainyrrr/plugins/${Arg}.installed"
            if (Test-ContainerRunning $ContainerName) {
                docker exec $ContainerName rm -f $Sentinel 2>$null | Out-Null
                Write-Host "[run.ps1] Sentinel removed."
            } else {
                Write-Host "[run.ps1] Container not running — sentinel will be absent on next start."
            }
        }
        default {
            Write-Host "Usage: .\run.ps1 plugins [list|add <names>|remove <name>]"
            exit 1
        }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Resolve values with fallbacks
# ---------------------------------------------------------------------------
$HostUID  = if ($env:HOST_UID)  { $env:HOST_UID }  else { "1000" }
$HostGID  = if ($env:HOST_GID)  { $env:HOST_GID }  else { "1000" }
# Clamp Windows-mapped UIDs (e.g. 197609 from WSL) to 1000 — not valid as Linux UIDs.
if ([int]$HostUID -gt 65535) { $HostUID = "1000" }
if ([int]$HostGID -gt 65535) { $HostGID = "1000" }
$CodingCLI = if ($Cli)          { $Cli } elseif ($env:CODING_CLI) { $env:CODING_CLI } else { "claude" }

$UserProfile = $env:USERPROFILE -replace '\\', '/'

$ProjectDir = if ($env:PROJECT_DIR -and $env:PROJECT_DIR -ne "") {
    $env:PROJECT_DIR -replace '\\', '/'
} else {
    "$ScriptDir/workspace" -replace '\\', '/'
}

$ClaudeDir = if ($env:CLAUDE_DIR -and $env:CLAUDE_DIR -ne "") {
    $env:CLAUDE_DIR -replace '\\', '/'
} else {
    "$UserProfile/.claude"
}

$ClaudeJson = if ($env:CLAUDE_JSON -and $env:CLAUDE_JSON -ne "") {
    $env:CLAUDE_JSON -replace '\\', '/'
} else {
    "$UserProfile/.claude.json"
}

$ImageName   = "codetainyrrr:local"
$NetworkName = "codetainyrrr_default"

# API / git env vars (empty string if not set)
$AnthropicKey   = if ($env:ANTHROPIC_API_KEY)   { $env:ANTHROPIC_API_KEY }   else { "" }
$OpenAIKey      = if ($env:OPENAI_API_KEY)      { $env:OPENAI_API_KEY }      else { "" }
$OpenRouterKey  = if ($env:OPENROUTER_API_KEY)  { $env:OPENROUTER_API_KEY }  else { "" }
$GeminiKey      = if ($env:GEMINI_API_KEY)      { $env:GEMINI_API_KEY }      else { "" }
$GitName        = if ($env:GIT_AUTHOR_NAME)     { $env:GIT_AUTHOR_NAME }     else { "" }
$GitEmail       = if ($env:GIT_AUTHOR_EMAIL)    { $env:GIT_AUTHOR_EMAIL }    else { "" }
$InstallTools    = if ($env:INSTALL_TOOLS)       { $env:INSTALL_TOOLS }       else { "" }
$InstallPlugins  = if ($env:INSTALL_PLUGINS)    { $env:INSTALL_PLUGINS }     else { "" }
$ExtraWorkspaces = if ($env:EXTRA_WORKSPACES)   { $env:EXTRA_WORKSPACES }    else { "" }

# Bring-your-own configs
$CcstatuslineConfig = if ($env:CCSTATUSLINE_CONFIG) { ($env:CCSTATUSLINE_CONFIG) -replace '\\','/' } else { "" }
$ZshExtraConfig     = if ($env:ZSH_EXTRA_CONFIG)    { ($env:ZSH_EXTRA_CONFIG)    -replace '\\','/' } else { "" }
$StarshipConfig     = if ($env:STARSHIP_CONFIG)     { ($env:STARSHIP_CONFIG)      -replace '\\','/' } else { "" }

$ByoConfigArgs = @()
if ($CcstatuslineConfig) { $ByoConfigArgs += "--volume"; $ByoConfigArgs += "${CcstatuslineConfig}:/home/dev/.config/ccstatusline/settings.json:ro" }
if ($ZshExtraConfig)     { $ByoConfigArgs += "--volume"; $ByoConfigArgs += "${ZshExtraConfig}:/home/dev/.config/zsh/extra.zsh:ro" }
if ($StarshipConfig)     { $ByoConfigArgs += "--volume"; $ByoConfigArgs += "${StarshipConfig}:/home/dev/.config/starship.toml:ro" }

# Derive system-level build args from INSTALL_TOOLS
$InstallCpp  = if ($InstallTools -match "(^|,)cpp(,|$)")  { "true" } else { "false" }
$InstallPhp  = if ($InstallTools -match "(^|,)php(,|$)")  { "true" } else { "false" }
$InstallRuby = if ($InstallTools -match "(^|,)ruby(,|$)") { "true" } else { "false" }

# ---------------------------------------------------------------------------
# Build image if requested or missing
# ---------------------------------------------------------------------------
$imageExists = docker image inspect $ImageName 2>$null
if ($Build -or -not $imageExists) {
    Write-Host "[run.ps1] Building codetainyrrr image (UID=$HostUID GID=$HostGID CPP=$InstallCpp PHP=$InstallPhp RUBY=$InstallRuby)..."
    docker build `
        --build-arg "HOST_UID=$HostUID" `
        --build-arg "HOST_GID=$HostGID" `
        --build-arg "USERNAME=dev" `
        --build-arg "INSTALL_CPP=$InstallCpp" `
        --build-arg "INSTALL_PHP=$InstallPhp" `
        --build-arg "INSTALL_RUBY=$InstallRuby" `
        -t $ImageName `
        $ScriptDir
}

# ---------------------------------------------------------------------------
# Ensure default network exists
# ---------------------------------------------------------------------------
$netExists = docker network inspect $NetworkName 2>$null
if (-not $netExists) {
    docker network create $NetworkName | Out-Null
}

if (-not (Test-Path $ProjectDir)) {
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
}

# .claude volume strategy: home volume handles ~/.claude by default.
# When CLAUDE_DIR is set, bind-mount overlays on top (shares with Claude Desktop).
$ClaudeVolumeArgs = @()
$ClaudeDirRaw = $env:CLAUDE_DIR
if ($ClaudeDirRaw -and $ClaudeDirRaw -ne "") {
    $ClaudeDir = $ClaudeDirRaw -replace '\\', '/'
    $ClaudeJson = if ($env:CLAUDE_JSON -and $env:CLAUDE_JSON -ne "") {
        $env:CLAUDE_JSON -replace '\\', '/'
    } else {
        "$UserProfile/.claude.json"
    }
    if (-not (Test-Path $ClaudeJson)) { New-Item -ItemType File -Path $ClaudeJson -Force | Out-Null }
    if (-not (Test-Path $ClaudeDir))  { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }
    $ClaudeVolumeArgs = @(
        "--volume", "${ClaudeDir}:/home/dev/.claude",
        "--volume", "${ClaudeJson}:/home/dev/.claude.json"
    )
}

$ProjectDirName = Split-Path -Leaf $ProjectDir
Write-Host "[run.ps1] CLI: $CodingCLI | Project: $ProjectDir → /workspace/$ProjectDirName"

# ---------------------------------------------------------------------------
# Build docker run args
# ---------------------------------------------------------------------------
# Default (no args): start daemon + auto-connect
$AutoConnect = $false
if (-not $Detach -and $ContainerArgs.Count -eq 0) {
    $Detach = $true
    $AutoConnect = $true
}

$RunModeArgs = if ($Detach) { @("run", "--detach") } else { @("run", "--rm", "-it") }
$RunContainerName = if ($Detach) { $ContainerName } else { "codetainyrrr-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
if ($Detach) {
    $ContainerArgs = @("--daemon")
    if (-not $AutoConnect) { Write-Host "[run.ps1] Starting daemon. Connect with: .\run.ps1 connect" }
}

# Idempotent: check existing container state before trying to docker run
if ($Detach) {
    $CtStatus = docker container inspect $ContainerName --format '{{.State.Status}}' 2>$null
    if ($CtStatus -eq "running") {
        if ($AutoConnect) {
            & docker exec -it $ContainerName /bin/zsh -l
            exit $LASTEXITCODE
        } else {
            Write-Host "[run.ps1] Container already running. Connect with: .\run.ps1 connect"
            exit 0
        }
    } elseif ($CtStatus) {
        # Exists but stopped — restart rather than recreate
        Write-Host "[run.ps1] Restarting stopped container..."
        docker start $ContainerName | Out-Null
        if ($AutoConnect) {
            & docker exec -it $ContainerName /bin/zsh -l
            exit $LASTEXITCODE
        } else {
            Write-Host "[run.ps1] Container restarted. Connect with: .\run.ps1 connect"
            exit 0
        }
    }
}

$RunArgs = $RunModeArgs + @(
    "--name", $RunContainerName,
    "--hostname", "codetainyrrr",
    "--cap-drop", "ALL",
    "--cap-add", "CHOWN",
    "--cap-add", "SETUID",
    "--cap-add", "SETGID",
    "--security-opt", "no-new-privileges:true",
    "--volume", "${ProjectDir}:/workspace/${ProjectDirName}",
    "--volume", "${ContainerName}_ct_home:/home/dev") + $ClaudeVolumeArgs + $ByoConfigArgs + @(
    "--env", "HOST_UID=$HostUID",
    "--env", "HOST_GID=$HostGID",
    "--env", "CODING_CLI=$CodingCLI",
    "--env", "INSTALL_TOOLS=$InstallTools",
    "--env", "INSTALL_PLUGINS=$InstallPlugins",
    "--env", "HOME=/home/dev",
    "--env", "USER=dev",
    "--env", "ANTHROPIC_API_KEY=$AnthropicKey",
    "--env", "OPENAI_API_KEY=$OpenAIKey",
    "--env", "OPENROUTER_API_KEY=$OpenRouterKey",
    "--env", "GEMINI_API_KEY=$GeminiKey",
    "--env", "GIT_AUTHOR_NAME=$GitName",
    "--env", "GIT_AUTHOR_EMAIL=$GitEmail",
    "--env", "GIT_COMMITTER_NAME=$GitName",
    "--env", "GIT_COMMITTER_EMAIL=$GitEmail",
    "--network", $NetworkName
)

foreach ($net in $Network) {
    $RunArgs += "--network"
    $RunArgs += $net
    Write-Host "[run.ps1] Extra network: $net"
}

# Mount extra workspaces (colon-separated paths in EXTRA_WORKSPACES)
if ($ExtraWorkspaces -ne "") {
    foreach ($ws in ($ExtraWorkspaces -split ";")) {
        $ws = $ws.Trim()
        if ($ws -eq "") { continue }
        $ws = $ws -replace '\\', '/'
        $wsName = Split-Path -Leaf $ws
        if (-not (Test-Path $ws)) {
            New-Item -ItemType Directory -Path $ws -Force | Out-Null
        }
        $RunArgs += "--volume"
        $RunArgs += "${ws}:/workspace/${wsName}"
        Write-Host "[run.ps1] Extra workspace: $ws → /workspace/$wsName"
    }
}

$RunArgs += "--workdir"
$RunArgs += "/workspace/$ProjectDirName"
$RunArgs += $ImageName

foreach ($arg in $ContainerArgs) {
    $RunArgs += $arg
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
if ($AutoConnect) {
    & docker @RunArgs
    & docker exec -it $ContainerName /bin/zsh -l
} else {
    & docker @RunArgs
}

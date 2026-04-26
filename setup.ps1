# setup.ps1 — interactive onboarding for codetainyrrr (Windows PowerShell)
# Walks through every option and writes .env

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ── helpers ───────────────────────────────────────────────────────────────────

function Write-Header($text) {
    Write-Host ""
    Write-Host "── $text " -ForegroundColor Cyan -NoNewline
    Write-Host ("─" * [Math]::Max(1, 46 - $text.Length)) -ForegroundColor DarkGray
}

function Write-Dim($text)  { Write-Host "  $text" -ForegroundColor DarkGray }
function Write-Ok($text)   { Write-Host "  ✓ $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  ⚠  $text" -ForegroundColor Yellow }

function Ask {
    param([string]$Question, [string]$Default = "")
    Write-Host $Question -ForegroundColor Yellow
    if ($Default -ne "") { Write-Host "  default: $Default" -ForegroundColor DarkGray }
    $input = Read-Host "  >"
    if ($input -eq "") { return $Default } else { return $input }
}

function AskSecret {
    param([string]$Question)
    Write-Host $Question -ForegroundColor Yellow
    $secure = Read-Host "  >" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function AskYN {
    param([string]$Question, [string]$Default = "n")
    $hint = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
    Write-Host "$Question $hint" -ForegroundColor Yellow
    $input = Read-Host "  >"
    if ($input -eq "") { $input = $Default }
    return $input.ToLower().StartsWith("y")
}

function Show-Menu {
    param([string]$Question, [hashtable[]]$Options)
    Write-Host $Question -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $key  = $Options[$i].Key
        $desc = $Options[$i].Desc
        Write-Host "  " -NoNewline
        Write-Host "$($i+1)" -ForegroundColor White -NoNewline
        Write-Host ") " -NoNewline
        Write-Host $key -ForegroundColor Green -NoNewline
        Write-Host " — $desc"
    }
    $input = Read-Host "  >"
    if ($input -match '^\d+$') {
        $idx = [int]$input - 1
        if ($idx -ge 0 -and $idx -lt $Options.Count) { return $Options[$idx].Key }
    }
    if ($input -eq "") { return $Options[0].Key }
    return $input
}

# ── load existing .env as defaults ───────────────────────────────────────────
$Existing = @{}
$EnvFile  = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $k = $parts[0].Trim()
                $v = $parts[1].Trim().Trim('"')
                $Existing[$k] = $v
            }
        }
    }
}
function E($key, $fallback = "") {
    if ($Existing.ContainsKey($key)) { return $Existing[$key] } else { return $fallback }
}

# ── banner ────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║        codetainyrrr  ·  setup             ║" -ForegroundColor Cyan
Write-Host "  ║   AI coding container · sandboxed · fast  ║" -ForegroundColor Cyan
Write-Host "  ╚═══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This wizard creates your .env configuration file."
Write-Host "  Press Enter to accept any default shown."
Write-Host ""

if (Test-Path $EnvFile) {
    Write-Warn "Found existing .env — current values shown as defaults."
}

# ── 1. AI CLI ─────────────────────────────────────────────────────────────────
Write-Header "AI Coding Assistant"
Write-Dim "Which CLI should run inside the container?"
$CodingCLI = Show-Menu "Pick one:" @(
    @{ Key="claude";   Desc="Anthropic Claude Code (default)" }
    @{ Key="codex";    Desc="OpenAI Codex CLI" }
    @{ Key="gemini";   Desc="Google Gemini CLI" }
    @{ Key="opencode"; Desc="OpenCode AI" }
    @{ Key="pi";       Desc="Pi coding agent" }
    @{ Key="goose";    Desc="Block's Goose" }
    @{ Key="aider";    Desc="Aider — great for git workflows (Python)" }
    @{ Key="kilo";     Desc="Kilocode" }
    @{ Key="cn";       Desc="Continue Dev" }
)
if ($CodingCLI -eq "") { $CodingCLI = E "CODING_CLI" "claude" }
Write-Ok "CLI: $CodingCLI"
Write-Dim "  Switch later: .\run.ps1 switch <cli>  (updates .env + restarts)"
Write-Dim "  One-off session: .\run.ps1 -Cli <cli>  (no default change)"

$ContainerName = Ask "Container name (shown in docker ps):" (E "CONTAINER_NAME" "codetainyrrr")
if ($ContainerName -eq "") { $ContainerName = "codetainyrrr" }
Write-Ok "Container: $ContainerName"
Write-Dim "  Run a second instance with a different name: change CONTAINER_NAME in .env and .\run.ps1"

# ── 2. Project directory ──────────────────────────────────────────────────────
Write-Header "Project Directory"
Write-Dim "The folder on your host machine mounted as /workspace inside the container."
$UserProfile = $env:USERPROFILE -replace '\\', '/'
$ProjectDir  = Ask "Path to your project:" (E "PROJECT_DIR" "$UserProfile/projects/myproject")
$ProjectDir  = $ProjectDir -replace '\\', '/'
Write-Ok "Project: $ProjectDir"

$ExtraWorkspaces = E "EXTRA_WORKSPACES" ""
if (AskYN "Mount additional project folders? (semicolon-separated in next prompt)" "n") {
    $ExtraWorkspaces = Ask "Extra paths (semicolon-separated):" $ExtraWorkspaces
    $ExtraWorkspaces = $ExtraWorkspaces -replace '\\', '/'
}

# ── 3. Claude settings ────────────────────────────────────────────────────────
Write-Header "Claude Settings"
Write-Host "  Share your host ~/.claude with the container?" -ForegroundColor White
Write-Dim "  Yes → memories, settings, and plugins sync with Claude Desktop."
Write-Dim "  No  → fully isolated — nothing touches your host."
$shareDefault = if ($Existing.ContainsKey("CLAUDE_DIR") -and $Existing["CLAUDE_DIR"] -ne "") { "y" } else { "n" }
$ClaudeDir  = ""
$ClaudeJson = ""
if (AskYN "Share host ~/.claude?" $shareDefault) {
    $ClaudeDir  = Ask "Path to your Claude config dir:"  (E "CLAUDE_DIR"  "$UserProfile/.claude")
    $ClaudeJson = Ask "Path to your claude.json file:"   (E "CLAUDE_JSON" "$UserProfile/.claude.json")
    $ClaudeDir  = $ClaudeDir  -replace '\\', '/'
    $ClaudeJson = $ClaudeJson -replace '\\', '/'
    Write-Ok "Sharing: $ClaudeDir"
} else {
    Write-Ok "Isolated: named volume (wipe with: docker volume rm codetainyrrr_ct_home)"
}

# ── 4. API keys ───────────────────────────────────────────────────────────────
Write-Header "API Keys"
Write-Dim "Keys are stored only in your local .env — never sent anywhere by this script."
Write-Host ""

$AnthropicKey   = E "ANTHROPIC_API_KEY" ""
$OpenAIKey      = E "OPENAI_API_KEY" ""
$OpenRouterKey  = E "OPENROUTER_API_KEY" ""
$GeminiKey      = E "GEMINI_API_KEY" ""

if ($AnthropicKey -ne "") {
    Write-Host "  Anthropic API key: " -NoNewline
    Write-Host "already set" -ForegroundColor DarkGray
    if (AskYN "Replace existing Anthropic key?" "n") {
        $AnthropicKey = AskSecret "New Anthropic API key:"
    }
} else {
    Write-Dim "  Leave blank if you log in via claude.ai (CLAUDE_DIR shared above)."
    $AnthropicKey = AskSecret "Anthropic API key (or leave blank):"
}
if ($AnthropicKey -ne "") { Write-Ok "Anthropic key set" } else { Write-Dim "  Anthropic key: not set" }

if (AskYN "Set additional provider keys? (OpenAI, OpenRouter, Gemini)" "n") {
    $OpenAIKey     = AskSecret "OpenAI API key (or leave blank):"
    $OpenRouterKey = AskSecret "OpenRouter API key (or leave blank):"
    $GeminiKey     = AskSecret "Gemini API key (or leave blank):"
}

# ── 5. Git identity ───────────────────────────────────────────────────────────
Write-Header "Git Identity"
Write-Dim "Used for commits made inside the container."
$gitNameDefault  = E "GIT_AUTHOR_NAME"  (git config --global user.name  2>$null)
$gitEmailDefault = E "GIT_AUTHOR_EMAIL" (git config --global user.email 2>$null)
$GitName  = Ask "Your name:"  $gitNameDefault
$GitEmail = Ask "Your email:" $gitEmailDefault
if ($GitName -ne "") { Write-Ok "Git: $GitName <$GitEmail>" }

# ── 6. Dev Tools ──────────────────────────────────────────────────────────────
Write-Header "Dev Tools  (optional)"
Write-Dim "Lazy-installed on first run into named volumes — instant on every start after."
Write-Host ""

function Show-Category($title, $items, $note = "") {
    Write-Host "  $title" -ForegroundColor White
    if ($note) { Write-Host "  $note" -ForegroundColor DarkGray }
    foreach ($item in $items) {
        Write-Host "    " -NoNewline
        Write-Host $item[0].PadRight(14) -ForegroundColor Green -NoNewline
        Write-Host $item[1] -ForegroundColor DarkGray
    }
    Write-Host ""
}

Show-Category "Languages & runtimes" @(
    @("java",   "Java LTS via SDKMan — enterprise / Android / Spring"),
    @("go",     "Go latest stable — fast compiled services"),
    @("rust",   "Rust via rustup — systems / WASM / CLI tools"),
    @("python", "Poetry, black, ruff, mypy via uv — data / ML / scripts"),
    @("deno",   "Deno — secure TypeScript runtime, no node_modules"),
    @("bun",    "Bun — fast JS runtime + package manager"),
    @("dotnet", ".NET SDK LTS — C# / F# / ASP.NET")
)

Show-Category "Frontend" @(
    @("ts",     "TypeScript + ts-node + tsx — type-safe JS, works anywhere"),
    @("react",  "Vite + create-react-app — React scaffolding & dev server"),
    @("svelte", "SvelteKit — lean reactive framework, no virtual DOM")
)

Show-Category "Git & utilities" @(
    @("lazygit", "TUI git client — navigate branches/diffs without leaving terminal")
)

Write-Dim "  cpp, php, ruby require a rebuild (set INSTALL_CPP/PHP/RUBY=true then .\run.ps1 -Build)."
$InstallTools = Ask "Enter tools (comma-separated, or leave blank):" (E "INSTALL_TOOLS" "")
if ($InstallTools -ne "") { Write-Ok "Tools: $InstallTools" } else { Write-Dim "  Tools: none" }

# ── 7. Plugins & Tools ────────────────────────────────────────────────────────
Write-Header "Plugins & Tools  (optional)"
Write-Dim "Installed once, sentineled. Add/remove later: .\run.ps1 plugins add <name> / remove <name>"
Write-Host ""

if ($CodingCLI -eq "claude") {
    Show-Category "Token & context optimization" @(
        @("caveman",      "Rewrites output as caveman-speak — ~70% fewer tokens, same accuracy"),
        @("context-mode", "Sandboxes tool output so raw data never enters context — ~98% savings")
    ) "(Claude Code only)"

    Show-Category "Usage monitoring" @(
        @("ccusage",    "Dashboard for session cost & token usage — run: npx ccusage"),
        @("claude-hud", "Live token/context/agent overlay inside Claude Code  (Claude only)")
    ) "(ccusage works with any CLI)"

    Show-Category "Memory & session continuity" @(
        @("claude-mem", "Auto-captures session activity, compresses, injects context next session  (Claude only, AGPL-3.0)"),
        @("mempalace",  "Spatial AI memory indexed locally — run: mempalace init /workspace  (any CLI)")
    )

    Show-Category "Codebase intelligence" @(
        @("graphify", "Parses your codebase into a queryable knowledge graph — run: /graphify .  (any CLI)")
    )

    Show-Category "Rules & skill packs" @(
        @("karpathy-skills",        "Injects Karpathy's 4 principles: think first, minimal code, surgical edits"),
        @("everything-claude-code", "48 agents + 183 skills + 34 language rules  (large — adds context overhead)")
    ) "(Claude Code only)"

    Show-Category "Custom — add anything not in the list" @(
        @("owner/repo", "GitHub repo with a .claude-plugin folder (Claude only)"),
        @("npm:pkg",    "npm install -g (any CLI)"),
        @("uv:pkg",     "uv tool install (any CLI)")
    )
    Write-Dim "  Example: caveman,ccusage,myorg/myplugin,npm:my-tool"
} else {
    Write-Dim "  Showing plugins compatible with $CodingCLI."
    Write-Dim "  Claude-only plugins (caveman, context-mode, claude-mem, claude-hud, karpathy-skills, everything-claude-code)"
    Write-Dim "  are not available with this CLI. Switch to claude to use them: .\run.ps1 switch claude"
    Write-Host ""

    Show-Category "Usage monitoring" @(
        @("ccusage",   "Dashboard for session cost & token usage — run: npx ccusage")
    ) "(standalone, any CLI)"

    Show-Category "Memory & session continuity" @(
        @("mempalace", "Spatial AI memory indexed locally — run: mempalace init /workspace  (any CLI)")
    )

    Show-Category "Codebase intelligence" @(
        @("graphify",  "Parses your codebase into a queryable knowledge graph — run: /graphify .  (any CLI)")
    )

    Show-Category "Custom" @(
        @("npm:pkg", "npm install -g (any CLI)"),
        @("uv:pkg",  "uv tool install (any CLI)")
    )
    Write-Dim "  Example: ccusage,mempalace,npm:my-tool"
}
Write-Host ""
$InstallPlugins = Ask "Enter plugins (comma-separated, or leave blank):" (E "INSTALL_PLUGINS" "")
if ($InstallPlugins -ne "") { Write-Ok "Plugins: $InstallPlugins" } else { Write-Dim "  Plugins: none" }

# ── 8. Bring-your-own configs ─────────────────────────────────────────────────
Write-Header "Bring-Your-Own Configs  (optional)"
Write-Dim "Point to files on your host — mounted read-only into the container."
Write-Dim "Leave blank to use the built-in defaults."
Write-Host ""
$CcstatuslineConfig = Ask "ccstatusline settings.json path (blank = use built-in):" (E "CCSTATUSLINE_CONFIG" "")
$ZshExtraConfig     = Ask "Extra zsh config to source at shell start (blank = none):" (E "ZSH_EXTRA_CONFIG" "")
$StarshipConfig     = Ask "starship.toml path (blank = use built-in):" (E "STARSHIP_CONFIG" "")
$CcstatuslineConfig = $CcstatuslineConfig -replace '\\', '/'
$ZshExtraConfig     = $ZshExtraConfig     -replace '\\', '/'
$StarshipConfig     = $StarshipConfig     -replace '\\', '/'
if ($CcstatuslineConfig -ne "") { Write-Ok "ccstatusline: $CcstatuslineConfig" }
if ($ZshExtraConfig     -ne "") { Write-Ok "zsh extra:    $ZshExtraConfig" }
if ($StarshipConfig     -ne "") { Write-Ok "starship:     $StarshipConfig" }

# ── 9. System UID/GID ─────────────────────────────────────────────────────────
$HostUID = E "HOST_UID" "1000"
$HostGID = E "HOST_GID" "1000"

# ── 10. Summary ───────────────────────────────────────────────────────────────
Write-Header "Summary"
Write-Host ""
$claudeDirDisplay = if ($ClaudeDir -ne "") { $ClaudeDir } else { "named volume (isolated)" }
$anthropicDisplay = if ($AnthropicKey -ne "") { "set" } else { "not set" }
@(
    @("CLI:",             $CodingCLI)
    @("Container:",       $ContainerName)
    @("Project:",         $ProjectDir)
    @("Claude dir:",      $claudeDirDisplay)
    @("Anthropic key:",   $anthropicDisplay)
    @("Git name:",        $(if ($GitName  -ne "") { $GitName }  else { "not set" }))
    @("Git email:",       $(if ($GitEmail -ne "") { $GitEmail } else { "not set" }))
    @("Dev tools:",       $(if ($InstallTools   -ne "") { $InstallTools   } else { "none" }))
    @("Plugins:",         $(if ($InstallPlugins -ne "") { $InstallPlugins } else { "none" }))
) | ForEach-Object {
    Write-Host ("  {0,-24}" -f $_[0]) -NoNewline
    Write-Host $_[1]
}
if ($CcstatuslineConfig -ne "") { Write-Host ("  {0,-24}{1}" -f "ccstatusline config:", $CcstatuslineConfig) }
if ($ZshExtraConfig     -ne "") { Write-Host ("  {0,-24}{1}" -f "zsh extra config:",    $ZshExtraConfig) }
if ($StarshipConfig     -ne "") { Write-Host ("  {0,-24}{1}" -f "starship config:",     $StarshipConfig) }
Write-Host ""

if (-not (AskYN "Write .env and continue?" "y")) {
    Write-Host "Aborted."
    exit 0
}

# ── 11. Write .env ────────────────────────────────────────────────────────────
$envContent = @"
# codetainyrrr configuration
# Generated by setup.ps1 — edit manually or re-run setup.ps1 to update.

HOST_UID=$HostUID
HOST_GID=$HostGID

# ── AI CLI ──────────────────────────────────────────────────────────────────
# Options: claude | codex | gemini | opencode | pi | goose | aider | kilo | cn
CODING_CLI=$CodingCLI
CONTAINER_NAME=$ContainerName

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_DIR=$ProjectDir
EXTRA_WORKSPACES=$ExtraWorkspaces

# Claude config — leave blank to use an isolated named volume (recommended)
CLAUDE_DIR=$ClaudeDir
CLAUDE_JSON=$ClaudeJson

# ── API keys ─────────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY=$AnthropicKey
OPENAI_API_KEY=$OpenAIKey
OPENROUTER_API_KEY=$OpenRouterKey
GEMINI_API_KEY=$GeminiKey

# ── Git identity ─────────────────────────────────────────────────────────────
GIT_AUTHOR_NAME=$GitName
GIT_AUTHOR_EMAIL=$GitEmail

# ── Dev tools ────────────────────────────────────────────────────────────────
# Options: java,go,rust,ts,react,svelte,python,deno,bun,dotnet,lazygit
# (cpp, php, ruby are baked in at build time)
INSTALL_TOOLS=$InstallTools
# INSTALL_CPP=false
# INSTALL_PHP=false
# INSTALL_RUBY=false

# ── Plugins ──────────────────────────────────────────────────────────────────
# Built-in: caveman,context-mode,claude-mem,claude-hud,ccusage,graphify,
#           mempalace,everything-claude-code,karpathy-skills
# Custom:   owner/repo  (Claude),  npm:pkg,  uv:pkg
INSTALL_PLUGINS=$InstallPlugins

# ── Bring-your-own configs ────────────────────────────────────────────────────
# Host paths → mounted read-only. Leave blank to use built-in defaults.
CCSTATUSLINE_CONFIG=$CcstatuslineConfig
ZSH_EXTRA_CONFIG=$ZshExtraConfig
STARSHIP_CONFIG=$StarshipConfig
"@

$envContent | Out-File -FilePath $EnvFile -Encoding utf8 -NoNewline
Write-Ok ".env written."

# ── 12. Build + start ─────────────────────────────────────────────────────────
Write-Host ""
if (AskYN "Build the Docker image now? (required on first run, ~30s)" "y") {
    Write-Host ""
    & "$ScriptDir\run.ps1" -Build -Detach
    Write-Ok "Image built."
}

Write-Host ""
if (AskYN "Start the container now?" "y") {
    Write-Host ""
    & "$ScriptDir\run.ps1"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host "  Run " -NoNewline; Write-Host ".\run.ps1" -ForegroundColor Cyan -NoNewline; Write-Host "         to start"
Write-Host "  Run " -NoNewline; Write-Host ".\run.ps1 connect" -ForegroundColor Cyan -NoNewline; Write-Host "  to attach another shell"
Write-Host "  Run " -NoNewline; Write-Host ".\run.ps1 stop" -ForegroundColor Cyan -NoNewline; Write-Host "     to stop the container"
if ($InstallPlugins -match "mempalace") {
    Write-Warn "mempalace: run 'mempalace init /workspace' inside the container on first use."
}
Write-Host ""

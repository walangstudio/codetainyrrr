#!/usr/bin/env bash
# setup.sh — interactive onboarding for codetainyrrr
# Walks through every option and writes .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; DIM='\033[2m'; RED='\033[0;31m'; NC='\033[0m'

h()    { echo; echo -e "${BOLD}${CYAN}── $* ${NC}"; }
dim()  { echo -e "  ${DIM}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }

# ── helpers ───────────────────────────────────────────────────────────────────

# ask VAR "Question" "default"
ask() {
    local __var="$1" question="$2" default="${3:-}"
    echo -e "${YELLOW}$question${NC}"
    [ -n "$default" ] && echo -e "  ${DIM}default: $default${NC}"
    printf "  > "
    local input; read -r input
    printf -v "$__var" '%s' "${input:-$default}"
}

# ask_secret VAR "Question"
ask_secret() {
    local __var="$1" question="$2"
    echo -e "${YELLOW}$question${NC}"
    printf "  > "
    local input; read -rs input; echo
    printf -v "$__var" '%s' "$input"
}

# yn VAR "Question" y|n
yn() {
    local __var="$1" question="$2" default="${3:-n}"
    local hint; [ "$default" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    echo -e "${YELLOW}$question ${DIM}$hint${NC}"
    printf "  > "
    local input; read -r input
    input="${input:-$default}"
    # lowercase without bash4 ${,,}
    input="$(echo "$input" | tr '[:upper:]' '[:lower:]')"
    [[ "$input" == y* ]] && printf -v "$__var" 'y' || printf -v "$__var" 'n'
}

# menu VAR "Question" option1 "desc1" option2 "desc2" ...
menu() {
    local __var="$1" question="$2"; shift 2
    echo -e "${YELLOW}$question${NC}"
    local i=1
    local -a keys=()
    while [ $# -ge 2 ]; do
        echo -e "  ${BOLD}$i)${NC} ${GREEN}$1${NC} — $2"
        keys+=("$1"); shift 2; ((i++))
    done
    printf "  > "
    local input; read -r input
    # accept number or name
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$(( input - 1 ))
        printf -v "$__var" '%s' "${keys[$idx]:-${keys[0]}}"
    elif [ -z "$input" ]; then
        printf -v "$__var" '%s' "${keys[0]}"
    else
        printf -v "$__var" '%s' "$input"
    fi
}

# Load existing .env so re-runs show current values as defaults
_load_existing() {
    [ -f .env ] || return 0
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        val="${val%%#*}"          # strip inline comments
        val="${val%"${val##*[! ]}"}"  # trim trailing spaces
        export "_ENV_${key}=${val}"
    done < .env
}
_e() { local k="_ENV_$1"; echo "${!k:-${2:-}}"; }

# ── main ─────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║        codetainyrrr  ·  setup             ║"
echo "  ║   AI coding container · sandboxed · fast  ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo "  This wizard creates your .env configuration file."
echo "  Press Enter to accept any [default] shown."
echo

# Load existing values so re-runs are incremental
_load_existing
EXISTING=false
[ -f .env ] && { EXISTING=true; warn "Found existing .env — current values shown as defaults."; }

# ── 1. AI coding CLI ─────────────────────────────────────────────────────────
h "AI Coding Assistant"
dim "Which CLI should Claude Code start inside the container?"
menu CODING_CLI "Pick one:" \
    "claude"   "Anthropic Claude Code (default)" \
    "codex"    "OpenAI Codex CLI" \
    "gemini"   "Google Gemini CLI" \
    "opencode" "OpenCode AI" \
    "pi"       "Pi coding agent" \
    "goose"    "Block's Goose" \
    "aider"    "Aider — great for git workflows (Python)" \
    "kilo"     "Kilocode" \
    "cn"       "Continue Dev"
CODING_CLI="${CODING_CLI:-$(_e CODING_CLI claude)}"
ok "CLI: $CODING_CLI"
dim "  Switch later: ./run.sh switch <cli>  (updates .env + restarts)"
dim "  One-off session: ./run.sh --cli <cli>  (no default change)"

ask CONTAINER_NAME "Container name (shown in docker ps):" "$(_e CONTAINER_NAME "codetainyrrr")"
CONTAINER_NAME="${CONTAINER_NAME:-codetainyrrr}"
ok "Container: $CONTAINER_NAME"
dim "  Run a second instance with a different name: change CONTAINER_NAME in .env and ./run.sh"

# ── 2. Project directory ──────────────────────────────────────────────────────
h "Project Directory"
dim "The folder on your host machine that gets mounted as /workspace inside the container."
_default_proj="$(_e PROJECT_DIR "$HOME/projects/myproject")"
ask PROJECT_DIR "Path to your project:" "$_default_proj"
PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"
ok "Project: $PROJECT_DIR"

EXTRA_WORKSPACES="$(_e EXTRA_WORKSPACES "")"
yn _extra_ws "Mount additional project folders? (semicolon-separated in next prompt)" "n"
if [ "$_extra_ws" = "y" ]; then
    ask EXTRA_WORKSPACES "Extra paths (semicolon-separated):" "$EXTRA_WORKSPACES"
fi

# ── 3. Claude settings ────────────────────────────────────────────────────────
h "Claude Settings"
echo -e "  ${BOLD}Share your host ~/.claude with the container?${NC}"
dim "  Yes → memories, settings, and plugins persist and sync with Claude Desktop."
dim "  No  → fully isolated — nothing touches your host (safer for experimentation)."
yn _share_claude "Share host ~/.claude?" "$( [ -n "$(_e CLAUDE_DIR)" ] && echo y || echo n )"

if [ "$_share_claude" = "y" ]; then
    _default_claude_dir="$(_e CLAUDE_DIR "$HOME/.claude")"
    _default_claude_json="$(_e CLAUDE_JSON "$HOME/.claude.json")"
    ask CLAUDE_DIR  "Path to your Claude config dir:"  "$_default_claude_dir"
    ask CLAUDE_JSON "Path to your claude.json file:"   "$_default_claude_json"
    CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"
    CLAUDE_JSON="${CLAUDE_JSON/#\~/$HOME}"
    ok "Sharing: $CLAUDE_DIR"
else
    CLAUDE_DIR=""
    CLAUDE_JSON=""
    ok "Isolated: named volume (wipe with: docker volume rm codetainyrrr_ct_home)"
fi

# ── 4. API keys ───────────────────────────────────────────────────────────────
h "API Keys"
dim "Keys are stored only in your local .env — never sent anywhere by this script."

_anthropic_default="$(_e ANTHROPIC_API_KEY "")"
if [ -n "$_anthropic_default" ]; then
    ask_secret ANTHROPIC_API_KEY "Anthropic API key (Enter to keep existing):"
    [ -z "$ANTHROPIC_API_KEY" ] && ANTHROPIC_API_KEY="$_anthropic_default"
else
    dim "  Leave blank if you log in via claude.ai (CLAUDE_DIR shared above)."
    ask_secret ANTHROPIC_API_KEY "Anthropic API key (or leave blank):"
fi
[ -n "$ANTHROPIC_API_KEY" ] && ok "Anthropic key set" || dim "  Anthropic key: not set"

yn _extra_keys "Set additional provider keys? (OpenAI, OpenRouter, Gemini)" "n"
OPENAI_API_KEY="$(_e OPENAI_API_KEY "")"; OPENROUTER_API_KEY="$(_e OPENROUTER_API_KEY "")"; GEMINI_API_KEY="$(_e GEMINI_API_KEY "")"
if [ "$_extra_keys" = "y" ]; then
    ask_secret OPENAI_API_KEY     "OpenAI API key (or leave blank):"
    ask_secret OPENROUTER_API_KEY "OpenRouter API key (or leave blank):"
    ask_secret GEMINI_API_KEY     "Gemini API key (or leave blank):"
fi

# ── 5. Git identity ───────────────────────────────────────────────────────────
h "Git Identity"
dim "Used for commits made inside the container."
_git_name_default="$(_e GIT_AUTHOR_NAME "$(git config --global user.name 2>/dev/null || echo "")")"
_git_email_default="$(_e GIT_AUTHOR_EMAIL "$(git config --global user.email 2>/dev/null || echo "")")"
ask GIT_AUTHOR_NAME  "Your name:"  "$_git_name_default"
ask GIT_AUTHOR_EMAIL "Your email:" "$_git_email_default"
[ -n "$GIT_AUTHOR_NAME" ] && ok "Git: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"

# ── 6. Dev Tools ──────────────────────────────────────────────────────────────
h "Dev Tools  (optional)"
dim "Lazy-installed on first run into named volumes — instant on every start after."
echo
echo -e "  ${BOLD}Languages & runtimes${NC}"
echo -e "    ${GREEN}java${NC}     Java LTS via SDKMan — enterprise / Android / Spring"
echo -e "    ${GREEN}go${NC}       Go latest stable — fast compiled services"
echo -e "    ${GREEN}rust${NC}     Rust via rustup — systems / WASM / CLI tools"
echo -e "    ${GREEN}python${NC}   Poetry, black, ruff, mypy via uv — data / ML / scripts"
echo -e "    ${GREEN}deno${NC}     Deno — secure TypeScript runtime, no node_modules"
echo -e "    ${GREEN}bun${NC}      Bun — fast JS runtime + package manager"
echo -e "    ${GREEN}dotnet${NC}   .NET SDK LTS — C# / F# / ASP.NET"
echo
echo -e "  ${BOLD}Frontend${NC}"
echo -e "    ${GREEN}ts${NC}       TypeScript + ts-node + tsx — type-safe JS, works anywhere"
echo -e "    ${GREEN}react${NC}    Vite + create-react-app — React scaffolding & dev server"
echo -e "    ${GREEN}svelte${NC}   SvelteKit — lean reactive framework, no virtual DOM"
echo
echo -e "  ${BOLD}Git & utilities${NC}"
echo -e "    ${GREEN}lazygit${NC}  TUI git client — navigate branches/diffs without leaving terminal"
echo
dim "  cpp, php, ruby require a rebuild (set INSTALL_CPP/PHP/RUBY=true then ./run.sh --build)."
ask INSTALL_TOOLS "Enter tools (comma-separated, or leave blank):" "$(_e INSTALL_TOOLS "")"
[ -n "$INSTALL_TOOLS" ] && ok "Tools: $INSTALL_TOOLS" || dim "  Tools: none"

# ── 7. Plugins & Tools ────────────────────────────────────────────────────────
h "Plugins & Tools  (optional)"
dim "Installed once, sentineled. Add/remove later: ./run.sh plugins add <name> / remove <name>"
echo

if [ "$CODING_CLI" = "claude" ]; then
    echo -e "  ${BOLD}Token & context optimization${NC}  ${DIM}(Claude Code only)${NC}"
    echo -e "    ${GREEN}caveman${NC}       Rewrites Claude's output as caveman-speak — ~70% fewer tokens, same accuracy"
    echo -e "    ${GREEN}context-mode${NC}  Sandboxes tool output so raw data never enters context — ~98% savings"
    echo
    echo -e "  ${BOLD}Usage monitoring${NC}  ${DIM}(standalone, any CLI)${NC}"
    echo -e "    ${GREEN}ccusage${NC}       Dashboard for session cost & token usage — run: npx ccusage"
    echo -e "    ${GREEN}claude-hud${NC}    Live token/context/agent overlay inside Claude Code  ${DIM}(Claude only)${NC}"
    echo
    echo -e "  ${BOLD}Memory & session continuity${NC}"
    echo -e "    ${GREEN}claude-mem${NC}    Auto-captures session activity, compresses it, injects context next session  ${DIM}(Claude only, AGPL-3.0)${NC}"
    echo -e "    ${GREEN}mempalace${NC}     Spatial AI memory indexed locally — run: mempalace init /workspace  ${DIM}(any CLI)${NC}"
    echo
    echo -e "  ${BOLD}Codebase intelligence${NC}  ${DIM}(standalone, any CLI)${NC}"
    echo -e "    ${GREEN}graphify${NC}      Parses your codebase into a queryable knowledge graph — run: /graphify ."
    echo
    echo -e "  ${BOLD}Rules & skill packs${NC}  ${DIM}(Claude Code only)${NC}"
    echo -e "    ${GREEN}karpathy-skills${NC}        Injects Karpathy's 4 principles: think first, minimal code, surgical edits"
    echo -e "    ${GREEN}everything-claude-code${NC}  48 agents + 183 skills + 34 language rules  ${DIM}(large — adds context overhead)${NC}"
    echo
    echo -e "  ${BOLD}Custom — add anything not in the list:${NC}"
    echo -e "    ${GREEN}owner/repo${NC}   GitHub repo with a .claude-plugin folder (Claude only)"
    echo -e "    ${GREEN}npm:pkg${NC}      npm install -g (any CLI)"
    echo -e "    ${GREEN}uv:pkg${NC}       uv tool install (any CLI)"
    dim "  Example: caveman,ccusage,myorg/myplugin,npm:my-tool"
else
    dim "  Showing plugins compatible with $CODING_CLI."
    dim "  Claude-only plugins (caveman, context-mode, claude-mem, claude-hud, karpathy-skills, everything-claude-code)"
    dim "  are not available with this CLI. Switch to claude to use them: ./run.sh switch claude"
    echo
    echo -e "  ${BOLD}Usage monitoring${NC}  ${DIM}(standalone, any CLI)${NC}"
    echo -e "    ${GREEN}ccusage${NC}    Dashboard for session cost & token usage — run: npx ccusage"
    echo
    echo -e "  ${BOLD}Memory & session continuity${NC}  ${DIM}(any CLI)${NC}"
    echo -e "    ${GREEN}mempalace${NC}  Spatial AI memory indexed locally — run: mempalace init /workspace"
    echo
    echo -e "  ${BOLD}Codebase intelligence${NC}  ${DIM}(any CLI)${NC}"
    echo -e "    ${GREEN}graphify${NC}   Parses your codebase into a queryable knowledge graph — run: /graphify ."
    echo
    echo -e "  ${BOLD}Custom:${NC}"
    echo -e "    ${GREEN}npm:pkg${NC}    npm install -g (any CLI)"
    echo -e "    ${GREEN}uv:pkg${NC}     uv tool install (any CLI)"
    dim "  Example: ccusage,mempalace,npm:my-tool"
fi
echo
ask INSTALL_PLUGINS "Enter plugins (comma-separated, or leave blank):" "$(_e INSTALL_PLUGINS "")"
[ -n "$INSTALL_PLUGINS" ] && ok "Plugins: $INSTALL_PLUGINS" || dim "  Plugins: none"

# ── 8. Bring-your-own configs ─────────────────────────────────────────────────
h "Bring-Your-Own Configs  (optional)"
dim "  Point to files on your host — they'll be mounted read-only into the container."
dim "  Leave blank to use the built-in defaults."
echo

ask CCSTATUSLINE_CONFIG "ccstatusline settings.json path (blank = use built-in):" "$(_e CCSTATUSLINE_CONFIG "")"
ask ZSH_EXTRA_CONFIG    "Extra zsh config file to source at shell start (blank = none):" "$(_e ZSH_EXTRA_CONFIG "")"
ask STARSHIP_CONFIG     "starship.toml path (blank = use built-in):" "$(_e STARSHIP_CONFIG "")"
CCSTATUSLINE_CONFIG="${CCSTATUSLINE_CONFIG/#\~/$HOME}"
ZSH_EXTRA_CONFIG="${ZSH_EXTRA_CONFIG/#\~/$HOME}"
STARSHIP_CONFIG="${STARSHIP_CONFIG/#\~/$HOME}"
[ -n "$CCSTATUSLINE_CONFIG" ] && ok "ccstatusline: $CCSTATUSLINE_CONFIG" || true
[ -n "$ZSH_EXTRA_CONFIG" ]    && ok "zsh extra:    $ZSH_EXTRA_CONFIG"    || true
[ -n "$STARSHIP_CONFIG" ]     && ok "starship:     $STARSHIP_CONFIG"     || true

# ── 9. System UID/GID ─────────────────────────────────────────────────────────
HOST_UID="${HOST_UID:-$(id -u 2>/dev/null || echo 1000)}"
HOST_GID="${HOST_GID:-$(id -g 2>/dev/null || echo 1000)}"

# ── 10. Summary ───────────────────────────────────────────────────────────────
h "Summary"
echo
printf "  %-24s %s\n" "CLI:"            "$CODING_CLI"
printf "  %-24s %s\n" "Container:"      "$CONTAINER_NAME"
printf "  %-24s %s\n" "Project:"        "$PROJECT_DIR"
[ -n "$EXTRA_WORKSPACES" ] && printf "  %-24s %s\n" "Extra workspaces:" "$EXTRA_WORKSPACES"
printf "  %-24s %s\n" "Claude dir:"     "${CLAUDE_DIR:-named volume (isolated)}"
printf "  %-24s %s\n" "Anthropic key:"  "$([ -n "$ANTHROPIC_API_KEY" ] && echo "set" || echo "not set")"
printf "  %-24s %s\n" "Git name:"       "${GIT_AUTHOR_NAME:-not set}"
printf "  %-24s %s\n" "Git email:"      "${GIT_AUTHOR_EMAIL:-not set}"
printf "  %-24s %s\n" "Dev tools:"      "${INSTALL_TOOLS:-none}"
printf "  %-24s %s\n" "Plugins:"        "${INSTALL_PLUGINS:-none}"
[ -n "$CCSTATUSLINE_CONFIG" ] && printf "  %-24s %s\n" "ccstatusline config:" "$CCSTATUSLINE_CONFIG"
[ -n "$ZSH_EXTRA_CONFIG" ]    && printf "  %-24s %s\n" "zsh extra config:"    "$ZSH_EXTRA_CONFIG"
[ -n "$STARSHIP_CONFIG" ]     && printf "  %-24s %s\n" "starship config:"     "$STARSHIP_CONFIG"
echo

yn _write "Write .env and continue?" "y"
[ "$_write" != "y" ] && { echo "Aborted."; exit 0; }

# ── 11. Write .env ────────────────────────────────────────────────────────────

_qval() {
    local v="$1"
    # Quote if contains spaces; leave plain otherwise
    if [[ "$v" == *" "* ]]; then echo "\"$v\""; else echo "$v"; fi
}

cat > .env << EOF
# codetainyrrr configuration
# Generated by setup.sh — edit manually or re-run setup.sh to update.

HOST_UID=$HOST_UID
HOST_GID=$HOST_GID

# ── AI CLI ──────────────────────────────────────────────────────────────────
# Options: claude | codex | gemini | opencode | pi | goose | aider | kilo | cn
CODING_CLI=$CODING_CLI
CONTAINER_NAME=$CONTAINER_NAME

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_DIR=$(      _qval "$PROJECT_DIR")
EXTRA_WORKSPACES=$( _qval "$EXTRA_WORKSPACES")

# Claude config — leave blank to use an isolated named volume (recommended)
CLAUDE_DIR=$(       _qval "$CLAUDE_DIR")
CLAUDE_JSON=$(      _qval "$CLAUDE_JSON")

# ── API keys ─────────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
OPENAI_API_KEY=$OPENAI_API_KEY
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
GEMINI_API_KEY=$GEMINI_API_KEY

# ── Git identity ─────────────────────────────────────────────────────────────
GIT_AUTHOR_NAME=$(  _qval "$GIT_AUTHOR_NAME")
GIT_AUTHOR_EMAIL=$( _qval "$GIT_AUTHOR_EMAIL")

# ── Dev tools ────────────────────────────────────────────────────────────────
# Options: java,go,rust,ts,react,svelte,python,deno,bun,dotnet,lazygit
# (cpp, php, ruby are baked in at build time — set to true in .env to include)
INSTALL_TOOLS=$INSTALL_TOOLS
# INSTALL_CPP=false
# INSTALL_PHP=false
# INSTALL_RUBY=false

# ── Plugins ──────────────────────────────────────────────────────────────────
# Built-in: caveman,context-mode,claude-mem,claude-hud,ccusage,graphify,
#           mempalace,everything-claude-code,karpathy-skills
# Custom:   owner/repo  (Claude),  npm:pkg,  uv:pkg
INSTALL_PLUGINS=$INSTALL_PLUGINS

# ── Bring-your-own configs ────────────────────────────────────────────────────
# Host paths → mounted read-only. Leave blank to use built-in defaults.
CCSTATUSLINE_CONFIG=$CCSTATUSLINE_CONFIG
ZSH_EXTRA_CONFIG=$ZSH_EXTRA_CONFIG
STARSHIP_CONFIG=$STARSHIP_CONFIG
EOF

ok ".env written."

# ── 12. Build + start ─────────────────────────────────────────────────────────
echo
yn _build "Build the Docker image now? (required on first run, ~30s)" "y"
if [ "$_build" = "y" ]; then
    echo
    bash "$SCRIPT_DIR/run.sh" --build --detach || true
    ok "Image built."
fi

echo
yn _start "Start the container now?" "y"
if [ "$_start" = "y" ]; then
    echo
    exec bash "$SCRIPT_DIR/run.sh"
fi

echo
echo -e "${BOLD}${GREEN}Setup complete!${NC}"
echo -e "  Run ${CYAN}./run.sh${NC}         to start (auto-connects if already running)"
echo -e "  Run ${CYAN}./run.sh connect${NC}  to attach another shell"
echo -e "  Run ${CYAN}./run.sh stop${NC}     to stop the container"
[ -n "$INSTALL_PLUGINS" ] && grep -q "mempalace" <<< "$INSTALL_PLUGINS" 2>/dev/null && \
    warn "mempalace: run 'mempalace init /workspace' inside the container on first use."
echo

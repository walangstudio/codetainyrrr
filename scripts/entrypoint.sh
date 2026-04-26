#!/usr/bin/env bash
# entrypoint.sh — installs the selected coding CLI and any dev tools on first run,
# then dispatches. Named volumes persist everything so subsequent starts are instant.
#
# CODING_CLI: claude | codex | gemini | opencode | pi | goose | aider | kilo | cn
# INSTALL_TOOLS: comma-separated — java,go,rust,ts,react,svelte,python,deno,bun,dotnet,lazygit
#                cpp, php, ruby are baked into the image at build time (see Dockerfile)
# INSTALL_PLUGINS: comma-separated — built-in names or custom entries:
#   Built-in:  caveman,context-mode,claude-mem,claude-hud,ccusage,graphify,
#              mempalace,everything-claude-code,karpathy-skills
#   Custom:    owner/repo        → claude plugin from that GitHub repo
#              npm:package-name  → npm install -g
#              uv:package-name   → uv tool install
set -e

# If started as root (default — no --user flag), fix /home/dev ownership and
# drop to the dev user. This handles Docker Desktop volume seeding leaving
# /home/dev owned by root.
if [ "$(id -u)" = "0" ]; then
    _uid="${HOST_UID:-1000}"
    _gid="${HOST_GID:-1000}"
    # Docker Desktop for Windows seeds volumes with the host Windows UID.
    # Batch-chown only files/dirs that are wrong — no-op on subsequent starts.
    find /home/dev \( -not -user "$_uid" -o -not -group "$_gid" \) \
        -exec chown "${_uid}:${_gid}" {} + 2>/dev/null || true
    export HOME=/home/dev
    exec gosu "${_uid}:${_gid}" "$0" "$@"
fi

NVM_DIR="$HOME/.nvm"
SDKMAN_DIR="$HOME/.sdkman"
CODING_CLI="${CODING_CLI:-claude}"
INSTALL_TOOLS="${INSTALL_TOOLS:-}"
INSTALL_PLUGINS="${INSTALL_PLUGINS:-}"

_log() { echo "[codetainyrrr] $*"; }

_has_tool() { [[ ",$INSTALL_TOOLS," == *",$1,"* ]]; }

# ---------------------------------------------------------------------------
# Tool installer helpers
# ---------------------------------------------------------------------------

_ensure_nvm() {
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        _log "Installing NVM + Node LTS..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
        export NVM_DIR
        . "$NVM_DIR/nvm.sh"
        nvm install --lts
        nvm alias default node
        _log "Node $(node --version) ready."
    fi
    export NVM_DIR
    . "$NVM_DIR/nvm.sh"
}

_ensure_uv() {
    if [ ! -f "$HOME/.local/bin/uv" ]; then
        _log "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    export PATH="$HOME/.local/bin:$PATH"
}

_ensure_rtk() {
    if [ ! -f "$HOME/.local/bin/rtk" ]; then
        _log "Installing RTK..."
        mkdir -p "$HOME/.local/bin"
        curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
        rtk init -g 2>/dev/null || true
    fi
}

_install_java() {
    if [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
        _log "Installing SDKMan..."
        curl -fsSL https://get.sdkman.io | bash || true
    fi
    if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
        source "$SDKMAN_DIR/bin/sdkman-init.sh"
        sdk list java 2>/dev/null | grep -q ' installed' || { _log "Installing Java LTS..."; sdk install java; }
    else
        _log "SDKMan install failed — skipping Java. Run install-sdkman inside the container."
    fi
}

_install_go() {
    if [ ! -f "$HOME/go/sdk/go/bin/go" ]; then
        _log "Installing Go..."
        GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
        mkdir -p "$HOME/go/sdk"
        curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" \
            | tar -xz -C "$HOME/go/sdk/"
        mv "$HOME/go/sdk/go" "$HOME/go/sdk/go-bin"
        # rename so we can detect it next time
        mv "$HOME/go/sdk/go-bin" "$HOME/go/sdk/go"
        _log "Go ${GO_VERSION} ready."
    fi
    export GOROOT="$HOME/go/sdk/go"
    export GOPATH="$HOME/go"
    export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
}

_install_rust() {
    if [ ! -f "$HOME/.cargo/bin/rustc" ]; then
        _log "Installing Rust via rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path
        _log "Rust $(~/.cargo/bin/rustc --version) ready."
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
}

_install_ts() {
    _ensure_nvm
    if ! command -v tsc &>/dev/null; then
        _log "Installing TypeScript, ts-node, tsx..."
        npm install -g typescript ts-node tsx
    fi
}

_install_react() {
    _ensure_nvm
    if ! command -v create-react-app &>/dev/null && ! command -v vite &>/dev/null; then
        _log "Installing React tooling (vite, create-react-app)..."
        npm install -g vite create-react-app
    fi
}

_install_svelte() {
    _ensure_nvm
    if ! npm list -g @sveltejs/kit &>/dev/null 2>&1; then
        _log "Installing Svelte / SvelteKit tooling..."
        npm install -g svelte @sveltejs/kit
    fi
}

_install_python_tools() {
    _ensure_uv
    if ! command -v poetry &>/dev/null; then
        _log "Installing Python tools (poetry, pipenv, black, ruff, mypy)..."
        uv tool install poetry
        uv tool install pipenv
        uv tool install black
        uv tool install ruff
        uv tool install mypy
    fi
}

_install_deno() {
    if [ ! -f "$HOME/.deno/bin/deno" ]; then
        _log "Installing Deno..."
        curl -fsSL https://deno.land/install.sh | sh
        _log "Deno $("$HOME/.deno/bin/deno" --version | head -1) ready."
    fi
    export PATH="$HOME/.deno/bin:$PATH"
}

_install_bun() {
    if [ ! -f "$HOME/.bun/bin/bun" ]; then
        _log "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        _log "Bun $("$HOME/.bun/bin/bun" --version) ready."
    fi
    export PATH="$HOME/.bun/bin:$PATH"
}

_install_dotnet() {
    if [ ! -f "$HOME/.dotnet/dotnet" ]; then
        _log "Installing .NET SDK (LTS)..."
        curl -fsSL https://dot.net/v1/dotnet-install.sh \
            | bash -s -- --channel LTS --install-dir "$HOME/.dotnet"
        _log ".NET $("$HOME/.dotnet/dotnet" --version) ready."
    fi
    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
}

_install_lazygit() {
    if ! command -v lazygit &>/dev/null; then
        _log "Installing lazygit..."
        local ver
        ver=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | jq -r '.tag_name')
        curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/${ver}/lazygit_${ver#v}_Linux_x86_64.tar.gz" \
            | tar -xz -C "$HOME/.local/bin" lazygit
        _log "lazygit ${ver} ready."
    fi
}

# ---------------------------------------------------------------------------
# Plugin helpers
# ---------------------------------------------------------------------------

_plugin_sentinel() { echo "$HOME/.local/share/codetainyrrr/plugins/$1.installed"; }
_plugin_done()     { [ -f "$(_plugin_sentinel "$1")" ]; }
_mark_plugin()     { mkdir -p "$(dirname "$(_plugin_sentinel "$1")")"; touch "$(_plugin_sentinel "$1")"; }

_install_claude_plugin() {
    local name="$1" repo="$2" marketplace="${3:-$1}"
    _plugin_done "$name" && return 0
    command -v claude &>/dev/null || { _log "Skipping plugin $name — claude not installed"; return 0; }
    _log "Installing plugin $name..."
    claude plugin marketplace add "$repo" 2>/dev/null || true
    claude plugin install "${name}@${marketplace}" --scope user 2>/dev/null || true
    _mark_plugin "$name"
}

# Generic handlers — used for custom INSTALL_PLUGINS entries
_install_plugin_github() {
    local repo="$1" name="${1#*/}"
    _install_claude_plugin "$name" "$repo" "$name"
}

_install_plugin_npm_pkg() {
    local pkg="$1" name
    name="$(echo "${pkg##*/}" | tr '@/' '__')"
    _plugin_done "npm-${name}" && return 0
    _log "Installing npm package $pkg..."
    _ensure_nvm
    npm install -g "$pkg" && _mark_plugin "npm-${name}" || true
}

_install_plugin_uv_pkg() {
    local pkg="$1" name="${1##*/}"
    _plugin_done "uv-${name}" && return 0
    _log "Installing Python package $pkg via uv..."
    _ensure_uv
    uv tool install "$pkg" && _mark_plugin "uv-${name}" || true
}

_install_plugin_caveman() {
    _install_claude_plugin "caveman" "JuliusBrussee/caveman" "caveman"
}

_install_plugin_context_mode() {
    _install_claude_plugin "context-mode" "mksglu/context-mode" "context-mode"
}

_install_plugin_claude_mem() {
    _install_claude_plugin "claude-mem" "thedotmack/claude-mem" "claude-mem"
}

_install_plugin_claude_hud() {
    _install_claude_plugin "claude-hud" "jarrodwatts/claude-hud" "claude-hud"
}

_install_plugin_ccusage() {
    _plugin_done "ccusage" && return 0
    command -v ccusage &>/dev/null && { _mark_plugin "ccusage"; return 0; }
    _log "Installing ccusage..."
    _ensure_nvm
    npm install -g ccusage && _mark_plugin "ccusage" || true
}

_install_plugin_graphify() {
    _plugin_done "graphify" && return 0
    _log "Installing graphify..."
    _ensure_uv
    uv tool install graphifyy 2>/dev/null || true
    command -v graphify &>/dev/null && { graphify install 2>/dev/null || true; _mark_plugin "graphify"; } || true
}

_install_plugin_mempalace() {
    _plugin_done "mempalace" && return 0
    _log "Installing mempalace..."
    _ensure_uv
    uv tool install mempalace 2>/dev/null && _mark_plugin "mempalace" || true
    # Run: mempalace init /workspace  — inside the container on first project use
}

_install_plugin_everything_cc() {
    _install_claude_plugin "everything-claude-code" "affaan-m/everything-claude-code" "everything-claude-code"
}

_install_plugin_karpathy() {
    _install_claude_plugin "andrej-karpathy-skills" "forrestchang/andrej-karpathy-skills" "karpathy-skills"
}

# ---------------------------------------------------------------------------
# Claude-specific helpers
# ---------------------------------------------------------------------------

_setup_claude_json() {
    # When .claude is a named volume (not a host bind-mount), .claude.json won't
    # exist on first run. Redirect it into the volume so it persists.
    # If the host bind-mounted a real file here, leave it alone.
    if [ ! -f "$HOME/.claude.json" ] || [ -L "$HOME/.claude.json" ]; then
        mkdir -p "$HOME/.claude"
        touch "$HOME/.claude/.claude.json" 2>/dev/null || true
        ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json" 2>/dev/null || true
    fi
}

_apply_claude_defaults() {
    # Seed opinionated defaults into ~/.claude/settings.json on first run.
    # Existing user values are preserved — only missing keys are added.
    #   dangerouslySkipPermissions: true  — auto-approve tool use; this image
    #     is a sandboxed dev container, so the broader permission system
    #     would just produce noise.
    #   includeCoAuthoredBy:        false — no "Co-Authored-By: Claude" line
    #     on commits made through Claude Code.
    _setup_claude_json
    [ -d "$HOME/.claude" ] || return 0
    local settings="$HOME/.claude/settings.json"
    [ -f "$settings" ] || echo '{}' > "$settings"
    local tmp; tmp=$(mktemp)
    jq '
        (if has("dangerouslySkipPermissions") then . else . + {"dangerouslySkipPermissions": true} end) |
        (if has("includeCoAuthoredBy")        then . else . + {"includeCoAuthoredBy":        false} end)
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

_wire_ccstatusline() {
    _apply_claude_defaults
    local settings="$HOME/.claude/settings.json"
    [ -f "$settings" ] || return 0
    if ! jq -e '.statusLine' "$settings" &>/dev/null 2>&1; then
        _log "Wiring ccstatusline into Claude Code settings..."
        local tmp
        tmp=$(mktemp)
        jq '. + {"statusLine": {"type": "command", "command": "npx -y ccstatusline@latest", "padding": 0}, "enabledPlugins": {}}' \
            "$settings" > "$tmp" && mv "$tmp" "$settings"
    fi
    local cc_config="$HOME/.config/ccstatusline/settings.json"
    if [ ! -f "$cc_config" ]; then
        mkdir -p "$(dirname "$cc_config")"
        cat > "$cc_config" <<'EOF'
{
  "version": 3,
  "lines": [
    [
      { "id": "1", "type": "model", "color": "brightRed" },
      { "id": "3", "type": "context-length", "color": "brightGreen" },
      { "id": "5", "type": "git-branch", "color": "cyan" },
      { "id": "7", "type": "git-changes", "color": "blue" },
      { "id": "2c02d9b7-3ece-4ef1-9d4e-e06735d6241a", "type": "session-cost" },
      { "id": "a3bb834a-5d01-4973-94e8-002c9eea6a14", "type": "skills", "color": "brightMagenta" },
      { "id": "d1719f1d-995a-481c-aab6-8bf4a50f1004", "type": "free-memory", "color": "white" }
    ],
    [
      { "id": "07059a63-67fb-4cf6-b2bc-cbb1273e8ef5", "type": "session-usage", "color": "green" },
      { "id": "6c62a8cc-d1ed-4dbd-9ec6-3d853f7d85a8", "type": "reset-timer", "rawValue": false, "color": "" },
      { "id": "0fe0d8c9-3223-4b1b-8b3e-f2027d29041a", "type": "weekly-usage", "metadata": { "display": "time" }, "rawValue": false, "color": "brightMagenta" },
      { "id": "3f859017-75e1-4826-a010-95778a9cc7a1", "type": "weekly-reset-timer", "metadata": { "display": "time" }, "color": "" }
    ],
    [
      { "id": "509657f1-8f11-4d3b-9c61-732aff170c9c", "type": "tokens-cached", "rawValue": false, "color": "brightBlack" },
      { "id": "471bb393-5359-4ef0-91fc-97cc6a27383a", "type": "tokens-input", "color": "cyan" },
      { "id": "4b6494ee-5ffb-4818-9f02-daf45b0e101e", "type": "tokens-output", "backgroundColor": "bgBrightBlack" },
      { "id": "6628efbf-9c2e-444e-9338-503c50beae97", "type": "tokens-total", "color": "brightRed" },
      { "id": "aea3ab80-2ed9-4527-93b4-af14b27f7e7b", "type": "total-speed", "color": "brightBlue" },
      { "id": "9d0ec75c-0892-4139-843a-2662ad1ffbbd", "type": "context-bar", "color": "brightGreen" }
    ]
  ],
  "flexMode": "full-minus-40",
  "compactThreshold": 60,
  "colorLevel": 2,
  "inheritSeparatorColors": false,
  "globalBold": false,
  "powerline": {
    "enabled": true,
    "separators": [""],
    "separatorInvertBackground": [false],
    "startCaps": [],
    "endCaps": [],
    "autoAlign": false,
    "theme": "catppuccin"
  },
  "defaultPadding": " "
}
EOF
    fi
}

_setup_zsh() {
    local plugins_dir="$HOME/.config/zsh/plugins"
    mkdir -p "$plugins_dir"
    if [ ! -d "$plugins_dir/zsh-autosuggestions" ]; then
        _log "Installing zsh-autosuggestions..."
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            "$plugins_dir/zsh-autosuggestions" 2>/dev/null || true
    fi
    if [ ! -d "$plugins_dir/zsh-syntax-highlighting" ]; then
        _log "Installing zsh-syntax-highlighting..."
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
            "$plugins_dir/zsh-syntax-highlighting" 2>/dev/null || true
    fi
    if [ ! -f "$HOME/.local/bin/starship" ]; then
        _log "Installing Starship prompt..."
        curl -sS https://starship.rs/install.sh | sh -s -- --bin-dir "$HOME/.local/bin" --yes 2>/dev/null || true
    fi
    if [ ! -f "$HOME/.config/starship.toml" ]; then
        cat > "$HOME/.config/starship.toml" <<'EOF'
format = """
$directory$git_branch$git_status$cmd_duration
$character"""

[directory]
truncation_length = 3
truncate_to_repo = true

[git_branch]
symbol = " "

[git_status]
ahead = "⇡${count}"
behind = "⇣${count}"
diverged = "⇕⇡${ahead_count}⇣${behind_count}"
modified = "!${count}"
untracked = "?${count}"
staged = "+${count}"

[cmd_duration]
min_time = 2000

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
EOF
    fi
}

# ---------------------------------------------------------------------------
# Coding CLI install
# ---------------------------------------------------------------------------

case "$CODING_CLI" in
  claude)
    _ensure_nvm
    _ensure_rtk
    command -v claude &>/dev/null || { curl -fsSL https://claude.ai/install.sh | bash; export PATH="$HOME/.local/bin:$PATH"; }
    _wire_ccstatusline
    ;;
  opencode)
    _ensure_nvm
    _ensure_rtk
    command -v opencode &>/dev/null || { curl -fsSL https://opencode.ai/install | bash; export PATH="$HOME/.local/bin:$PATH"; }
    ;;
  kilo|kilocode)
    _ensure_nvm
    _ensure_rtk
    command -v kilo &>/dev/null || npm install -g @kilocode/cli
    CODING_CLI=kilo
    ;;
  aider)
    _ensure_uv
    _ensure_rtk
    command -v aider &>/dev/null || uv tool install aider-chat
    ;;
  goose)
    _ensure_rtk
    if ! command -v goose &>/dev/null; then
        curl -fsSL https://install.goose.rs | bash
        export PATH="$HOME/.local/bin:$HOME/.config/goose/bin:$PATH"
    fi
    ;;
  cn|continue)
    _ensure_nvm
    _ensure_rtk
    command -v cn &>/dev/null || npm install -g @continuedev/cli
    CODING_CLI=cn
    ;;
  pi)
    _ensure_nvm
    _ensure_rtk
    command -v pi &>/dev/null || npm install -g @mariozechner/pi-coding-agent
    ;;
  codex)
    _ensure_nvm
    command -v codex &>/dev/null || npm install -g @openai/codex
    ;;
  gemini)
    _ensure_nvm
    command -v gemini &>/dev/null || npm install -g @google/gemini-cli
    ;;
  zsh|bash|sh|*) ;;
esac

# ---------------------------------------------------------------------------
# Dev tool installs (driven by INSTALL_TOOLS env var)
# ---------------------------------------------------------------------------

_has_tool java       && _install_java
_has_tool go         && _install_go
_has_tool rust       && _install_rust
_has_tool ts         && _install_ts
_has_tool typescript && _install_ts
_has_tool react      && _install_react
_has_tool svelte     && _install_svelte
_has_tool python     && _install_python_tools
_has_tool deno       && _install_deno
_has_tool bun        && _install_bun
_has_tool dotnet     && _install_dotnet
_has_tool lazygit    && _install_lazygit

# ---------------------------------------------------------------------------
# Plugin installs (driven by INSTALL_PLUGINS env var)
# ---------------------------------------------------------------------------

# Claude Code plugins — only meaningful when CODING_CLI=claude
_is_claude_plugin() {
    case "$1" in
        caveman|context-mode|claude-mem|claude-hud|everything-claude-code|karpathy-skills) return 0 ;;
        */*)  return 0 ;;  # owner/repo installs are always Claude plugins
        *)    return 1 ;;
    esac
}

_do_plugin_installs() {
    [ -z "$INSTALL_PLUGINS" ] && return 0
    IFS=',' read -ra _plugin_list <<< "$INSTALL_PLUGINS"
    for _p in "${_plugin_list[@]}"; do
        _p="${_p// /}"   # strip spaces
        [ -z "$_p" ] && continue
        if [ "$CODING_CLI" != "claude" ] && _is_claude_plugin "$_p"; then
            _log "Skipping Claude plugin '$_p' (CODING_CLI=$CODING_CLI)"
            continue
        fi
        case "$_p" in
            caveman)                _install_plugin_caveman ;;
            context-mode)           _install_plugin_context_mode ;;
            claude-mem)             _install_plugin_claude_mem ;;
            claude-hud)             _install_plugin_claude_hud ;;
            ccusage)                _install_plugin_ccusage ;;
            graphify)               _install_plugin_graphify ;;
            mempalace)              _install_plugin_mempalace ;;
            everything-claude-code) _install_plugin_everything_cc ;;
            karpathy-skills)        _install_plugin_karpathy ;;
            npm:*)                  _install_plugin_npm_pkg "${_p#npm:}" ;;
            uv:*)                   _install_plugin_uv_pkg  "${_p#uv:}" ;;
            */*)                    _install_plugin_github  "$_p" ;;
            *)                      _log "Unknown plugin '$_p' — use owner/repo, npm:pkg, or uv:pkg for custom installs" ;;
        esac
    done
}

# --plugins mode: re-run only the plugin install section (called via docker exec)
if [ "${1:-}" = "--plugins" ]; then
    _log "Re-running plugin installs (INSTALL_PLUGINS=$INSTALL_PLUGINS)"
    _ensure_nvm 2>/dev/null || true
    _do_plugin_installs
    exit 0
fi

_do_plugin_installs

# ---------------------------------------------------------------------------
# Load SDKMan if present
# ---------------------------------------------------------------------------
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# SDKMan install helper (always available in PATH)
cat > "$HOME/.local/bin/install-sdkman" <<'EOF'
#!/usr/bin/env bash
curl -fsSL https://get.sdkman.io | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
echo "SDKMan installed. Run: sdk install java"
EOF
chmod +x "$HOME/.local/bin/install-sdkman"

# ---------------------------------------------------------------------------
# PATH consolidation
# ---------------------------------------------------------------------------
export PATH="\
$HOME/.local/bin:\
$HOME/.cargo/bin:\
$HOME/.deno/bin:\
$HOME/.bun/bin:\
$HOME/.dotnet:\
$HOME/.dotnet/tools:\
$PATH"

# Go — only add if sdk is present
[ -d "$HOME/go/sdk/go/bin" ] && export PATH="$HOME/go/sdk/go/bin:$HOME/go/bin:$PATH"

# ---------------------------------------------------------------------------
# Wire .zshrc (idempotent)
# ---------------------------------------------------------------------------
_setup_zsh

ZSHRC="$HOME/.zshrc"
if ! grep -q '# codetainyrrr init' "$ZSHRC" 2>/dev/null; then
    cat >> "$ZSHRC" <<'PROFILE'

# codetainyrrr init

# --- Runtimes ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
[ -d "$HOME/go/sdk/go/bin" ] && export GOROOT="$HOME/go/sdk/go" GOPATH="$HOME/go"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.deno/bin:$HOME/.bun/bin:$HOME/.dotnet:$HOME/.dotnet/tools:${GOROOT:+$GOROOT/bin:}${GOPATH:+$GOPATH/bin:}$PATH"

# --- History ---
HISTSIZE=50000
SAVEHIST=50000
HISTFILE="$HOME/.zsh_history"
setopt HIST_IGNORE_ALL_DUPS HIST_SAVE_NO_DUPS SHARE_HISTORY HIST_REDUCE_BLANKS

# --- Completion ---
autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# --- Plugins ---
_src() { [ -f "$1" ] && source "$1"; }
_src "$HOME/.config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
_src "$HOME/.config/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# --- Aliases ---
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -lh --color=auto'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias ..='cd ..'
alias ...='cd ../..'

# --- Prompt ---
command -v starship &>/dev/null && eval "$(starship init zsh)"

# --- User extra config (bind-mounted from host via ZSH_EXTRA_CONFIG) ---
[ -f "$HOME/.config/zsh/extra.zsh" ] && source "$HOME/.config/zsh/extra.zsh"
PROFILE
fi

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    exec /bin/zsh -l
elif [ "$1" = "--daemon" ]; then
    _log "Daemon mode — connect with: docker exec -it codetainyrrr zsh"
    exec sleep infinity
elif [[ "$1" == --* ]] || [[ "$1" == -* ]]; then
    exec "$CODING_CLI" "$@"
else
    exec "$@"
fi

#!/usr/bin/env bash
# entrypoint.sh — installs the selected coding CLI and any dev tools on first run,
# then dispatches. Named volumes persist everything so subsequent starts are instant.
#
# CODING_CLI: claude | codex | gemini | opencode | pi | goose | aider | kilo | cn
# INSTALL_TOOLS: comma-separated — rtk,java,go,rust,node,pnpm,yarn,ts,react,svelte,python,deno,bun,dotnet,lazygit
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
    # Ensure common dirs exist with correct ownership so tools never hit EPERM on first write.
    mkdir -p /home/dev/.cache /home/dev/.config /home/dev/.local/bin
    chown "${_uid}:${_gid}" /home/dev/.cache /home/dev/.config /home/dev/.local/bin
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

_install_rtk() { _ensure_rtk; }

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
        sdk list java 2>/dev/null | grep -q ' installed' || {
            _log "Installing Java LTS..."
            SDKMAN_AUTO_ANSWER=true sdk install java || _log "[WARN] Java install failed — run 'sdk install java' inside the container"
        }
    else
        _log "SDKMan install failed — skipping Java. Run install-sdkman inside the container."
    fi
}

_install_go() {
    if [ ! -f "$HOME/go/sdk/go/bin/go" ]; then
        _log "Installing Go..."
        local GO_VERSION
        GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
        if [ -z "$GO_VERSION" ]; then
            _log "[WARN] Could not fetch Go version from go.dev — check network and restart container to retry"
            return 1
        fi
        mkdir -p "$HOME/go/sdk"
        if ! curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" \
                | tar -xz -C "$HOME/go/sdk/"; then
            rm -rf "$HOME/go/sdk/go"
            _log "[WARN] Go download/extraction failed — restart container to retry"
            return 1
        fi
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
    if ! command -v sv &>/dev/null; then
        _log "Installing SvelteKit CLI (sv)..."
        npm install -g @sveltejs/cli
    fi
}

_install_python() { _install_python_tools; }

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

_install_node() {
    _ensure_nvm
    export NVM_DIR
    . "$NVM_DIR/nvm.sh"
}

_install_pnpm() {
    _ensure_nvm
    if ! command -v pnpm >/dev/null 2>&1; then
        _log "Installing pnpm via corepack..."
        corepack enable >/dev/null 2>&1 || true
        corepack prepare pnpm@latest --activate
        _log "pnpm $(pnpm --version) ready."
    fi
}

_install_yarn() {
    _ensure_nvm
    if ! command -v yarn >/dev/null 2>&1; then
        _log "Installing Yarn via corepack..."
        corepack enable >/dev/null 2>&1 || true
        corepack prepare yarn@stable --activate
        _log "Yarn $(yarn --version) ready."
    fi
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

_install_cpp() {
    command -v g++ &>/dev/null && return 0
    _log "Installing C++ tools (build-essential, clang, cmake, gdb, valgrind)..."
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends \
        build-essential clang cmake gdb valgrind
}

_install_php() {
    command -v php &>/dev/null && return 0
    _log "Installing PHP..."
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends \
        php-cli php-mbstring php-xml php-curl
}

_install_ruby() {
    command -v ruby &>/dev/null && return 0
    _log "Installing Ruby..."
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends ruby-full
}

_install_react_native() {
    _ensure_nvm
    command -v react-native &>/dev/null && return 0
    _log "Installing React Native CLI..."
    # better-sqlite3 (transitive dep) needs make + g++ for node-gyp
    command -v make &>/dev/null || {
        _log "Installing build tools for React Native native dependencies..."
        sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends build-essential
    }
    npm install -g @react-native-community/cli
}

_install_expo() {
    _ensure_nvm
    command -v expo &>/dev/null && return 0
    _log "Installing Expo CLI..."
    command -v make &>/dev/null || {
        sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends build-essential
    }
    npm install -g @expo/cli
}

_install_flutter() {
    if [ -d "$HOME/.flutter/bin" ]; then
        export PATH="$HOME/.flutter/bin:$PATH"
        return 0
    fi
    # Remove any partial clone from a previous failed attempt
    rm -rf "$HOME/.flutter"
    _log "Installing Flutter SDK (this may take a few minutes)..."
    if ! git clone --depth=1 https://github.com/flutter/flutter.git "$HOME/.flutter"; then
        rm -rf "$HOME/.flutter"
        _log "[WARN] Flutter clone failed (network timeout?) — restart container to retry"
        return 1
    fi
    export PATH="$HOME/.flutter/bin:$PATH"
    flutter precache --no-android --no-ios 2>/dev/null || true
    _log "Flutter $(flutter --version 2>/dev/null | head -1) ready."
}

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------

# Emit the merged array (tools or plugins) from /catalog.json + /catalog.user.json.
# User entries with the same key override built-ins.
_merged_catalog() {
    local type="$1"  # "tools" or "plugins"
    if [ -f /catalog.user.json ]; then
        jq -s --arg t "$type" '
            (.[0][$t] // []) as $base |
            (.[1][$t] // []) as $user |
            ($user | map(.key)) as $ukeys |
            ([$base[] | select(.key as $k | ($ukeys | index($k)) == null)] + $user)
        ' /catalog.json /catalog.user.json
    else
        jq --arg t "$type" '.[$t]' /catalog.json
    fi
}

# Return 0 if the given plugin key is usable under the current CODING_CLI.
# owner/repo entries (always Claude plugins) return 0 only for CODING_CLI=claude.
_supports_cli() {
    local key="$1" cli="${2:-$CODING_CLI}"
    case "$key" in
        */*)  [ "$cli" = "claude" ] && return 0 || return 1 ;;
    esac
    local clis
    clis=$(_merged_catalog "plugins" \
        | jq -r --arg k "$key" '.[] | select(.key == $k) | (.supported_clis // ["*"])[]' 2>/dev/null || true)
    [ -z "$clis" ] && return 0  # key not in catalog — allow (user might have it in INSTALL_PLUGINS directly)
    echo "$clis" | grep -qxF '*'   && return 0
    echo "$clis" | grep -qxF "$cli" && return 0
    return 1
}

# Install a tool/plugin from a user-supplied install spec.
# Specs: npm:<pkg>  uv:<pkg>  gh:<owner/repo>  git:<url>  <raw shell>
_install_from_git_repo() {
    local url="$1" name="$2" sentinel_key="$3"
    local dest="$HOME/.local/share/codetainyrrr/$name"
    if [ ! -d "$dest" ]; then
        git clone --depth=1 "$url" "$dest" || return 1
    fi
    if [ -f "$dest/install.sh" ]; then bash "$dest/install.sh" || return 1
    elif [ -f "$dest/postinstall.sh" ]; then bash "$dest/postinstall.sh" || return 1
    fi
    _mark_plugin "$sentinel_key"
}

_install_from_spec() {
    local key="$1" spec="$2"
    local sentinel_key="custom-${key//\//_}"
    _plugin_done "$sentinel_key" && return 0
    _log "Installing '$key' via spec: $spec"
    case "$spec" in
        npm:*)
            _ensure_nvm
            # shellcheck disable=SC2086
            npm install -g ${spec#npm:} && _mark_plugin "$sentinel_key" || return 1
            ;;
        uv:*)
            _ensure_uv
            uv tool install "${spec#uv:}" && _mark_plugin "$sentinel_key" || return 1
            ;;
        marketplace:*)
            # marketplace:<owner/repo>:<plugin-name>[:<marketplace-name>]
            local _rest="${spec#marketplace:}"
            local _repo="${_rest%%:*}"
            local _remainder="${_rest#*:}"
            local _plugin="${_remainder%%:*}"
            local _mkt="${_remainder#*:}"
            # If no third segment, marketplace-name equals plugin-name
            [ "$_mkt" = "$_plugin" ] && _mkt="$_plugin"
            _install_claude_plugin "$_plugin" "$_repo" "$_mkt" && _mark_plugin "$sentinel_key" || return 1
            ;;
        gh:*)
            local repo="${spec#gh:}"
            local name="${repo##*/}"
            _install_from_git_repo "https://github.com/${repo}" "$name" "$sentinel_key"
            ;;
        git:*)
            local url="${spec#git:}"
            local name="${url##*/}"; name="${name%.git}"
            _install_from_git_repo "$url" "$name" "$sentinel_key"
            ;;
        *)
            bash -c "$spec" && _mark_plugin "$sentinel_key" || return 1
            ;;
    esac
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
    local ok=0
    claude plugin marketplace add "$repo"        2>/dev/null && ok=1 || true
    claude plugin install "${name}@${marketplace}" --scope user 2>/dev/null && ok=1 || true
    if [ "$ok" = "1" ]; then
        _mark_plugin "$name"
    else
        _log "[WARN] Plugin $name: claude plugin commands failed — install manually inside the container with: claude plugin install $marketplace"
    fi
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
    export PATH="$HOME/.local/bin:$PATH"
    if uv tool install graphify; then
        graphify install 2>/dev/null || true
        _mark_plugin "graphify"
    else
        _log "[WARN] graphify install failed — run 'uv tool install graphify' inside the container to retry"
    fi
}

_install_plugin_mempalace() {
    _plugin_done "mempalace" && return 0
    _log "Installing mempalace..."
    _ensure_uv
    export PATH="$HOME/.local/bin:$PATH"
    if uv tool install mempalace; then
        _mark_plugin "mempalace"
        # Run: mempalace init /workspace  — inside the container on first project use
    else
        _log "[WARN] mempalace install failed — run 'uv tool install mempalace' inside the container to retry"
    fi
}

_install_plugin_everything_claude_code() {
    _install_claude_plugin "everything-claude-code" "affaan-m/everything-claude-code" "everything-claude-code"
}

_install_plugin_karpathy_skills() {
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
    jq '. + {"dangerouslySkipPermissions": true, "includeCoAuthoredBy": false}' \
        "$settings" > "$tmp" && mv "$tmp" "$settings"
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
# Coding CLI install — driven by catalog.json clis[*].install
# ---------------------------------------------------------------------------

# Normalize CLI key aliases before catalog lookup
case "$CODING_CLI" in
    kilocode) CODING_CLI=kilo ;;
    continue)  CODING_CLI=cn ;;
esac

_cli_spec()  { jq -r --arg k "$CODING_CLI" '.clis // [] | .[] | select(.key == $k) | .install // empty' /catalog.json 2>/dev/null || true; }
_cli_bin()   { jq -r --arg k "$CODING_CLI" '.clis // [] | .[] | select(.key == $k) | .bin // $k'        /catalog.json 2>/dev/null || echo "$CODING_CLI"; }

_install_cli() {
    local spec="$1"
    case "$spec" in
        npm:*)  _ensure_nvm; npm install -g ${spec#npm:} ;;
        uv:*)   _ensure_uv;  uv tool install "${spec#uv:}" ;;
        *)      bash -c "$spec" ;;
    esac
}

# Some CLIs need NVM even before the install check (e.g. claude installer uses npm)
case "$CODING_CLI" in
    claude|opencode|codex|gemini|kilo|cn|pi) _ensure_nvm ;;
    aider) _ensure_uv ;;
esac

_cli_bin_val=$(_cli_bin)
_cli_spec_val=$(_cli_spec)

if ! command -v "$_cli_bin_val" &>/dev/null; then
    if [ -n "$_cli_spec_val" ]; then
        _log "Installing $CODING_CLI..."
        _install_cli "$_cli_spec_val"
        export PATH="$HOME/.local/bin:$PATH"
    else
        _log "[WARN] No install spec found for '$CODING_CLI' in catalog.json — add a 'clis' entry or install manually"
    fi
fi

# Per-CLI post-install hooks (PATH exports, settings wiring, etc.)
case "$CODING_CLI" in
    claude)
        _apply_claude_defaults
        [ "${WIRE_CCSTATUSLINE:-true}" = "true" ] && _wire_ccstatusline
        ;;
    opencode)
        export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
        ;;
    goose)
        export PATH="$HOME/.local/bin:$HOME/.config/goose/bin:$PATH"
        ;;
    zsh|bash|sh|*) ;;
esac

# ---------------------------------------------------------------------------
# Dev tool installs (driven by INSTALL_TOOLS env var)
# ---------------------------------------------------------------------------
# Convention: tool key "foo-bar" maps to installer "_install_foo_bar".
# Add a new tool: add an entry to catalog.json and define _install_<key> here.

_run_all_tool_installs() {
    [ -z "$INSTALL_TOOLS" ] && return 0
    IFS=',' read -ra _tool_list <<< "$INSTALL_TOOLS"
    for _t in "${_tool_list[@]}"; do
        _t="${_t// /}"
        [ -z "$_t" ] && continue
        _has_tool "$_t" || continue
        local _spec
        _spec=$(_merged_catalog "tools" | jq -r --arg k "$_t" '.[] | select(.key == $k) | .install // empty' 2>/dev/null || true)
        if [ -n "$_spec" ]; then
            _install_from_spec "$_t" "$_spec" || _log "[WARN] $_t install failed — restart container to retry"
            continue
        fi
        local _fn="_install_${_t//-/_}"
        if declare -f "$_fn" &>/dev/null; then
            "$_fn" || _log "[WARN] $_t install failed — it will be missing; restart container to retry"
        else
            _log "[WARN] No installer defined for '$_t' — skipping"
        fi
    done
}

_run_all_tool_installs

# ---------------------------------------------------------------------------
# Plugin installs (driven by INSTALL_PLUGINS env var)
# ---------------------------------------------------------------------------

# Convention: plugin key "foo-bar" maps to installer "_install_plugin_foo_bar".
# Add a new plugin: add an entry to catalog.json and define _install_plugin_<key> here.

_do_plugin_installs() {
    [ -z "$INSTALL_PLUGINS" ] && return 0
    IFS=',' read -ra _plugin_list <<< "$INSTALL_PLUGINS"
    for _p in "${_plugin_list[@]}"; do
        _p="${_p// /}"
        [ -z "$_p" ] && continue
        if ! _supports_cli "$_p"; then
            _log "Skipping plugin '$_p' (not supported by CODING_CLI=$CODING_CLI)"
            continue
        fi
        case "$_p" in
            npm:*)  _install_plugin_npm_pkg "${_p#npm:}"; continue ;;
            uv:*)   _install_plugin_uv_pkg  "${_p#uv:}"; continue ;;
            */*)    _install_plugin_github  "$_p"; continue ;;
        esac
        local _spec
        _spec=$(_merged_catalog "plugins" | jq -r --arg k "$_p" '.[] | select(.key == $k) | .install // empty' 2>/dev/null || true)
        if [ -n "$_spec" ]; then
            _install_from_spec "$_p" "$_spec" || _log "[WARN] Plugin '$_p' install failed"
            continue
        fi
        local _fn="_install_plugin_${_p//-/_}"
        if declare -f "$_fn" &>/dev/null; then
            "$_fn" || _log "[WARN] Plugin '$_p' install failed"
        else
            _log "[WARN] Unknown plugin '$_p' — use owner/repo, npm:pkg, uv:pkg, gh:owner/repo, or git:URL for custom entries"
        fi
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
# Shell setup — clone plugins + starship into home volume (idempotent)
# .zshrc itself is baked into the image via Dockerfile.
# ---------------------------------------------------------------------------
_setup_zsh

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    exec /bin/zsh -l
elif [ "$1" = "--daemon" ]; then
    mkdir -p "$HOME/.local/share/codetainyrrr"
    touch "$HOME/.local/share/codetainyrrr/ready"
    _log "Daemon mode — connect with: docker exec -it --user dev codetainyrrr zsh"
    exec sleep infinity
elif [[ "$1" == --* ]] || [[ "$1" == -* ]]; then
    exec "$CODING_CLI" "$@"
else
    exec "$@"
fi

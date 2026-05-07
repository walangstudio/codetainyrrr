#!/usr/bin/env bash
# run.sh — main wrapper for codetainyrrr container
#
# USAGE:
#   ./run.sh                                          # interactive zsh
#   ./run.sh --detach                                 # start in background (daemon mode)
#   ./run.sh connect                                  # attach a new shell to running container
#   ./run.sh stop                                     # stop the running container
#   ./run.sh --dangerously-skip-permissions           # run claude
#   ./run.sh --cli codex                              # run codex (one-off, no default change)
#   ./run.sh --network my_project_default             # attach extra network
#   ./run.sh --build                                  # rebuild image first

set -euo pipefail

# Prevent git bash on Windows from mangling Unix paths in docker volume/env args
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env if present
if [ -f .env ]; then
    set -o allexport
    # shellcheck source=/dev/null
    source .env
    set +o allexport
fi

# Defaults (fallback if not in .env)
HOST_UID="${HOST_UID:-$(id -u 2>/dev/null || echo 1000)}"
HOST_GID="${HOST_GID:-$(id -g 2>/dev/null || echo 1000)}"
# Git Bash on Windows returns a large Windows-mapped UID (e.g. 197609) which is
# not a valid Linux UID. Clamp anything above the 16-bit range to 1000.
[ "${HOST_UID}" -gt 65535 ] 2>/dev/null && HOST_UID=1000
[ "${HOST_GID}" -gt 65535 ] 2>/dev/null && HOST_GID=1000
CODING_CLI="${CODING_CLI:-claude}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)/workspace}"
# CLAUDE_DIR blank → named volume (default). Set it to share with host Claude Desktop.
CLAUDE_DIR="${CLAUDE_DIR:-}"
CLAUDE_JSON="${CLAUDE_JSON:-}"
# Expand ~ if somehow still present (e.g. user typed ~/foo in .env)
CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"
CLAUDE_JSON="${CLAUDE_JSON/#\~/$HOME}"
PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"
IMAGE_NAME="codetainyrrr:local"
NETWORK_NAME="codetainyrrr_default"
CONTAINER_NAME="${CONTAINER_NAME:-codetainyrrr}"
INSTALL_TOOLS="${INSTALL_TOOLS:-}"
INSTALL_PLUGINS="${INSTALL_PLUGINS:-}"
EXTRA_WORKSPACES="${EXTRA_WORKSPACES:-}"

# Bring-your-own configs (host paths → bind-mounted read-only into container)
CCSTATUSLINE_CONFIG="${CCSTATUSLINE_CONFIG:-}"
ZSH_EXTRA_CONFIG="${ZSH_EXTRA_CONFIG:-}"
STARSHIP_CONFIG="${STARSHIP_CONFIG:-}"
CCSTATUSLINE_CONFIG="${CCSTATUSLINE_CONFIG/#\~/$HOME}"
ZSH_EXTRA_CONFIG="${ZSH_EXTRA_CONFIG/#\~/$HOME}"
STARSHIP_CONFIG="${STARSHIP_CONFIG/#\~/$HOME}"

BYO_CONFIG_FLAGS=()
[ -n "$CCSTATUSLINE_CONFIG" ] && BYO_CONFIG_FLAGS+=("--volume" "${CCSTATUSLINE_CONFIG}:/home/dev/.config/ccstatusline/settings.json:ro,z")
[ -n "$ZSH_EXTRA_CONFIG" ]    && BYO_CONFIG_FLAGS+=("--volume" "${ZSH_EXTRA_CONFIG}:/home/dev/.config/zsh/extra.zsh:ro,z")
[ -n "$STARSHIP_CONFIG" ]     && BYO_CONFIG_FLAGS+=("--volume" "${STARSHIP_CONFIG}:/home/dev/.config/starship.toml:ro,z")

USER_CATALOG_FLAGS=()
[ -f "$SCRIPT_DIR/catalog.user.json" ] && USER_CATALOG_FLAGS+=("--volume" "$SCRIPT_DIR/catalog.user.json:/catalog.user.json:ro,z")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# docker ps --filter "name=^X$" is unreliable on Docker Desktop for Windows
# (anchors silently no-op). Always use container inspect for state checks.
_container_status() {
    docker container inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo ""
}
_container_running() { [ "$(_container_status "$1")" = "running" ]; }

# Whitelist for CLI / plugin names written into .env via sed -i.
# Allows alphanumerics, _ - . and / : (for owner/repo, npm:pkg, uv:pkg plugins).
_valid_id() { [[ "$1" =~ ^[a-zA-Z0-9_/:.-]+$ ]]; }

# ---------------------------------------------------------------------------
# Subcommands — handled before .env / flag parsing
# ---------------------------------------------------------------------------
case "${1:-}" in
    help|--help|-h)
        echo "Usage: ./run.sh [subcommand|flags]"
        echo ""
        echo "Subcommands:"
        echo "  (none)                 Start daemon + connect (default)"
        echo "  connect                Attach a new shell to running container"
        echo "  stop                   Stop the running container"
        echo "  restart                Stop and restart, then connect"
        echo "  status                 Show container and volume state"
        echo "  version                Print codetainyrrr version"
        echo "  switch <cli>           Change default CLI in .env, restart if running"
        echo "  plugins list           Show installed plugins"
        echo "  plugins add <name>     Install plugin(s) into running container"
        echo "  plugins remove <name>  Remove plugin sentinel"
        echo ""
        echo "Flags:"
        echo "  --build                Rebuild image before starting"
        echo "  --detach, -d           Start daemon without connecting"
        echo "  --cli <name>           Override CLI for this session"
        echo "  --network <name>       Attach extra Docker network"
        echo "  --dangerously-skip-permissions  Passed to claude"
        echo ""
        echo "CLIs: claude | codex | gemini | opencode | pi | goose | aider | kilo | cn"
        exit 0
        ;;
    version|--version|-V)
        cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown"
        exit 0
        ;;
    build)
        exec "$SCRIPT_DIR/run.sh" --build "${@:2}"
        ;;
    connect)
        if ! _container_running "$CONTAINER_NAME"; then
            echo "[run.sh] Container '$CONTAINER_NAME' is not running. Start it with: ./run.sh"
            exit 1
        fi
        exec docker exec -it --user dev "$CONTAINER_NAME" /bin/zsh -l
        ;;
    restart)
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        exec "$SCRIPT_DIR/run.sh" "${@:2}"
        ;;
    status)
        echo "Container: $CONTAINER_NAME"
        _st=$(docker container inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        echo "  State:  $_st"
        echo "Volume:   ${CONTAINER_NAME}_ct_home"
        docker volume inspect "${CONTAINER_NAME}_ct_home" --format '  Created: {{.CreatedAt}}' 2>/dev/null || echo "  not found"
        exit 0
        ;;
    stop)
        if _container_running "$CONTAINER_NAME"; then
            docker stop "$CONTAINER_NAME" >/dev/null
            echo "[run.sh] Stopped."
        else
            echo "[run.sh] Container '$CONTAINER_NAME' is not running."
        fi
        exit 0
        ;;
    switch)
        _new_cli="${2:-}"
        [ -z "$_new_cli" ] && { echo "Usage: ./run.sh switch <cli>"; exit 1; }
        _valid_id "$_new_cli" || { echo "[run.sh] Invalid CLI name: $_new_cli"; exit 1; }
        if grep -q ^CODING_CLI .env 2>/dev/null; then
            sed -i "s|^CODING_CLI=.*|CODING_CLI=$_new_cli|" .env
        else
            echo "CODING_CLI=$_new_cli" >> .env
        fi
        echo "[run.sh] CODING_CLI=$_new_cli saved to .env"
        if _container_running "$CONTAINER_NAME"; then
            echo "[run.sh] Stopping container..."
            docker stop "$CONTAINER_NAME"
            echo "[run.sh] Restarting with CLI: $_new_cli"
            # note: original flags (--build, --network, etc.) are intentionally not
            # forwarded — switch is "save and restart with the saved CLI", flags
            # passed earlier do not logically apply to the new daemon.
            exec "$SCRIPT_DIR/run.sh"
        else
            echo "[run.sh] Container not running — new CLI takes effect on next start."
        fi
        exit 0
        ;;
    plugins)
        _sub="${2:-list}"
        _arg="${3:-}"
        case "$_sub" in
            list)
                _env_val="$(grep ^INSTALL_PLUGINS .env 2>/dev/null | cut -d= -f2- || echo '')"
                echo "INSTALL_PLUGINS (.env): ${_env_val:-<none>}"
                echo "Installed sentinels:"
                docker exec "$CONTAINER_NAME" ls /home/dev/.local/share/codetainyrrr/plugins/ 2>/dev/null \
                    | sed 's/\.installed$//' \
                    || echo "  (container not running or no plugins installed)"
                ;;
            add)
                [ -z "$_arg" ] && { echo "Usage: ./run.sh plugins add <name>[,name,...]"; exit 1; }
                # Allow comma-separated lists; validate each name.
                IFS=',' read -ra _add_list <<< "$_arg"
                for _n in "${_add_list[@]}"; do
                    _valid_id "$_n" || { echo "[run.sh] Invalid plugin name: $_n"; exit 1; }
                done
                _cur="$(grep ^INSTALL_PLUGINS .env 2>/dev/null | cut -d= -f2- || echo '')"
                _new="$([ -n "$_cur" ] && echo "$_cur,$_arg" || echo "$_arg")"
                if grep -q ^INSTALL_PLUGINS .env 2>/dev/null; then
                    sed -i "s|^INSTALL_PLUGINS=.*|INSTALL_PLUGINS=$_new|" .env
                else
                    echo "INSTALL_PLUGINS=$_new" >> .env
                fi
                echo "[run.sh] INSTALL_PLUGINS=$_new"
                if _container_running "$CONTAINER_NAME"; then
                    docker exec \
                        -e "INSTALL_PLUGINS=$_arg" \
                        -e "CODING_CLI=${CODING_CLI:-claude}" \
                        "$CONTAINER_NAME" /entrypoint.sh --plugins
                else
                    echo "[run.sh] Container not running — plugins install on next start."
                fi
                ;;
            remove)
                [ -z "$_arg" ] && { echo "Usage: ./run.sh plugins remove <name>"; exit 1; }
                _valid_id "$_arg" || { echo "[run.sh] Invalid plugin name: $_arg"; exit 1; }
                _cur="$(grep ^INSTALL_PLUGINS .env 2>/dev/null | cut -d= -f2- || echo '')"
                _new="$(echo "$_cur" | tr ',' '\n' | { grep -vxF "$_arg" || true; } | paste -sd, -)"
                sed -i "s|^INSTALL_PLUGINS=.*|INSTALL_PLUGINS=$_new|" .env
                echo "[run.sh] Removed '$_arg'. INSTALL_PLUGINS=${_new:-<none>}"
                _sentinel="/home/dev/.local/share/codetainyrrr/plugins/${_arg}.installed"
                if _container_running "$CONTAINER_NAME"; then
                    docker exec "$CONTAINER_NAME" rm -f "$_sentinel" 2>/dev/null && echo "[run.sh] Sentinel removed."
                else
                    echo "[run.sh] Container not running — sentinel will be absent on next start."
                fi
                ;;
            *)
                echo "Usage: ./run.sh plugins [list|add <names>|remove <name>]"
                exit 1
                ;;
        esac
        exit 0
        ;;
esac

# Parse flags
EXTRA_NETWORK_FLAGS=()
CONTAINER_ARGS=()
DO_BUILD=false
DETACH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --network)
            EXTRA_NETWORK_FLAGS+=("--network" "$2")
            shift 2
            ;;
        --network=*)
            EXTRA_NETWORK_FLAGS+=("--network" "${1#*=}")
            shift
            ;;
        --cli)
            CODING_CLI="$2"
            shift 2
            ;;
        --cli=*)
            CODING_CLI="${1#*=}"
            shift
            ;;
        --build)
            DO_BUILD=true
            shift
            ;;
        --detach|-d)
            DETACH=true
            shift
            ;;
        *)
            CONTAINER_ARGS+=("$1")
            shift
            ;;
    esac
done

# Derive system-level build args from INSTALL_TOOLS
INSTALL_CPP=false
INSTALL_PHP=false
INSTALL_RUBY=false
[[ ",$INSTALL_TOOLS," == *",cpp,"*  ]] && INSTALL_CPP=true
[[ ",$INSTALL_TOOLS," == *",php,"*  ]] && INSTALL_PHP=true
[[ ",$INSTALL_TOOLS," == *",ruby,"* ]] && INSTALL_RUBY=true

_docker_build() {
    # pwd -W gives the Windows-native path (G:/...) that Docker understands.
    # Needed because MSYS_NO_PATHCONV=1 blocks automatic conversion of /g/... paths.
    local ctx
    ctx="$(cd "$SCRIPT_DIR" && pwd -W 2>/dev/null || echo "$SCRIPT_DIR")"
    docker build \
        --build-arg HOST_UID="$HOST_UID" \
        --build-arg HOST_GID="$HOST_GID" \
        --build-arg USERNAME="dev" \
        --build-arg INSTALL_CPP="$INSTALL_CPP" \
        --build-arg INSTALL_PHP="$INSTALL_PHP" \
        --build-arg INSTALL_RUBY="$INSTALL_RUBY" \
        -t "$IMAGE_NAME" \
        "$ctx"
}

# Rebuild image if requested
if [ "$DO_BUILD" = true ]; then
    echo "[run.sh] Building codetainyrrr image (UID=${HOST_UID} GID=${HOST_GID})..."
    _docker_build
fi

# Ensure image exists
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "[run.sh] Image not found. Building..."
    _docker_build
fi

# Ensure codetainyrrr_default network exists
if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    docker network create "$NETWORK_NAME"
fi

# .claude volume strategy:
# Named volume (ct_home) always owns ~/.claude — settings.json, hooks, CLAUDE.md stay container-local.
# When CLAUDE_DIR is set, only projects/ and todos/ are bind-mounted (memory sync with Claude Desktop).
# This prevents the host's hooks and permissions from leaking into the container.
CLAUDE_VOLUME_FLAGS=()
if [ -n "$CLAUDE_DIR" ]; then
    touch "$CLAUDE_JSON" 2>/dev/null || true
    mkdir -p "$CLAUDE_DIR/projects" "$CLAUDE_DIR/todos" 2>/dev/null || true
    CLAUDE_VOLUME_FLAGS=(
        "--volume" "${CLAUDE_DIR}/projects:/home/dev/.claude/projects:z"
        "--volume" "${CLAUDE_DIR}/todos:/home/dev/.claude/todos:z"
        "--volume" "${CLAUDE_JSON}:/home/dev/.claude.json:z"
    )
fi

# Ensure project workspace dir exists
mkdir -p "$PROJECT_DIR" 2>/dev/null || true

# Primary project mounts at /workspace/<dirname> so all projects sit side by side
PROJECT_DIRNAME="$(basename "$PROJECT_DIR")"

echo "[run.sh] CLI: $CODING_CLI | Project: $PROJECT_DIR → /workspace/$PROJECT_DIRNAME"
if [ ${#EXTRA_NETWORK_FLAGS[@]} -gt 0 ]; then
    echo "[run.sh] Extra networks: ${EXTRA_NETWORK_FLAGS[*]}"
fi

# Build extra workspace volume flags from EXTRA_WORKSPACES (semicolon-separated paths)
EXTRA_WORKSPACE_FLAGS=()
if [ -n "$EXTRA_WORKSPACES" ]; then
    IFS=';' read -ra _ws_list <<< "$EXTRA_WORKSPACES"
    for _ws in "${_ws_list[@]}"; do
        _ws="${_ws/#\~/$HOME}"
        _ws_name="$(basename "$_ws")"
        mkdir -p "$_ws" 2>/dev/null || true
        EXTRA_WORKSPACE_FLAGS+=("--volume" "${_ws}:/workspace/${_ws_name}:z")
        echo "[run.sh] Extra workspace: ${_ws} → /workspace/${_ws_name}"
    done
fi

# Default (no args): start daemon + auto-connect
AUTO_CONNECT=false
if [ "$DETACH" = false ] && [ ${#CONTAINER_ARGS[@]} -eq 0 ]; then
    DETACH=true
    AUTO_CONNECT=true
fi

if [ "$DETACH" = true ]; then
    RUN_MODE_FLAGS=(--detach)
    RUN_CONTAINER_NAME="$CONTAINER_NAME"
    CONTAINER_ARGS=(--daemon)

    # Idempotent: check existing container state before trying to docker run
    _ct_status=$(docker container inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "")
    if [ "$_ct_status" = "running" ]; then
        if [ "$AUTO_CONNECT" = true ]; then
            exec docker exec -it --user dev "$CONTAINER_NAME" /bin/zsh -l
        else
            echo "[run.sh] Container already running. Connect with: ./run.sh connect"
            exit 0
        fi
    elif [ -n "$_ct_status" ]; then
        # Stopped — remove and recreate so any .env changes (PROJECT_DIR, etc.) take effect.
        # The ct_home named volume persists all tools and data; only the container shell is recreated.
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    [ "$AUTO_CONNECT" = false ] && echo "[run.sh] Starting daemon. Connect with: ./run.sh connect"
else
    RUN_MODE_FLAGS=(--rm -it)
    RUN_CONTAINER_NAME="${CONTAINER_NAME}-$(date +%s)"
fi

DOCKER_RUN_ARGS=(
    "${RUN_MODE_FLAGS[@]}"
    --name "$RUN_CONTAINER_NAME"
    --hostname "codetainyrrr"
    --cap-drop ALL
    --cap-add CHOWN
    --cap-add SETUID
    --cap-add SETGID
    --security-opt no-new-privileges:true
    --volume "${PROJECT_DIR}:/workspace/${PROJECT_DIRNAME}:z"
    --volume "${CONTAINER_NAME}_ct_home:/home/dev"
    ${CLAUDE_VOLUME_FLAGS[@]+"${CLAUDE_VOLUME_FLAGS[@]}"}
    ${EXTRA_WORKSPACE_FLAGS[@]+"${EXTRA_WORKSPACE_FLAGS[@]}"}
    ${BYO_CONFIG_FLAGS[@]+"${BYO_CONFIG_FLAGS[@]}"}
    ${USER_CATALOG_FLAGS[@]+"${USER_CATALOG_FLAGS[@]}"}
    --env "HOST_UID=${HOST_UID}"
    --env "HOST_GID=${HOST_GID}"
    --env "CODING_CLI=${CODING_CLI}"
    --env "INSTALL_TOOLS=${INSTALL_TOOLS}"
    --env "INSTALL_PLUGINS=${INSTALL_PLUGINS}"
    --env "HOME=/home/dev"
    --env "USER=dev"
    --env "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
    --env "OPENAI_API_KEY=${OPENAI_API_KEY:-}"
    --env "OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}"
    --env "GEMINI_API_KEY=${GEMINI_API_KEY:-}"
    --env "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-}"
    --env "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-}"
    --env "GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME:-}"
    --env "GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL:-}"
    --env "HTTP_PROXY=${HTTP_PROXY:-}"
    --env "HTTPS_PROXY=${HTTPS_PROXY:-}"
    --env "NO_PROXY=${NO_PROXY:-}"
    --network "$NETWORK_NAME"
    ${EXTRA_NETWORK_FLAGS[@]+"${EXTRA_NETWORK_FLAGS[@]}"}
    --workdir "/workspace"
    "$IMAGE_NAME"
    ${CONTAINER_ARGS[@]+"${CONTAINER_ARGS[@]}"}
)

_wait_for_ready() {
    local sentinel="/home/dev/.local/share/codetainyrrr/ready"
    local i=0
    printf "[run.sh] Waiting for setup to complete"
    until docker exec "$CONTAINER_NAME" test -f "$sentinel" 2>/dev/null; do
        sleep 2
        printf "."
        i=$((i + 1))
        # Give up after 10 minutes — user can connect manually
        [ $i -ge 300 ] && { echo " timed out. Connect manually with: ./run.sh connect"; return 1; }
    done
    echo " done."
}

if [ "$AUTO_CONNECT" = true ]; then
    docker run "${DOCKER_RUN_ARGS[@]}"
    _wait_for_ready
    exec docker exec -it --user dev "$CONTAINER_NAME" /bin/zsh -l
else
    exec docker run "${DOCKER_RUN_ARGS[@]}"
fi

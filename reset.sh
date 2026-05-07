#!/usr/bin/env bash
# reset.sh — wipe codetainyrrr Docker volumes and start fresh
#
# USAGE:
#   ./reset.sh              # full reset — all volumes (tool installs, config, plugins, claude data)
#   ./reset.sh --plugins    # plugins/MCP only — wipes ~/.config volume (keeps tools and claude data)
#
# Your SOURCE CODE and PROJECT FILES are NOT touched — they live on your
# host machine as bind mounts and are never part of these volumes.

set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'
warn()  { echo -e "  ${YELLOW}${BOLD}⚠${NC}  $*"; }
err()   { echo -e "  ${RED}${BOLD}✗${NC}  $*"; }
info()  { echo -e "  ${CYAN}▸${NC} $*"; }
dim()   { echo -e "  ${DIM}$*${NC}"; }
banner(){ echo -e "${BOLD}${RED}$*${NC}"; }

# ── parse flags ───────────────────────────────────────────────────────────────
PLUGINS_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plugins) PLUGINS_ONLY=true; shift ;;
        *) shift ;;
    esac
done

# ── auto-detect project names from volumes ───────────────────────────────────
mapfile -t DETECTED_NAMES < <(docker volume ls -q 2>/dev/null | grep "_ct_home" | grep -v "_test_ct_home" | sed 's/_ct_home.*$//' | sort -u)

if [ ${#DETECTED_NAMES[@]} -eq 0 ]; then
    echo "No codetainyrrr volumes found. Nothing to reset."
    exit 0
fi

# If multiple projects found, list them and let user pick
if [ ${#DETECTED_NAMES[@]} -gt 1 ]; then
    echo
    echo -e "${BOLD}Multiple codetainyrrr installations found:${NC}"
    i=1
    for name in "${DETECTED_NAMES[@]}"; do
        echo -e "  ${BOLD}$i)${NC} ${CYAN}${name}${NC}"
        ((i++))
    done
    echo
    printf "  Which installation to reset? [1]: "
    read -r choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DETECTED_NAMES[@]} )); then
        PROJECT_NAME="${DETECTED_NAMES[$((choice-1))]}"
    else
        err "Invalid choice."; exit 1
    fi
else
    PROJECT_NAME="${DETECTED_NAMES[0]}"
fi

# ── gather volumes to delete / IMAGE_NAME for plugins mode ───────────────────
IMAGE_NAME="codetainyrrr:local"

if [ "$PLUGINS_ONLY" = true ]; then
    if ! docker volume inspect "${PROJECT_NAME}_ct_home" &>/dev/null; then
        echo "No volume '${PROJECT_NAME}_ct_home' to clean. Nothing to reset."
        exit 0
    fi
    TARGET_VOLS=()
    RESET_LABEL="plugins only"
    RESET_DETAIL="plugin sentinels cleared — tools and Claude data untouched"
else
    mapfile -t TARGET_VOLS < <(docker volume ls -q | grep "^${PROJECT_NAME}_ct_home" | grep -v "^${PROJECT_NAME}_test_ct_home" || true)
    RESET_LABEL="full"
    RESET_DETAIL="home volume deleted — all tools, plugins, and data will be re-downloaded"
fi

if [ "$PLUGINS_ONLY" = false ] && [ ${#TARGET_VOLS[@]} -eq 0 ]; then
    echo "No matching volume found for '${PROJECT_NAME}'. Nothing to reset."
    exit 0
fi

# ── show what will happen ─────────────────────────────────────────────────────
clear
echo
echo -e "${BOLD}${RED}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║          ⚠   WARNING — PERMANENT DATA LOSS   ⚠              ║"
echo "  ║                THIS CANNOT BE UNDONE                        ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Reset type:${NC} ${YELLOW}${RESET_LABEL}${NC}"
echo -e "  ${BOLD}Project:${NC}    ${CYAN}${PROJECT_NAME}${NC}"
echo
if [ "$PLUGINS_ONLY" = false ]; then
    warn "The following volume will be PERMANENTLY DELETED:"
    for v in "${TARGET_VOLS[@]}"; do
        dim "  docker volume rm $v"
    done
    echo
    echo -e "  ${BOLD}This will erase:${NC}"
    warn "All installed tool versions (Node, Python, Go, Rust, Java, etc.)"
    warn "All installed plugins, MCP servers, and their configurations"
    warn "Claude memories, slash commands, and settings (if using named volume)"
    warn "Shell history, zsh config, starship prompt, ccstatusline config"
    warn "Any data stored inside the container home directory"
    echo
    echo -e "  ${BOLD}${CYAN}This will NOT affect:${NC}"
    info "Your source code and project files (bind-mounted from host)"
    info "Your host ~/.claude directory (if you set CLAUDE_DIR in .env)"
    info "Your .env configuration file"
else
    info "Plugin sentinels will be cleared from ${PROJECT_NAME}_ct_home"
    echo
    echo -e "  ${BOLD}This will:${NC}"
    warn "Remove all plugin install sentinels — plugins re-install on next start"
    echo
    echo -e "  ${BOLD}${CYAN}This will NOT affect:${NC}"
    info "Installed tool versions (Node, Python, Go, Rust, etc.)"
    info "Claude memories and settings"
    info "Your source code and project files"
fi

echo
echo -e "  ${DIM}Container '${PROJECT_NAME}' will be stopped if running.${NC}"
echo

# ── first confirmation ────────────────────────────────────────────────────────
echo -e "${YELLOW}${BOLD}  Are you sure you want to proceed?${NC}  ${DIM}[y/N]${NC}"
printf "  > "
read -r first_confirm
first_confirm="${first_confirm:-n}"
first_confirm="$(echo "$first_confirm" | tr '[:upper:]' '[:lower:]')"
if [[ "$first_confirm" != y* ]]; then
    echo; echo "  Aborted. Nothing was changed."; exit 0
fi

# ── second confirmation (type RESET) ─────────────────────────────────────────
echo
echo -e "${RED}${BOLD}  This is your final warning.${NC}"
if [ "$PLUGINS_ONLY" = false ]; then
    echo -e "  Type ${BOLD}RESET${NC} to permanently delete the home volume, or anything else to abort:"
else
    echo -e "  Type ${BOLD}RESET${NC} to clear plugin sentinels, or anything else to abort:"
fi
printf "  > "
read -r final_confirm
if [ "$final_confirm" != "RESET" ]; then
    echo; echo "  Aborted. Nothing was changed."; exit 0
fi

# ── stop container ────────────────────────────────────────────────────────────
echo
info "Stopping container '${PROJECT_NAME}' if running..."
docker stop "$PROJECT_NAME" 2>/dev/null || true
docker rm   "$PROJECT_NAME" 2>/dev/null || true
info "Container stopped and removed (or was not running)."

# ── plugins-only mode: clear sentinels via temp container ────────────────────
if [ "$PLUGINS_ONLY" = true ]; then
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        err "Image '$IMAGE_NAME' not found. Build it first with: ./run.sh --build"
        exit 1
    fi
    info "Clearing plugin sentinels..."
    docker run --rm \
        --volume "${PROJECT_NAME}_ct_home:/home/dev" \
        --user root \
        --entrypoint /bin/sh \
        "$IMAGE_NAME" \
        -c "rm -rf /home/dev/.local/share/codetainyrrr/plugins/"
    echo
    echo -e "  ${BOLD}${CYAN}Plugin reset complete.${NC}"
    dim "Plugins will re-install on next start."
    dim "Run ./run.sh to start."
    echo
    exit 0
fi

# ── delete home volume ────────────────────────────────────────────────────────
info "Deleting ${#TARGET_VOLS[@]} volume(s)..."
failed=0
for v in "${TARGET_VOLS[@]}"; do
    if docker volume rm "$v" 2>/dev/null; then
        echo -e "    ${DIM}removed: $v${NC}"
    else
        err "Failed to remove: $v  (still in use?)"
        ((failed++)) || true
    fi
done

echo
if [ "$failed" -eq 0 ]; then
    echo -e "  ${BOLD}${CYAN}Reset complete.${NC}"
    dim "All tool installs will be re-downloaded on next start."
    dim "Run ./run.sh to start fresh."
else
    err "$failed volume(s) could not be removed. Try: docker stop ${PROJECT_NAME} && ./reset.sh"
    exit 1
fi
echo

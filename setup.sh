#!/usr/bin/env bash
# setup.sh — interactive onboarding for codetainyrrr
# Walks through every option and writes .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# catalog.json is required — it drives both the wizard menus and the entrypoint dispatch.
if ! command -v jq &>/dev/null; then
    echo "setup.sh requires 'jq'. Install it and retry."
    echo "  macOS:          brew install jq"
    echo "  Debian/Ubuntu:  sudo apt-get install jq"
    echo "  Windows (scoop): scoop install jq"
    exit 1
fi
CATALOG="$SCRIPT_DIR/catalog.json"
[ -f "$CATALOG" ] || { echo "catalog.json not found in $SCRIPT_DIR"; exit 1; }
USER_CATALOG="$SCRIPT_DIR/catalog.user.json"
WIZARD="$SCRIPT_DIR/wizard.json"
[ -f "$WIZARD" ] || { echo "wizard.json not found in $SCRIPT_DIR"; exit 1; }

# Emit the merged tools/plugins array, with user entries overriding built-ins on same key.
_catalog_tools() {
    if [ -f "$USER_CATALOG" ]; then
        jq -s '
            (.[0].tools // []) as $base | (.[1].tools // []) as $user |
            ($user | map(.key)) as $ukeys |
            [$base[] | select(.key as $k | ($ukeys | index($k)) == null)] + $user
        ' "$CATALOG" "$USER_CATALOG"
    else
        jq '.tools' "$CATALOG"
    fi
}

_catalog_plugins() {
    if [ -f "$USER_CATALOG" ]; then
        jq -s '
            (.[0].plugins // []) as $base | (.[1].plugins // []) as $user |
            ($user | map(.key)) as $ukeys |
            [$base[] | select(.key as $k | ($ukeys | index($k)) == null)] + $user
        ' "$CATALOG" "$USER_CATALOG"
    else
        jq '.plugins' "$CATALOG"
    fi
}

_catalog_clis() {
    if [ -f "$USER_CATALOG" ]; then
        jq -s '
            (.[0].clis // []) as $base | (.[1].clis // []) as $user |
            ($user | map(.key)) as $ukeys |
            [$base[] | select(.key as $k | ($ukeys | index($k)) == null)] + $user
        ' "$CATALOG" "$USER_CATALOG"
    else
        jq '.clis // []' "$CATALOG"
    fi
}

# ── colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; DIM='\033[2m'; RED='\033[0;31m'; NC='\033[0m'

h()    { echo; echo -e "${BOLD}${CYAN}── $* ${NC}"; }
dim()  { echo -e "  ${DIM}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }

# ── helpers ───────────────────────────────────────────────────────────────────

GO_BACK=0

# Normalize path: convert backslashes to forward slashes for Docker
normalize_path() {
    echo "$1" | sed 's|\\|/|g'
}

# ask VAR "Question" "default" [--path]
ask() {
    local __var="$1" question="$2" default="${3:-}" is_path=0
    [ "${4:-}" = "--path" ] && is_path=1
    echo -e "${YELLOW}$question${NC}"
    [ -n "$default" ] && echo -e "  ${DIM}default: $default${NC}"
    printf "  > "
    local input; read -r input
    if [ "$input" = "back" ] || [ "$input" = "b" ] || [ "$input" = '\' ]; then
        GO_BACK=1
        return
    fi
    local result="${input:-$default}"
    [ $is_path -eq 1 ] && result="$(normalize_path "$result")"
    printf -v "$__var" '%s' "$result"
}

# ask_secret VAR "Question" [current_value]
# If input is blank and current_value is set, keeps current_value unchanged.
ask_secret() {
    local __var="$1" question="$2" current="${3:-}"
    echo -e "${YELLOW}$question${NC}"
    [ -n "$current" ] && echo -e "  ${DIM}(leave blank to keep existing value)${NC}"
    printf "  > "
    local input; read -rs input; echo
    if [ "$input" = "back" ] || [ "$input" = "b" ] || [ "$input" = '\' ]; then
        GO_BACK=1
        return
    fi
    local result="${input:-$current}"
    printf -v "$__var" '%s' "$result"
}

# yn VAR "Question" y|n
yn() {
    local __var="$1" question="$2" default="${3:-n}"
    local hint; [ "$default" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    echo -e "${YELLOW}$question ${DIM}$hint${NC}"
    printf "  > "
    local input; read -r input
    if [ "$input" = "back" ] || [ "$input" = "b" ]; then
        GO_BACK=1
        return
    fi
    input="${input:-$default}"
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
        echo -e "  ${BOLD}$i)${NC} ${GREEN}$1${NC} - $2"
        keys+=("$1"); shift 2; ((i++))
    done
    while :; do
        printf "  > "
        local input; read -r input
        if [ "$input" = "back" ] || [ "$input" = "b" ] || [ "$input" = '\' ]; then
            GO_BACK=1
            return
        fi
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            local idx=$(( input - 1 ))
            if [ $idx -ge 0 ] && [ $idx -lt ${#keys[@]} ]; then
                printf -v "$__var" '%s' "${keys[$idx]}"
                return
            fi
        elif [ -z "$input" ]; then
            printf -v "$__var" '%s' "${keys[0]}"
            return
        fi
        dim "  Invalid. Enter a number 1-${#keys[@]}, or 'back'."
    done
}

# tui_single_select VAR "Question" "key|display_text" ...
# Arrow-key dropdown; falls back to typed-number menu when no TTY or WIZARD_NO_TUI=1.
# Pre-selects the item matching the current value of VAR.
tui_single_select() {
    local __var="$1" question="$2"; shift 2
    local -a keys=() descs=()
    while [ $# -gt 0 ]; do
        local item="$1"; shift
        keys+=("${item%%|*}")
        descs+=("${item#*|}")
    done
    local n=${#keys[@]}
    local cursor=0 existing="${!__var:-}"
    for ((i=0; i<n; i++)); do
        [ "${keys[i]}" = "$existing" ] && { cursor=$i; break; }
    done

    if [ "${WIZARD_NO_TUI:-0}" = "1" ] || [ ! -t 0 ] || [ ! -t 1 ] || [ "${BASH_VERSINFO[0]:-3}" -lt 4 ]; then
        local -a menu_args=()
        for ((i=0; i<n; i++)); do menu_args+=("${keys[i]}" "${descs[i]}"); done
        menu "$__var" "$question" "${menu_args[@]}"
        return
    fi

    _tui_single_render() {
        printf '%b\n' "  ${YELLOW}$question${NC}"
        printf '%b\n' "  ${DIM}↑/↓ navigate · ←/ESC back · →/ENTER forward${NC}"
        echo
        for ((i=0; i<n; i++)); do
            if [ "$i" -eq "$cursor" ]; then
                printf '  %b▸ %-16b%b  %s%b\n' "${BOLD}${CYAN}" "${keys[i]}${NC}" "${NC}" "${descs[i]}" "${NC}"
            else
                printf '  %b  %-16s%b  %s%b\n' "${DIM}" "${keys[i]}" "${NC}" "${descs[i]}" "${NC}"
            fi
        done
    }
    local total_lines=$((n + 3))
    printf '\033[?25l'
    trap 'printf "\033[?25h"' EXIT INT TERM
    _tui_single_render

    while :; do
        local key rest=""
        IFS= read -rsn1 key
        if [ "$key" = $'\x1b' ]; then
            read -rsn2 -t 0.05 rest 2>/dev/null || true
            key="$key$rest"
        fi
        case "$key" in
            $'\x1b[A') (( cursor > 0 ))    && cursor=$((cursor - 1)) ;;
            $'\x1b[B') (( cursor < n-1 ))  && cursor=$((cursor + 1)) ;;
            $'\x1b[D') GO_BACK=1; break ;;
            $'\x1b[C') break ;;
            $'\x1b')   GO_BACK=1; break ;;
            "")        break ;;
        esac
        printf '\033[%dA\033[J' "$total_lines"
        _tui_single_render
    done

    printf '\033[?25h'
    trap - EXIT INT TERM
    echo
    [ "$GO_BACK" -eq 1 ] && return
    printf -v "$__var" '%s' "${keys[$cursor]}"
}

# tui_multiselect VAR_NAME "Title" "key|default|description" ...
# default: 1 = pre-ticked, 0 = unchecked
# Use "---Label" as key (no pipes needed) for a non-selectable category header.
# If VAR_NAME has a value (from .env), it overrides defaults.
# Uses ANSI raw-key TUI when stdin is a TTY; falls back to typed numbers otherwise.
tui_multiselect() {
    local __var="$1" title="$2"; shift 2
    local -a keys=() descs=() picked=() types=()
    while [ $# -gt 0 ]; do
        local item="$1"; shift
        local key="${item%%|*}"
        if [[ "$key" == ---* ]]; then
            keys+=("$key"); descs+=("${key#---}"); picked+=(0); types+=("header")
        else
            local rest="${item#*|}"
            local dflt="${rest%%|*}"
            local desc="${rest#*|}"
            keys+=("$key"); descs+=("$desc"); picked+=("$dflt"); types+=("item")
        fi
    done
    local existing="${!__var:-}"
    local i n=${#keys[@]}
    if [ -n "$existing" ]; then
        for ((i=0; i<n; i++)); do
            [ "${types[i]}" = "header" ] && continue
            if [[ ",$existing," == *",${keys[i]},"* ]]; then picked[i]=1; else picked[i]=0; fi
        done
    fi

    if [ "${WIZARD_NO_TUI:-0}" = "1" ] || [ ! -t 0 ] || [ ! -t 1 ] || [ "${BASH_VERSINFO[0]:-3}" -lt 4 ]; then
        _typed_multiselect_render "$title" keys descs picked types
        [ "$GO_BACK" -eq 1 ] && return
        local -a _chosen=()
        for ((i=0; i<n; i++)); do
            [ "${types[i]}" = "item" ] && [ "${picked[i]}" = "1" ] && _chosen+=("${keys[i]}")
        done
        local IFS=','; printf -v "$__var" '%s' "${_chosen[*]}"
        return 0
    fi

    local cursor=0
    while (( cursor < n )) && [ "${types[cursor]}" = "header" ]; do cursor=$((cursor + 1)); done

    printf '\033[?25l'
    trap 'printf "\033[?25h"' EXIT INT TERM

    _tui_render() {
        printf '%b\n' "  ${BOLD}${CYAN}$title${NC}"
        printf '%b\n' "  ${DIM}↑/↓ · SPACE toggle · A=all · N=none · ←/ESC back · →/ENTER fwd${NC}"
        echo
        for ((i=0; i<n; i++)); do
            if [ "${types[i]}" = "header" ]; then
                printf '  %b── %s ──────────────────────────%b\n' "${DIM}" "${descs[i]}" "${NC}"
                continue
            fi
            local mark="${DIM}[ ]${NC}"
            [ "${picked[i]}" = "1" ] && mark="[${GREEN}x${NC}]"
            local prefix="    " row_name="${keys[i]}" row_desc="${descs[i]}"
            if [ "$i" -eq "$cursor" ]; then
                prefix="  ${CYAN}▸${NC} "
                row_name="${BOLD}${keys[i]}${NC}"
            fi
            printf '%b %b  %-16b %b%s%b\n' \
                "$prefix" "$mark" "$row_name" "${DIM}" "$row_desc" "${NC}"
        done
    }
    _tui_render
    local total_lines=$((n + 3))

    while :; do
        local key rest=""
        IFS= read -rsn1 key
        if [ "$key" = $'\x1b' ]; then
            read -rsn2 -t 0.05 rest 2>/dev/null || true
            key="$key$rest"
        fi
        case "$key" in
            $'\x1b[A')
                (( cursor > 0 )) && cursor=$((cursor - 1))
                while (( cursor > 0 )) && [ "${types[cursor]}" = "header" ]; do cursor=$((cursor - 1)); done
                while [ "${types[cursor]}" = "header" ] && (( cursor < n-1 )); do cursor=$((cursor + 1)); done
                ;;
            $'\x1b[B')
                (( cursor < n-1 )) && cursor=$((cursor + 1))
                while (( cursor < n-1 )) && [ "${types[cursor]}" = "header" ]; do cursor=$((cursor + 1)); done
                while [ "${types[cursor]}" = "header" ] && (( cursor > 0 )); do cursor=$((cursor - 1)); done
                ;;
            " ")     [ "${types[cursor]}" = "item" ] && picked[cursor]=$((1 - ${picked[cursor]})) ;;
            a|A)     for ((i=0; i<n; i++)); do [ "${types[i]}" = "item" ] && picked[i]=1; done ;;
            n|N)     for ((i=0; i<n; i++)); do [ "${types[i]}" = "item" ] && picked[i]=0; done ;;
            $'\x1b[D') GO_BACK=1; break ;;
            $'\x1b[C') break ;;
            $'\x1b')   GO_BACK=1; break ;;
            "")        break ;;
        esac
        printf '\033[%dA\033[J' "$total_lines"
        _tui_render
    done

    printf '\033[?25h'
    trap - EXIT INT TERM
    echo

    [ "$GO_BACK" -eq 1 ] && return

    local -a chosen=()
    for ((i=0; i<n; i++)); do
        [ "${types[i]}" = "item" ] && [ "${picked[i]}" = "1" ] && chosen+=("${keys[i]}")
    done
    local IFS=','; printf -v "$__var" '%s' "${chosen[*]}"
}

# Fallback when no TTY or bash <4: numbered toggle picker.
_typed_multiselect_render() {
    local title="$1"; shift
    local -n _keys=$1 _descs=$2 _picked=$3 _types=$4
    local n=${#_keys[@]} i input
    local -a _numToIdx=()
    for ((i=0; i<n; i++)); do [ "${_types[i]}" = "item" ] && _numToIdx+=($i); done
    local nItems=${#_numToIdx[@]}
    while :; do
        echo -e "  ${BOLD}${CYAN}$title${NC}"
        echo -e "  ${DIM}numbers (e.g. 1,3,5) toggle · 'a' all · 'n' none · Enter = confirm${NC}"
        echo
        local num=1
        for ((i=0; i<n; i++)); do
            if [ "${_types[i]}" = "header" ]; then
                echo -e "  ${DIM}── ${_descs[i]} ──────────────────────────${NC}"
                continue
            fi
            local mark="[ ]"; [ "${_picked[i]}" = "1" ] && mark="[${GREEN}x${NC}]"
            printf '  %b %2d) %-16s %b%s%b\n' \
                "$mark" "$num" "${_keys[i]}" "${DIM}" "${_descs[i]}" "${NC}"
            num=$((num + 1))
        done
        printf "  > "
        read -r input || break
        case "$input" in
            "")     break ;;
            back|b) GO_BACK=1; return ;;
            a|A)    for ((i=0; i<n; i++)); do [ "${_types[i]}" = "item" ] && _picked[i]=1; done ;;
            n|N)    for ((i=0; i<n; i++)); do [ "${_types[i]}" = "item" ] && _picked[i]=0; done ;;
            *)   for tok in $(echo "$input" | tr ',' ' '); do
                    [[ "$tok" =~ ^[0-9]+$ ]] || continue
                    local nidx=$((tok - 1))
                    [ $nidx -ge 0 ] && [ $nidx -lt $nItems ] && {
                        local idx=${_numToIdx[$nidx]}
                        _picked[idx]=$((1 - ${_picked[idx]}))
                    }
                 done ;;
        esac
        echo
    done
}

# _wp pageId key — read a page-level field from wizard.json
_wp() { jq -r --arg p "$1" --arg k "$2" '.pages[] | select(.id==$p) | .[$k] // empty' "$WIZARD" 2>/dev/null || true; }
# _wf pageId fieldId key — read a field-level attribute from wizard.json
_wf() { jq -r --arg p "$1" --arg f "$2" --arg k "$3" '.pages[] | select(.id==$p) | .fields[] | select(.id==$f) | .[$k] // empty' "$WIZARD" 2>/dev/null || true; }

# Load existing .env so re-runs show current values as defaults
_load_existing() {
    [ -f .env ] || return 0
    while IFS='=' read -r key val; do
        # strip UTF-8 BOM from first line
        key="${key#$'\xef\xbb\xbf'}"
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        val="${val%%#*}"          # strip inline comments
        val="${val%"${val##*[! ]}"}"  # trim trailing spaces
        val="${val#\"}" val="${val%\"}"  # strip surrounding double-quotes
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
echo -e "  ${DIM}Enter = accept default   \\  or 'back' = previous step${NC}"
echo

# Load existing values so re-runs are incremental
_load_existing
EXISTING=false
[ -f .env ] && { EXISTING=true; warn "Found existing .env — current values shown as defaults."; }

# Migrate: add rtk to existing installs that predate it being an INSTALL_TOOLS option
_stored_tools="$(_e INSTALL_TOOLS "")"
if [ -n "$_stored_tools" ] && [[ ",$_stored_tools," != *",rtk,"* ]]; then
    _stored_tools="rtk,$_stored_tools"
fi

# Initialise all vars from .env so re-runs are incremental
CODING_CLI="$(_e CODING_CLI claude)"
CONTAINER_NAME="$(_e CONTAINER_NAME codetainyrrr)"
PROJECT_DIR="$(_e PROJECT_DIR "")"
EXTRA_WORKSPACES="$(_e EXTRA_WORKSPACES "")"
CLAUDE_DIR="$(_e CLAUDE_DIR "")"
CLAUDE_JSON="$(_e CLAUDE_JSON "")"
WIRE_CCSTATUSLINE="$(_e WIRE_CCSTATUSLINE true)"
ANTHROPIC_API_KEY="$(_e ANTHROPIC_API_KEY "")"
OPENAI_API_KEY="$(_e OPENAI_API_KEY "")"
OPENROUTER_API_KEY="$(_e OPENROUTER_API_KEY "")"
GEMINI_API_KEY="$(_e GEMINI_API_KEY "")"
GIT_AUTHOR_NAME="$(_e GIT_AUTHOR_NAME "")"
GIT_AUTHOR_EMAIL="$(_e GIT_AUTHOR_EMAIL "")"
INSTALL_TOOLS="$_stored_tools"
INSTALL_PLUGINS="$(_e INSTALL_PLUGINS "")"
CCSTATUSLINE_CONFIG="$(_e CCSTATUSLINE_CONFIG "")"
ZSH_EXTRA_CONFIG="$(_e ZSH_EXTRA_CONFIG "")"
STARSHIP_CONFIG="$(_e STARSHIP_CONFIG "")"

step=1; maxstep=$(jq '.pages | length' "$WIZARD" 2>/dev/null || echo 8)
while [ "$step" -le "$maxstep" ]; do
    GO_BACK=0
    case "$step" in

    1) # ── AI coding CLI ────────────────────────────────────────────────────
        h "Step 1/$maxstep  $(_wp cli title)"
        dim "$(_wp cli description)"
        mapfile -t _cli_args < <(
            _catalog_clis | jq -r '.[] | .key + "|" + .name + " — " + .description'
        )
        tui_single_select CODING_CLI "$(_wf cli CODING_CLI prompt 2>/dev/null || echo 'Pick your AI coding CLI:')" "${_cli_args[@]}"
        [ "$GO_BACK" -eq 1 ] && continue  # step 1: nothing to go back to
        CODING_CLI="${CODING_CLI:-$(_wf cli CODING_CLI default)}"
        CODING_CLI="${CODING_CLI:-claude}"
        ok "CLI: $CODING_CLI"

        ask CONTAINER_NAME "$(_wf cli CONTAINER_NAME prompt)" "$CONTAINER_NAME"
        [ "$GO_BACK" -eq 1 ] && continue
        CONTAINER_NAME="${CONTAINER_NAME:-codetainyrrr}"
        ok "Container: $CONTAINER_NAME"
        ;;

    2) # ── Project directory ───────────────────────────────────────────────
        h "Step 2/$maxstep  $(_wp paths title)"
        dim "$(_wp paths description)"
        dim "$(_wp paths hint)"
        ask PROJECT_DIR "$(_wf paths PROJECT_DIR prompt)" "$PROJECT_DIR" --path
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }
        if [ -z "$PROJECT_DIR" ]; then
            err "PROJECT_DIR is required."; continue
        fi
        PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"
        ok "Project: $PROJECT_DIR"

        yn _extra_ws "Mount additional project folders?" "n"
        [ "$GO_BACK" -eq 1 ] && continue
        if [ "$_extra_ws" = "y" ]; then
            ask EXTRA_WORKSPACES "$(_wf paths EXTRA_WORKSPACES prompt)" "$EXTRA_WORKSPACES" --path
            [ "$GO_BACK" -eq 1 ] && continue
        else
            EXTRA_WORKSPACES=""
        fi
        ;;

    3) # ── Claude settings ─────────────────────────────────────────────────
        h "Step 3/$maxstep  $(_wp claude_settings title)"
        echo -e "  ${BOLD}Share project memories with Claude Desktop?${NC}"
        dim "  $(_wp claude_settings hint)"
        _share_default="$( [ -n "$CLAUDE_DIR" ] && echo y || echo n )"
        yn _share_claude "Share host ~/.claude?" "$_share_default"
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }

        if [ "$_share_claude" = "y" ]; then
            dim "  Both Windows and Unix path formats accepted."
            ask CLAUDE_DIR  "$(_wf claude_settings CLAUDE_DIR prompt)"  "$CLAUDE_DIR" --path
            [ "$GO_BACK" -eq 1 ] && continue
            ask CLAUDE_JSON "$(_wf claude_settings CLAUDE_JSON prompt)" "$CLAUDE_JSON" --path
            [ "$GO_BACK" -eq 1 ] && continue
            CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"
            CLAUDE_JSON="${CLAUDE_JSON/#\~/$HOME}"
            ok "Sharing: $CLAUDE_DIR"
        else
            CLAUDE_DIR=""; CLAUDE_JSON=""
            ok "Isolated: named volume"
        fi

        ;;

    4) # ── API keys ────────────────────────────────────────────────────────
        h "Step 4/$maxstep  $(_wp api_keys title)"
        dim "$(_wp api_keys description)"
        _hint="$(_wf api_keys ANTHROPIC_API_KEY hint)"
        [ -n "$_hint" ] && dim "  $_hint"
        ask_secret ANTHROPIC_API_KEY "$(_wf api_keys ANTHROPIC_API_KEY prompt)" "$ANTHROPIC_API_KEY"
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }
        [ -n "$ANTHROPIC_API_KEY" ] && ok "Anthropic key set" || dim "  Anthropic key: not set"

        yn _extra_keys "Set additional provider keys? (OpenAI, OpenRouter, Gemini)" "n"
        [ "$GO_BACK" -eq 1 ] && continue
        if [ "$_extra_keys" = "y" ]; then
            ask_secret OPENAI_API_KEY     "$(_wf api_keys OPENAI_API_KEY prompt)"     "$OPENAI_API_KEY"
            ask_secret OPENROUTER_API_KEY "$(_wf api_keys OPENROUTER_API_KEY prompt)" "$OPENROUTER_API_KEY"
            ask_secret GEMINI_API_KEY     "$(_wf api_keys GEMINI_API_KEY prompt)"     "$GEMINI_API_KEY"
        fi
        ;;

    5) # ── Git identity ────────────────────────────────────────────────────
        h "Step 5/$maxstep  $(_wp git_identity title)"
        dim "$(_wp git_identity description)"
        ask GIT_AUTHOR_NAME  "$(_wf git_identity GIT_AUTHOR_NAME prompt)"  "$GIT_AUTHOR_NAME"
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }
        ask GIT_AUTHOR_EMAIL "$(_wf git_identity GIT_AUTHOR_EMAIL prompt)" "$GIT_AUTHOR_EMAIL"
        [ "$GO_BACK" -eq 1 ] && continue
        [ -n "$GIT_AUTHOR_NAME" ] && ok "Git: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
        ;;

    6) # ── Dev Tools ───────────────────────────────────────────────────────
        h "Step 6/$maxstep  $(_wp tools title)"
        dim "$(_wp tools description)"
        mapfile -t _tool_args < <(
            _catalog_tools | jq -r --arg cli "$CODING_CLI" '
                [ .[] | select(
                    (.supported_clis // ["*"]) | (index("*") != null or index($cli) != null)
                )] |
                [ group_by(.category)[] |
                    ("---" + .[0].category),
                    (.[] | .key + "|" + (if .default then "1" else "0" end) + "|" + .description)
                ] | .[]
            '
        )
        tui_multiselect INSTALL_TOOLS "Pick dev tools" "${_tool_args[@]}"
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }
        [ -n "$INSTALL_TOOLS" ] && ok "Tools: $INSTALL_TOOLS" || dim "  Tools: none"
        ;;

    7) # ── Plugins ─────────────────────────────────────────────────────────
        h "Step 7/$maxstep  $(_wp plugins title)"
        dim "$(_wp plugins description)"
        if [ "$CODING_CLI" = "claude" ]; then
            # Re-inject wire-ccstatusline so re-runs restore checked state from WIRE_CCSTATUSLINE.
            if [ "$WIRE_CCSTATUSLINE" = "true" ] && [[ ",$INSTALL_PLUGINS," != *",wire-ccstatusline,"* ]]; then
                [ -n "$INSTALL_PLUGINS" ] && INSTALL_PLUGINS="wire-ccstatusline,$INSTALL_PLUGINS" || INSTALL_PLUGINS="wire-ccstatusline"
            fi
            mapfile -t _plugin_args < <(
                _catalog_plugins | jq -r --arg cli "$CODING_CLI" '
                    [ .[] | select(
                        (.supported_clis // ["*"]) | (index("*") != null or index($cli) != null)
                    )] |
                    [ group_by(.category)[] |
                        ("---" + .[0].category),
                        (.[] | .key + "|" + (if .default then "1" else "0" end) + "|" + .description)
                    ] | .[]
                '
            )
            tui_multiselect INSTALL_PLUGINS "Pick plugins (Claude)" "${_plugin_args[@]}"
            if [[ ",$INSTALL_PLUGINS," == *",wire-ccstatusline,"* ]]; then
                WIRE_CCSTATUSLINE=true
                INSTALL_PLUGINS="${INSTALL_PLUGINS//wire-ccstatusline,/}"
                INSTALL_PLUGINS="${INSTALL_PLUGINS//,wire-ccstatusline/}"
                INSTALL_PLUGINS="${INSTALL_PLUGINS//wire-ccstatusline/}"
            else
                WIRE_CCSTATUSLINE=false
            fi
        else
            dim "Plugins are filtered by supported CLI. Add plugins for $CODING_CLI in catalog.user.json."
            mapfile -t _plugin_args < <(
                _catalog_plugins | jq -r --arg cli "$CODING_CLI" '
                    [ .[] | select(
                        (.supported_clis // ["*"]) | (index("*") != null or index($cli) != null)
                    )] |
                    [ group_by(.category)[] |
                        ("---" + .[0].category),
                        (.[] | .key + "|" + (if .default then "1" else "0" end) + "|" + .description)
                    ] | .[]
                '
            )
            tui_multiselect INSTALL_PLUGINS "Pick plugins ($CODING_CLI)" "${_plugin_args[@]}"
            WIRE_CCSTATUSLINE=false
        fi
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }
        dim "Custom plugins: append owner/repo, npm:pkg, or uv:pkg to INSTALL_PLUGINS in .env"
        [ "$WIRE_CCSTATUSLINE" = "true" ] && ok "ccstatusline: wired"
        [ -n "$INSTALL_PLUGINS" ] && ok "Plugins: $INSTALL_PLUGINS" || dim "  Plugins: none"
        ;;

    8) # ── Bring-your-own configs ───────────────────────────────────────────
        h "Step 8/$maxstep  $(_wp custom_configs title)"
        dim "  $(_wp custom_configs description)"
        dim "  $(_wp custom_configs hint)"
        echo
        ask CCSTATUSLINE_CONFIG "$(_wf custom_configs CCSTATUSLINE_CONFIG prompt)" "$CCSTATUSLINE_CONFIG" --path
        [ "$GO_BACK" -eq 1 ] && { step=$((step - 1)); continue; }
        ask ZSH_EXTRA_CONFIG    "$(_wf custom_configs ZSH_EXTRA_CONFIG prompt)"    "$ZSH_EXTRA_CONFIG" --path
        [ "$GO_BACK" -eq 1 ] && continue
        ask STARSHIP_CONFIG      "$(_wf custom_configs STARSHIP_CONFIG prompt)"     "$STARSHIP_CONFIG" --path
        [ "$GO_BACK" -eq 1 ] && continue
        CCSTATUSLINE_CONFIG="${CCSTATUSLINE_CONFIG/#\~/$HOME}"
        ZSH_EXTRA_CONFIG="${ZSH_EXTRA_CONFIG/#\~/$HOME}"
        STARSHIP_CONFIG="${STARSHIP_CONFIG/#\~/$HOME}"
        [ -n "$CCSTATUSLINE_CONFIG" ] && ok "ccstatusline: $CCSTATUSLINE_CONFIG"
        [ -n "$ZSH_EXTRA_CONFIG" ]    && ok "zsh extra:    $ZSH_EXTRA_CONFIG"
        [ -n "$STARSHIP_CONFIG" ]     && ok "starship:     $STARSHIP_CONFIG"
        ;;
    esac

    [ "$GO_BACK" -eq 0 ] && step=$((step + 1))
done

# ── 9. System UID/GID ─────────────────────────────────────────────────────────
HOST_UID="${HOST_UID:-$(id -u 2>/dev/null || echo 1000)}"
HOST_GID="${HOST_GID:-$(id -g 2>/dev/null || echo 1000)}"

# ── 9.5 Build dynamic values for .env ────────────────────────────────────────
_cli_keys=$(jq -r '.clis // [] | .[].key' "$CATALOG" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' | tr ' ' '|' || echo "claude|codex|gemini|opencode|pi|goose|aider|kilo|cn")

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
    [ -z "$v" ] && echo "" || printf '"%s"' "${v//\"/\\\"}"
}

cat > .env << EOF
# codetainyrrr configuration
# Generated by setup.sh — edit manually or re-run setup.sh to update.

HOST_UID=$HOST_UID
HOST_GID=$HOST_GID

# ── AI CLI ──────────────────────────────────────────────────────────────────
# Options: $_cli_keys
CODING_CLI=$CODING_CLI
WIRE_CCSTATUSLINE=$WIRE_CCSTATUSLINE
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
# Options: node,java,go,rust,python,deno,bun,dotnet,cpp,php,ruby,ts,pnpm,yarn,
#          react,react-native,expo,svelte,flutter,rtk,lazygit
INSTALL_TOOLS=$INSTALL_TOOLS

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

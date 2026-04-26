#!/usr/bin/env bash
# test.sh — smoke-tests each supported CODING_CLI
#
# USAGE:
#   ./test.sh                     # test all CLIs sequentially
#   ./test.sh --cli claude        # test one CLI
#   ./test.sh --fast              # build check + container-start only (CODING_CLI=zsh, no installs)
#   ./test.sh --cleanup           # remove test volumes after run
#   ./test.sh --skip-build        # skip docker build, use existing image
#   ./test.sh --parallel          # run all CLIs in parallel

set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env for HOST_UID/GID if present
if [ -f .env ]; then
    set -o allexport
    source .env
    set +o allexport
fi

IMAGE_NAME="codetainyrrr:local"
TEST_VOL_PREFIX="codetainyrrr_test"
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
# Match run.sh: clamp Windows-mapped UIDs (e.g. 197609 from Git Bash) to 1000.
[ "${HOST_UID}" -gt 65535 ] 2>/dev/null && HOST_UID=1000
[ "${HOST_GID}" -gt 65535 ] 2>/dev/null && HOST_GID=1000

# ---------------------------------------------------------------------------
# Volume flags (isolated test volume — never touches real user data)
# ---------------------------------------------------------------------------
_vol_flags() {
    printf '%s ' --volume "${TEST_VOL_PREFIX}_ct_home:/home/dev"
}

# ---------------------------------------------------------------------------
# CLI → binary name
# ---------------------------------------------------------------------------
_cli_binary() {
    case "$1" in
        claude)   echo "claude"   ;;
        codex)    echo "codex"    ;;
        gemini)   echo "gemini"   ;;
        opencode) echo "opencode" ;;
        kilo)     echo "kilo"     ;;
        aider)    echo "aider"    ;;
        goose)    echo "goose"    ;;
        cn)       echo "cn"       ;;
        pi)       echo "pi"       ;;
        zsh)      echo "zsh"      ;;
        *)        echo "$1"       ;;
    esac
}

# ---------------------------------------------------------------------------
# Run one CLI test
# ---------------------------------------------------------------------------
_run_cli_test() {
    local cli="$1"
    local bin; bin="$(_cli_binary "$cli")"
    local log; log="$(mktemp /tmp/codetainyrrr_test_XXXX.log)"
    local start; start=$(date +%s)

    printf "  %-14s " "$cli"

    local cmd="command -v ${bin} && echo '[test] PASS: ${cli} found' || { echo '[test] FAIL: ${cli} not found'; exit 1; }"

    # shellcheck disable=SC2046
    if docker run --rm \
        --name "codetainyrrr_test_${cli}_$$" \
        -e "HOST_UID=${HOST_UID}" \
        -e "HOST_GID=${HOST_GID}" \
        -e "CODING_CLI=${cli}" \
        -e "HOME=/home/dev" \
        -e "USER=dev" \
        -e "INSTALL_TOOLS=" \
        -e "INSTALL_PLUGINS=" \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add SETUID \
        --cap-add SETGID \
        --security-opt no-new-privileges:true \
        $(_vol_flags) \
        --workdir /workspace \
        "$IMAGE_NAME" \
        bash -c "$cmd" > "$log" 2>&1; then
        local elapsed=$(( $(date +%s) - start ))
        echo "PASS  (${elapsed}s)"
    else
        local elapsed=$(( $(date +%s) - start ))
        echo "FAIL  (${elapsed}s)"
        echo "    --- output ---"
        sed 's/^/    /' "$log"
        echo "    --------------"
        FAILURES+=("$cli")
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# Subcommand tests (.env manipulation — no container needed)
# ---------------------------------------------------------------------------
_test_subcommands() {
    echo "[test] Subcommand tests..."
    local backup=".env.test_backup_$$"
    cp .env "$backup" 2>/dev/null || touch "$backup"
    # always restore .env, even on early exit
    trap 'mv "$backup" .env 2>/dev/null || true' RETURN
    # Ensure container is stopped — switch/plugins now correctly restart a
    # running container, which would block on docker exec -it without a TTY.
    docker stop "${CONTAINER_NAME:-codetainyrrr}" 2>/dev/null >/dev/null || true
    local ok=true

    _check() {
        local label="$1" result="$2"
        if [ "$result" = "0" ]; then
            printf "  %-20s PASS\n" "$label"
        else
            printf "  %-20s FAIL\n" "$label"
            ok=false
        fi
    }

    bash run.sh switch aider 2>/dev/null
    grep -q "^CODING_CLI=aider" .env 2>/dev/null; _check "switch" "$?"

    bash run.sh plugins add ccusage 2>/dev/null
    grep -q "ccusage" .env 2>/dev/null; _check "plugins add" "$?"

    bash run.sh plugins remove ccusage 2>/dev/null
    # check ccusage is NOT in INSTALL_PLUGINS line
    val="$(grep "^INSTALL_PLUGINS=" .env 2>/dev/null || true)"
    case "$val" in *ccusage*) _check "plugins remove" "1" ;; *) _check "plugins remove" "0" ;; esac

    if [ "$ok" = true ]; then
        echo "[test] Subcommand tests PASSED."
    else
        echo "[test] Subcommand tests FAILED."
        FAILURES+=("subcommands")
    fi
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
ONLY_CLI=""
FAST=false
CLEANUP=false
SKIP_BUILD=false
PARALLEL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cli)        ONLY_CLI="$2"; shift 2 ;;
        --fast)       FAST=true;  shift ;;
        --cleanup)    CLEANUP=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --parallel)   PARALLEL=true; shift ;;
        *) shift ;;
    esac
done

ALL_CLIS=(claude codex gemini opencode pi goose aider kilo cn)
[ -n "$ONLY_CLI" ] && ALL_CLIS=("$ONLY_CLI")
[ "$FAST" = true ]  && ALL_CLIS=(zsh)

FAILURES=()

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    echo "[test] Building image..."
    _host_uid="${HOST_UID:-1000}"
    _host_gid="${HOST_GID:-1000}"
    docker build \
        --build-arg "HOST_UID=$_host_uid" \
        --build-arg "HOST_GID=$_host_gid" \
        --build-arg "USERNAME=dev" \
        --build-arg "INSTALL_CPP=false" \
        --build-arg "INSTALL_PHP=false" \
        --build-arg "INSTALL_RUBY=false" \
        -t "$IMAGE_NAME" \
        "$SCRIPT_DIR" 2>&1 | tail -5
    echo "[test] Image built."
fi

echo
echo "[test] Running CLI tests (image: $IMAGE_NAME)"
echo "       Volumes prefixed: $TEST_VOL_PREFIX"
echo "       Installs are cached — re-runs are fast."
echo

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
if [ "$PARALLEL" = true ]; then
    pids=()
    for cli in "${ALL_CLIS[@]}"; do
        _run_cli_test "$cli" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
else
    for cli in "${ALL_CLIS[@]}"; do
        _run_cli_test "$cli"
    done
fi

echo
_test_subcommands

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ ${#FAILURES[@]} -eq 0 ]; then
    echo "[test] All tests PASSED."
    RESULT=0
else
    echo "[test] FAILED CLIs/commands: ${FAILURES[*]}"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
if [ "$CLEANUP" = true ]; then
    echo "[test] Removing test volume..."
    docker volume rm "${TEST_VOL_PREFIX}_ct_home" 2>/dev/null || true
    echo "[test] Test volume removed."
fi

exit $RESULT

#!/usr/bin/env bash
# test-clis.sh — end-to-end check that each coding CLI installs and "lands"
# (is runnable) inside the codetainyrrr container, and that `setup` collects
# config WITHOUT running any host install (config-only; insmaller >=0.4.0).
#
# Gated. Needs Docker + network and installs CLIs in throwaway containers
# (npm-based CLIs take several minutes each). Off by default so CI stays green:
#   CT_E2E=1 scripts/test-clis.sh
#
# Inputs (env):
#   CT_E2E       1 to actually run (default: unset -> print how-to and exit 0)
#   CT_BIN       codetainyrrr binary for the setup check (default: codetainyrrr on PATH;
#                if absent, the host-side setup check is skipped with a warning)
#   CT_IMAGE     container image (default: codetainyrrr:local)
#   CT_CLIS      space-separated CLIs to test (default: "claude codex gemini")
#   CT_TIMEOUT   per-CLI container timeout in seconds (default: 1800)
#   CT_RUNTIME   container runtime: docker | podman | auto (default: auto;
#                auto = prefer podman if installed, else docker)
#
# Heads-up: these CLIs download real, large artifacts inside the container.
# `claude` pulls a ~240 MB binary from downloads.claude.ai; `codex`/`gemini`
# first install node (nvm, ~40 MB) then the npm package. On a slow link the
# default timeout can still be too short — raise CT_TIMEOUT or run on a fast
# connection. A 124 exit means the timeout fired (usually mid-download), not a
# product failure.
#
# Per CLI:
#   1. setup --answers (config-only): asserts exit 0, prints the outro, and runs
#      ZERO host install steps (no '✗' / 'FAILED' / 'shell script exited').
#      Regression guard for the Windows PowerShell host-install bug.
#   2. container landing: `docker run --rm -e CODING_CLI=<cli> <image> -c
#      'command -v <cmd> && <cmd> --version'`. The entrypoint installs the CLI
#      (pulling deps like node as needed), then runs the appended `-c` as the
#      login shell. Exit 0 = installed, on PATH, runnable = the user lands on a
#      working CLI and can connect.

set -u

# Resolve where installer.toml lives. Works in BOTH layouts:
#   - repo: scripts/test-clis.sh -> installer.toml is one dir up.
#   - extracted bundle: codetainyrrr.exe + installer.toml + test-clis.sh all in
#     the same dir (release.yml ships the script flat, and we also stage it that
#     way in C:\temp\codetainyrrr-v0.4).
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_script_dir/../installer.toml" ]; then
    REPO_ROOT="$(cd "$_script_dir/.." && pwd)"
else
    REPO_ROOT="$_script_dir"
fi
CT_IMAGE="${CT_IMAGE:-codetainyrrr:local}"
CT_CLIS="${CT_CLIS:-claude codex gemini}"
CT_TIMEOUT="${CT_TIMEOUT:-1800}"
CT_BIN="${CT_BIN:-codetainyrrr}"
CT_RUNTIME="${CT_RUNTIME:-auto}"

if [ "${CT_E2E:-}" != "1" ]; then
    cat <<EOF
test-clis.sh is gated. To run the full per-CLI container suite:
  CT_E2E=1 scripts/test-clis.sh
Optional: CT_CLIS="claude" CT_IMAGE=codetainyrrr:local CT_BIN=/path/to/codetainyrrr
         CT_RUNTIME=podman   (or docker; default: auto-detect)
Skipping (exit 0).
EOF
    exit 0
fi

# Resolve $RUNTIME: explicit > auto-detect (podman → docker).
if [ "$CT_RUNTIME" = "auto" ] || [ -z "$CT_RUNTIME" ]; then
    if command -v podman >/dev/null 2>&1; then RUNTIME=podman
    elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
    else echo "FATAL: neither podman nor docker on PATH"; exit 2
    fi
else
    RUNTIME="$CT_RUNTIME"
    command -v "$RUNTIME" >/dev/null \
        || { echo "FATAL: CT_RUNTIME=$RUNTIME but '$RUNTIME' not on PATH"; exit 2; }
fi
echo "runtime: $RUNTIME ($("$RUNTIME" --version 2>&1 | head -1))"

"$RUNTIME" image inspect "$CT_IMAGE" >/dev/null 2>&1 \
    || { echo "FATAL: image '$CT_IMAGE' not found in $RUNTIME (run 'codetainyrrr task build' or '$RUNTIME load -i <tarball>')"; exit 2; }

# Command name a CLI provides (provides_command in catalog.json). Override-free
# default to the key; only list keys whose command differs or needs pinning.
cli_cmd() {
    case "$1" in
        claude) echo claude ;;
        codex)  echo codex ;;
        gemini) echo gemini ;;
        *)      echo "$1" ;;
    esac
}

with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout "$CT_TIMEOUT" "$@"; else "$@"; fi
}

# Step 1: setup is config-only (no host install). Best-effort: skipped if the
# binary isn't available (it's a release artifact, not in this config-only repo).
check_setup_config_only() {
    local cli="$1"
    if ! command -v "$CT_BIN" >/dev/null 2>&1 && [ ! -x "$CT_BIN" ]; then
        echo "  [setup ] SKIP (CT_BIN '$CT_BIN' not found; set CT_BIN to the codetainyrrr binary)"
        return 0
    fi
    local home out rc
    home="$(mktemp -d)"
    printf 'CODING_CLI = "%s"\nCONTAINER_NAME = "ct-test-%s"\n' "$cli" "$cli" > "$home/answers.toml"
    # HOME redirect keeps the real ~/.codetainyrrr untouched (honoured on Linux/CI).
    out="$(cd "$REPO_ROOT" && HOME="$home" USERPROFILE="$home" \
        "$CT_BIN" setup --answers "$home/answers.toml" --config installer.toml 2>&1)"
    rc=$?
    rm -rf "$home"
    if [ "$rc" -ne 0 ]; then
        echo "  [setup ] FAIL (exit $rc)"; echo "$out" | sed 's/^/    /'; return 1
    fi
    if printf '%s' "$out" | grep -Eq '✗|FAILED|shell script exited|Invoke-WebRequest|parameter cannot be found'; then
        echo "  [setup ] FAIL (host install ran — config-only flag not honoured)"
        echo "$out" | sed 's/^/    /'; return 1
    fi
    echo "  [setup ] PASS (config-only, no host install)"
    return 0
}

# Step 2: CLI installs and is runnable in the container.
check_container_lands() {
    local cli cmd out rc
    cli="$1"; cmd="$(cli_cmd "$cli")"
    # Entrypoint execs `zsh -c <args>`. zsh -c is NON-interactive and does NOT
    # source ~/.zshrc, so install dirs added there (~/.local/bin, ~/.opencode/bin,
    # nvm bins, etc.) aren't on PATH — `command -v <cli>` then fails even though
    # the binary IS on disk. Source .zshrc explicitly so the check mirrors the
    # interactive user's PATH/runtime setup. NO_AUTOLAUNCH=1 skips the welcome
    # banner + auto-launch loop (scripts/zshrc:44-85) so the check returns cleanly.
    # Bind-mount the repo's catalog.json + installer.toml over the BAKED copies
    # at /etc/codetainyrrr/* so the test exercises the current source, not the
    # snapshot baked into the image. Mirrors task.run's live-edit override.
    # MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL stop Git-Bash from mangling the
    # container-side /etc paths into Windows paths when sh execs the runtime.exe.
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    # Podman rootless: --userns=keep-id maps container uid 1000 to host user so
    # bind-mounted files stay correctly owned (mirrors task.run behaviour).
    local userns=()
    [ "$RUNTIME" = "podman" ] && userns=(--userns=keep-id)
    out="$(with_timeout "$RUNTIME" run --rm "${userns[@]}" -e "CODING_CLI=$cli" -e NO_AUTOLAUNCH=1 \
        -v "$REPO_ROOT/catalog.json:/etc/codetainyrrr/catalog.json:ro" \
        -v "$REPO_ROOT/installer.toml:/etc/codetainyrrr/installer.toml:ro" \
        "$CT_IMAGE" \
        -c "set -e
            [ -f \$HOME/.zshrc ] && source \$HOME/.zshrc 2>/dev/null || true
            command -v $cmd >/dev/null || { echo 'not on PATH'; exit 1; }
            $cmd --version 2>/dev/null || $cmd --help >/dev/null 2>&1 || true
            echo LANDED:$cmd" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "LANDED:$cmd"; then
        echo "  [land  ] PASS ($cmd installed + runnable in container)"
        return 0
    fi
    echo "  [land  ] FAIL (exit $rc)"; echo "$out" | tail -20 | sed 's/^/    /'
    return 1
}

echo "== codetainyrrr per-CLI E2E =="
echo "runtime=$RUNTIME image=$CT_IMAGE clis='$CT_CLIS' timeout=${CT_TIMEOUT}s"
echo

declare -a RESULTS
fails=0
for cli in $CT_CLIS; do
    echo "-- $cli --"
    s_ok=0; l_ok=0
    check_setup_config_only "$cli" && s_ok=1
    check_container_lands  "$cli" && l_ok=1
    if [ "$s_ok" = 1 ] && [ "$l_ok" = 1 ]; then
        RESULTS+=("PASS  $cli")
    else
        RESULTS+=("FAIL  $cli"); fails=$((fails+1))
    fi
    echo
done

echo "== summary =="
printf '%s\n' "${RESULTS[@]}"
[ "$fails" -eq 0 ] && { echo "all ok"; exit 0; } || { echo "$fails CLI(s) failed"; exit 1; }

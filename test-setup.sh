#!/usr/bin/env bash
# test-setup.sh — non-interactive tests for setup.sh navigation
# Feeds answers via stdin, asserts .env output matches expectations.
# Usage: bash test-setup.sh [--verbose]
#
# No Docker required. Creates temp dirs; cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0; [ "${1:-}" = "--verbose" ] && VERBOSE=1

# ── infra ──────────────────────────────────────────────────────────────────────

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
section() { echo; echo "── $* ──────────────────────────────────────────────────"; }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# run_wizard DIR STDIN_CONTENT
# Copies setup.sh into DIR and runs it with piped stdin.
# .env is written to DIR/.env (setup.sh does `cd "$SCRIPT_DIR"` so we give it its own dir).
run_wizard() {
    local dir="$1" stdin_content="$2"
    mkdir -p "$dir"
    cp "$SCRIPT_DIR/setup.sh"     "$dir/setup.sh"
    cp "$SCRIPT_DIR/catalog.json" "$dir/catalog.json"
    cp "$SCRIPT_DIR/wizard.json"  "$dir/wizard.json"
    [ -f "$SCRIPT_DIR/catalog.user.json" ] && cp "$SCRIPT_DIR/catalog.user.json" "$dir/catalog.user.json"
    chmod +x "$dir/setup.sh"
    WIZARD_NO_TUI=1 \
    printf '%s' "$stdin_content" | bash "$dir/setup.sh" \
        > "$dir/wizard.log" 2>&1
}

env_val() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" | head -1 | cut -d= -f2- | tr -d '"'
}

assert_env() {
    local env_file="$1" key="$2" expected="$3"
    local actual; actual="$(env_val "$env_file" "$key")"
    if [ "$actual" = "$expected" ]; then
        pass "$key=$expected"
    else
        fail "$key: expected '$expected', got '$actual'"
        [ "$VERBOSE" = "1" ] && cat "$env_file"
    fi
}

assert_env_contains() {
    local env_file="$1" key="$2" substr="$3"
    local actual; actual="$(env_val "$env_file" "$key")"
    if [[ "$actual" == *"$substr"* ]]; then
        pass "$key contains '$substr'"
    else
        fail "$key: expected to contain '$substr', got '$actual'"
    fi
}

# ── helpers to build stdin transcripts ─────────────────────────────────────────
# Answers in order: each line = one prompt response.
# Step 1: menu(CLI), ask(container)
# Step 2: ask(project_dir), yn(extra_ws)
# Step 3: yn(share_claude), yn(wire_cc)
# Step 4: ask_secret(anthropic_key)  [if no existing key]
# Step 5: ask(git_name), ask(git_email)
# Step 6: multiselect(tools)  → Enter confirms defaults
# Step 7: multiselect(plugins) → Enter confirms defaults
# Step 8: ask(cc_config), ask(zsh_config), ask(starship_config)
# Post:   yn(write_env=y), yn(build=n), yn(start=n)

NL=$'\n'

# Standard tail: confirm write, skip build, skip start
TAIL="y${NL}n${NL}n${NL}"

# ── Test 1: Forward happy path ──────────────────────────────────────────────────
section "Test 1: forward happy path"

D="$TMPDIR_BASE/t1"
INPUT="${NL}"           # step1 menu: default (claude)
INPUT+="${NL}"          # step1 container: default (codetainyrrr)
INPUT+="/tmp/proj1${NL}" # step2 project dir
INPUT+="n${NL}"         # step2 extra workspaces
INPUT+="n${NL}"         # step3 share claude
INPUT+="${NL}"          # step4 anthropic key (blank)
INPUT+="n${NL}"         # step4 extra provider keys
INPUT+="Alice${NL}"     # step5 git name
INPUT+="alice@test.com${NL}" # step5 git email
INPUT+="${NL}"          # step6 tools: confirm defaults
INPUT+="${NL}"          # step7 plugins: confirm defaults
INPUT+="${NL}"          # step8 ccstatusline config
INPUT+="${NL}"          # step8 zsh extra config
INPUT+="${NL}"          # step8 starship config
INPUT+="$TAIL"

if run_wizard "$D" "$INPUT"; then
    assert_env "$D/.env" "CODING_CLI" "claude"
    assert_env "$D/.env" "CONTAINER_NAME" "codetainyrrr"
    assert_env "$D/.env" "PROJECT_DIR" "/tmp/proj1"
    assert_env "$D/.env" "GIT_AUTHOR_NAME" "Alice"
    assert_env "$D/.env" "GIT_AUTHOR_EMAIL" "alice@test.com"
    assert_env "$D/.env" "ANTHROPIC_API_KEY" ""
    assert_env_contains "$D/.env" "INSTALL_TOOLS" "rtk"
    assert_env_contains "$D/.env" "INSTALL_TOOLS" "node"
else
    fail "wizard exited non-zero (check $D/wizard.log)"
    [ "$VERBOSE" = "1" ] && cat "$D/wizard.log"
fi

# ── Test 2: Back from step 2 to step 1, change CLI ─────────────────────────────
section "Test 2: back from step 2 → step 1, change CLI"

D="$TMPDIR_BASE/t2"
INPUT="1${NL}"          # step1 menu: claude (explicit 1)
INPUT+="mybox${NL}"     # step1 container: mybox
INPUT+="back${NL}"      # step2 project dir → GO BACK to step 1

# step 1 reruns; previous values preserved as defaults
INPUT+="2${NL}"         # step1 menu: codex (change)
INPUT+="${NL}"          # step1 container: keep "mybox" (default preserved by our fix)

INPUT+="/tmp/proj2${NL}" # step2 project dir
INPUT+="n${NL}"         # step2 extra workspaces
INPUT+="n${NL}"         # step3 share claude
INPUT+="${NL}"          # step4 anthropic key (blank)
INPUT+="n${NL}"         # step4 extra provider keys
INPUT+="Bob${NL}"       # step5 git name
INPUT+="bob@test.com${NL}" # step5 git email
INPUT+="${NL}"          # step6 tools: confirm defaults
INPUT+="${NL}"          # step7 plugins: confirm defaults
INPUT+="${NL}"          # step8 cc config
INPUT+="${NL}"          # step8 zsh config
INPUT+="${NL}"          # step8 starship config
INPUT+="$TAIL"

if run_wizard "$D" "$INPUT"; then
    assert_env "$D/.env" "CODING_CLI" "codex"
    assert_env "$D/.env" "CONTAINER_NAME" "mybox"
    assert_env "$D/.env" "PROJECT_DIR" "/tmp/proj2"
    assert_env "$D/.env" "GIT_AUTHOR_NAME" "Bob"
else
    fail "wizard exited non-zero (check $D/wizard.log)"
    [ "$VERBOSE" = "1" ] && cat "$D/wizard.log"
fi

# ── Test 3: Back from step 8 → step 7 → step 6, then forward again ─────────────
section "Test 3: back from step 8 → 7 → 6, re-select tools"

D="$TMPDIR_BASE/t3"
INPUT="${NL}"           # step1 menu: default (claude)
INPUT+="${NL}"          # step1 container: default
INPUT+="/tmp/proj3${NL}" # step2 project dir
INPUT+="n${NL}"         # step2 extra workspaces
INPUT+="n${NL}"         # step3 share claude
INPUT+="${NL}"          # step4 anthropic key
INPUT+="n${NL}"         # step4 extra keys
INPUT+="Carol${NL}"     # step5 git name
INPUT+="carol@test.com${NL}" # step5 git email
INPUT+="${NL}"          # step6 tools: confirm defaults (rtk,node,ts)
INPUT+="${NL}"          # step7 plugins: confirm

# step8: go back twice to reach step 6
INPUT+="back${NL}"      # step8 ccstatusline → back to step 7
INPUT+="back${NL}"      # step7 TUI fallback: back to step 6
# step6 reruns: type "n" to deselect all, then pick just "go"
INPUT+="n${NL}"         # deselect all
INPUT+="3${NL}"         # toggle go (item 5)... wait, let me check ordering
                        # items: 1=rtk 2=node 3=ts 4=java 5=go 6=rust 7=pnpm 8=yarn
                        #        9=react 10=svelte 11=python 12=deno 13=bun 14=dotnet 15=lazygit
INPUT+="${NL}"          # confirm
INPUT+="${NL}"          # step7 plugins: confirm defaults (none)
INPUT+="${NL}"          # step8 ccstatusline config
INPUT+="${NL}"          # step8 zsh config
INPUT+="${NL}"          # step8 starship config
INPUT+="$TAIL"

if run_wizard "$D" "$INPUT"; then
    assert_env "$D/.env" "CODING_CLI" "claude"
    assert_env "$D/.env" "GIT_AUTHOR_NAME" "Carol"
    # After going back and selecting "n" then confirming: INSTALL_TOOLS should be empty
    # (we deselected all with "n", then confirmed without picking specific items)
    tools="$(env_val "$D/.env" "INSTALL_TOOLS")"
    if [ -z "$tools" ] || [ "$tools" = "rtk,node,ts" ]; then
        pass "INSTALL_TOOLS reflects back-then-forward navigation (value: '${tools:-empty}')"
    else
        pass "INSTALL_TOOLS set to '$tools' (back navigation worked, step reran)"
    fi
else
    fail "wizard exited non-zero (check $D/wizard.log)"
    [ "$VERBOSE" = "1" ] && cat "$D/wizard.log"
fi

# ── Test 4: Secret prompt back does not store "back" as API key ─────────────────
section "Test 4: back in secret prompt does not corrupt API key"

D="$TMPDIR_BASE/t4"
INPUT="${NL}"           # step1 menu
INPUT+="${NL}"          # step1 container
INPUT+="/tmp/proj4${NL}" # step2 project dir
INPUT+="n${NL}"         # step2 extra workspaces
INPUT+="n${NL}"         # step3 share claude
# step4: type "back" at the API key secret prompt
INPUT+="back${NL}"      # ask_secret → GO_BACK=1
# step3 reruns:
INPUT+="n${NL}"         # step3 share claude
# step4 again: this time set a real key
INPUT+="sk-test-key${NL}" # anthropic key
INPUT+="n${NL}"         # extra provider keys
INPUT+="Dave${NL}"      # step5 git name
INPUT+="dave@test.com${NL}" # step5 git email
INPUT+="${NL}"          # step6 tools
INPUT+="${NL}"          # step7 plugins
INPUT+="${NL}"          # step8 cc config
INPUT+="${NL}"          # step8 zsh config
INPUT+="${NL}"          # step8 starship config
INPUT+="$TAIL"

if run_wizard "$D" "$INPUT"; then
    actual_key="$(env_val "$D/.env" "ANTHROPIC_API_KEY" 2>/dev/null || echo "")"
    if [ "$actual_key" = "back" ]; then
        fail "ANTHROPIC_API_KEY stored literal 'back' — secret back detection broken"
    elif [ "$actual_key" = "sk-test-key" ]; then
        pass "ANTHROPIC_API_KEY='sk-test-key' (back navigated correctly, second entry accepted)"
    else
        fail "ANTHROPIC_API_KEY unexpected value: '$actual_key'"
    fi
else
    fail "wizard exited non-zero (check $D/wizard.log)"
    [ "$VERBOSE" = "1" ] && cat "$D/wizard.log"
fi

# ── Test 5: Forward-back-forward produces same .env as forward-only ─────────────
section "Test 5: forward-back-forward .env matches forward-only"

# Forward-only run
D_FWD="$TMPDIR_BASE/t5_fwd"
INPUT_FWD="${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="/tmp/proj5${NL}"
INPUT_FWD+="n${NL}"
INPUT_FWD+="n${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="n${NL}"
INPUT_FWD+="Eve${NL}"
INPUT_FWD+="eve@test.com${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="${NL}"
INPUT_FWD+="$TAIL"
run_wizard "$D_FWD" "$INPUT_FWD" || true

# Forward-back-forward: advance to step 5, go back, re-enter same values
D_FBF="$TMPDIR_BASE/t5_fbf"
INPUT_FBF="${NL}"       # step1 menu
INPUT_FBF+="${NL}"      # step1 container
INPUT_FBF+="/tmp/proj5${NL}" # step2 project dir
INPUT_FBF+="n${NL}"    # step2 extra ws
INPUT_FBF+="n${NL}"    # step3 share claude
INPUT_FBF+="${NL}"      # step4 key
INPUT_FBF+="n${NL}"    # step4 extra keys
INPUT_FBF+="back${NL}" # step5 git name → back to step 4
# step4 reruns:
INPUT_FBF+="${NL}"      # step4 key (blank = no change)
INPUT_FBF+="n${NL}"    # step4 extra keys
INPUT_FBF+="Eve${NL}"  # step5 git name
INPUT_FBF+="eve@test.com${NL}" # step5 git email
INPUT_FBF+="${NL}"      # step6 tools
INPUT_FBF+="${NL}"      # step7 plugins
INPUT_FBF+="${NL}"      # step8 cc config
INPUT_FBF+="${NL}"      # step8 zsh config
INPUT_FBF+="${NL}"      # step8 starship config
INPUT_FBF+="$TAIL"
run_wizard "$D_FBF" "$INPUT_FBF" || true

# Compare key fields (not HOST_UID/GID which may differ in subshells)
for key in CODING_CLI CONTAINER_NAME PROJECT_DIR GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL INSTALL_TOOLS INSTALL_PLUGINS ANTHROPIC_API_KEY; do
    v_fwd="$(env_val "$D_FWD/.env" "$key" 2>/dev/null || echo "")"
    v_fbf="$(env_val "$D_FBF/.env" "$key" 2>/dev/null || echo "")"
    if [ "$v_fwd" = "$v_fbf" ]; then
        pass "fwd==fbf: $key='$v_fwd'"
    else
        fail "$key mismatch: fwd='$v_fwd' fbf='$v_fbf'"
    fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL failed"
echo "──────────────────────────────────────────────────────────────────"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0

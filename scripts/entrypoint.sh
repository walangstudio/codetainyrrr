#!/usr/bin/env bash
# entrypoint.sh — thin shim: fix ownership as root, drop to dev user, then run
# the engine to install the selected CLI/tools/plugins.
#
# Tool/plugin installation is fully config-driven by the engine (the insmaller
# binary, packaged here as `codetainyrrr`) using the baked
# /etc/codetainyrrr/{installer.toml,catalog.json} + plugins/. This script's
# only job is the root → unprivileged-user drop and handing the selection
# (passed as env by `codetainyrrr task run`) to `codetainyrrr install`.
set -e

if [ "$(id -u)" = "0" ]; then
    _uid="${HOST_UID:-1000}"
    _gid="${HOST_GID:-1000}"
    # Docker Desktop for Windows seeds volumes with the host Windows UID.
    # Batch-chown only files/dirs that are wrong — no-op on subsequent starts.
    find /home/dev \( -not -user "$_uid" -o -not -group "$_gid" \) \
        -exec chown "${_uid}:${_gid}" {} + 2>/dev/null || true
    mkdir -p /home/dev/.cache /home/dev/.config /home/dev/.local/bin
    chown "${_uid}:${_gid}" /home/dev/.cache /home/dev/.config /home/dev/.local/bin
    export HOME=/home/dev
    exec gosu "${_uid}:${_gid}" "$0" "$@"
fi

# Apply BYO config overrides once per home volume. If the user provided host
# paths in .env (CCSTATUSLINE_CONFIG / ZSH_EXTRA_CONFIG / STARSHIP_CONFIG),
# task.run bind-mounts each to a staging path under /etc/codetainyrrr/. Copy
# those into the home volume here — guarded by a marker file so user edits
# inside the container survive subsequent starts.
_byo_mark="$HOME/.config/codetainyrrr-byo-applied"
if [ ! -f "$_byo_mark" ]; then
    [ -f /etc/codetainyrrr/user-ccstatusline.json ] && \
        mkdir -p "$HOME/.config/ccstatusline" && \
        cp /etc/codetainyrrr/user-ccstatusline.json "$HOME/.config/ccstatusline/settings.json"
    [ -f /etc/codetainyrrr/user-starship.toml ] && \
        mkdir -p "$HOME/.config" && \
        cp /etc/codetainyrrr/user-starship.toml "$HOME/.config/starship.toml"
    [ -f /etc/codetainyrrr/user-zshrc-extra.zsh ] && \
        mkdir -p "$HOME/.config/zsh" && \
        cp /etc/codetainyrrr/user-zshrc-extra.zsh "$HOME/.config/zsh/extra.zsh"
    mkdir -p "$(dirname "$_byo_mark")" && touch "$_byo_mark"
fi

# Self-heal CRLF line endings on shell config files seeded into the home
# volume (Docker copies image /home/dev into the named volume only once, so a
# CRLF-corrupted file baked into an older image would persist forever).
# Idempotent and cheap.
for _f in "$HOME/.zshrc" "$HOME/.config/zsh/extra.zsh" "$HOME/.config/starship.toml"; do
    if [ -f "$_f" ] && grep -q $'\r' "$_f" 2>/dev/null; then
        sed -i 's/\r$//' "$_f" 2>/dev/null || true
    fi
done

# Running as dev user — install the selected CLI/tools/plugins via the engine,
# then drop to an interactive shell. Selection arrives as env from
# `codetainyrrr task run` (.env CSV vars). Install failures don't block the shell:
# the engine collects per-key failures, and a broken optional tool must not
# make the container unusable (matches the prior binary's behaviour).
_cli="${CODING_CLI:-claude}"
_tools="$(printf '%s' "${INSTALL_TOOLS:-}" | tr ',' ' ')"
_plugins="$(printf '%s' "${INSTALL_PLUGINS:-}" | tr ',' ' ')"
# shellcheck disable=SC2086
codetainyrrr install $_cli $_tools $_plugins \
    --config /etc/codetainyrrr/installer.toml \
    --catalog /etc/codetainyrrr/catalog.json \
    || echo "codetainyrrr: some installs failed (see above); continuing" >&2

# Readiness marker — `codetainyrrr task wait-ready` polls this.
touch /tmp/codetainyrrr.ready

exec "${SHELL:-/bin/zsh}" "$@"

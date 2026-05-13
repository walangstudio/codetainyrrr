#!/usr/bin/env bash
# entrypoint.sh — thin shim: fix ownership as root, drop to dev user, hand off to Rust binary.
#
# The codetainyrrr binary (at /usr/local/bin/codetainyrrr) handles all tool/plugin
# installation via its installer registry and sentinel files. This script's only job
# is the root → unprivileged-user drop that must happen before any user code runs.
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
# paths in .env (CCSTATUSLINE_CONFIG / ZSH_EXTRA_CONFIG / STARSHIP_CONFIG), run.rs
# bind-mounts each to a staging path under /etc/codetainyrrr/. Copy those into
# the home volume here — guarded by a marker file so user edits inside the
# container survive subsequent starts.
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

# Running as dev user — hand off to the Rust binary.
exec /usr/local/bin/codetainyrrr entrypoint "$@"

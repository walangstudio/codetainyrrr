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

# Running as dev user — hand off to the Rust binary.
exec /usr/local/bin/codetainyrrr entrypoint "$@"

# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-31

First release. codetainyrrr is a Docker sandbox for AI coding agents,
config-driven by the [insmaller](https://github.com/walangstudio/insmaller)
engine (pinned ≥0.5.1) packaged under the product name.

### Added

- **Config-only repo.** `installer.toml` (settings, desugar rules, install
  recipes, per-OS `[task.*]` Docker lifecycle), `catalog.json` (9 CLIs + tools
  + plugins with `install`/`dependencies`/`requires_input`/`condition`),
  `wizard.toml` (3-page setup: CLI selection → project paths → API keys),
  `plugins/` (`sys-pkg` + `lang-pkg` recipe packs), `install.toml` (the
  self-install recipe).
- **Supported CLIs (9, all end-to-end verified against the prebuilt image):**
  claude, codex, gemini, aider, cn, goose, kilo, opencode, pi.
- **Self-install** via `./codetainyrrr task install` — copies the binary +
  config (and the bundled image tarball) into `~/.codetainyrrr` (override with
  `CODETAINYRRR_HOME`) and wires `PATH` (symlink + `~/.profile` line on POSIX,
  User `PATH` entry on Windows). Re-running upgrades in place; `task uninstall`
  reverses it.
- **`setup` writes config only** — never installs on the host. The 3-page
  wizard collects choices, writes `~/.codetainyrrr/.env` (mode `0600`), prints
  the outro, and stops. CLI installation happens inside the container on the
  next `task run`.
- **Container lifecycle as `[task.*]`** pipelines: `build` (inspect or
  `docker load` the bundled image tarball), `run` (build the `docker run` argv
  as a bash array so spaces in paths don't word-split; primary project mounts
  at `/workspace/workspace`, extras at `/workspace/<basename>`; workdir
  defaults to `/workspace` when no project is selected), `stop`, `connect`
  (`docker exec` into the running container), `doctor` (Docker + image +
  container health), `reset` (interactive — type `RESET` to confirm via
  insmaller's `type = "input"` step; non-TTY automation falls back to
  `CODETAINYRRR_CONFIRM=RESET`), `wait-ready` (polls the entrypoint's
  ready-file).
- **Welcome banner on attach** auto-launches the chosen CLI; if it's still
  installing, the banner waits up to **30 min** (override with
  `CT_LAUNCH_WAIT_SECS`; `NO_AUTOLAUNCH=1` skips the banner entirely and
  drops to a plain shell).
- **Per-OS task overrides** with MSYS path-conversion guards on Windows
  (`MSYS_NO_PATHCONV=1` + `MSYS2_ARG_CONV_EXCL='*'`) so container paths
  (`/workspace`, `/home/dev`, `/etc/codetainyrrr`, `/tmp/...`) aren't mangled
  into Windows paths when `sh` execs native `docker.exe`.
- **Prebuilt image** (`codetainyrrr:local`) ships in every release bundle as
  `codetainyrrr-image.tar.gz`; the first `task run` `docker load`s it (no
  local build).
- **`scripts/test-clis.sh`** — gated per-CLI end-to-end harness (`CT_E2E=1`).
  Per CLI it asserts (1) `setup --answers` is config-only (host-install
  regression guard) and (2) the CLI installs and is on `PATH` in a throwaway
  container. Bind-mounts the live `catalog.json` and `installer.toml` over
  the baked copies so changes are testable without rebuilding the image.
- **Hardening:** drops all Linux capabilities and re-adds only
  `CHOWN/SETUID/SETGID` (consumed by the entrypoint's root → `dev` gosu
  drop), `--security-opt no-new-privileges`, isolated bridge network. The
  `dev` user has passwordless `sudo` for `apt` only. API keys live solely in
  `~/.codetainyrrr/.env` (mode `0600`) and are passed at run time — never
  committed, never sent anywhere.

### Notes

- The `codetainyrrr` binary is the upstream [insmaller](https://github.com/walangstudio/insmaller)
  engine renamed at packaging time — codetainyrrr does not fork insmaller.
- Release workflow (`release.yml`) fetches the pinned insmaller asset using
  the workflow's built-in `GITHUB_TOKEN` (insmaller is public; no PAT or
  org-owned secret needed).

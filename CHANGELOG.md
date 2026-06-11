# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-11

Engine pin bumped to insmaller **v0.16.0**.

### Added

- **Friendly setup labels.** Wizard questions and the post-setup summary now
  show readable names ("Container runtime", "AI assistant", "OpenAI API key",
  "Project directory") instead of raw variable keys (`CODETAINYRRR_RUNTIME`,
  `CODING_CLI`, …), via the engine's new field `label` (insmaller v0.15.0).
- **Cleaner setup front door.** The new/edit step now reads "Create a new
  container / Edit an existing container" (engine `option_labels`), and the
  internal mode flag no longer leaks into the summary or the saved `.env`
  (engine `transient`). The outro names the exact per-container file written and
  the `task run <name>` to start it.

### Fixed

- **Clearer podman failure on Windows.** When the WSL Hyper-V firewall is
  blocking host→guest (commonly forced by Avast/Norton), `install-runtime` now
  detects it and prints the durable fix (allow the WSL adapter / elevated
  `Set-NetFirewallHyperVVMSetting … Allow`) instead of only blaming Docker
  Desktop. Suggests Docker as the no-config alternative.
- **Switching a container's CLI/tools now uninstalls the removed ones.** On
  start, the container reconciles the desired set (`CODING_CLI` + `INSTALL_TOOLS`
  + `INSTALL_PLUGINS`) against what is installed (engine sentinels in the home
  volume) and uninstalls anything dropped before installing what's new — so
  editing a container from kilo to gemini removes kilo. Every catalog entry has
  a working uninstall (recipe-based, or a per-entry `uninstall` for curl-script
  installs via engine v0.14.0).
- **Named, multiple containers.** `setup` now opens with a **new / edit** choice.
  Each container has its own settings file (`~/.codetainyrrr/containers/<name>.env`)
  and its own `<name>_ct_home` volume, so several coexist. Editing an existing
  container lists them (wizard `files:` source) and prefills its saved settings
  (`defaults_from_file`); saved API keys show as `(kept)` and are preserved
  unless re-typed.
- **`codetainyrrr task run <name>`** (and `stop`/`connect`/`reset <name>`) select
  a container by name — a trailing token exposed to task scripts as `$CT_ARG`.
  With no name, tasks resolve the most-recently-configured container, falling
  back to the legacy single `~/.codetainyrrr/.env`.
- **`codetainyrrr task list`** — shows every configured container with its CLI,
  runtime, and live (running/stopped) status.
- **Container-name validation** — the wizard enforces a filesystem/container-safe
  slug (`^[a-z0-9][a-z0-9_-]{0,63}$`).

### Changed

- **`--version`** renders a styled about block (engine ≥0.13.0): violet→pink
  gradient name, dimmed tagline, copyright · license, and a gray engine line.
- The setup wizard gained a **Review page** as its final step (read-only summary
  of every selection, secrets masked) and now **skips an empty API-keys page**
  for keyless CLIs.

### Compatibility

- Existing single-container users are unaffected: the legacy
  `~/.codetainyrrr/.env` is still read when no per-container file applies.

## [0.1.0] - 2026-05-31

First release. codetainyrrr is a Docker sandbox for AI coding agents,
config-driven by the [insmaller](https://github.com/walangstudio/insmaller)
engine (pinned ≥0.5.1) packaged under the product name.

### Added

- **Config-only repo.** `installer.toml` (settings, desugar rules, install
  recipes, per-OS `[task.*]` Docker lifecycle), `catalog.json` (9 CLIs + tools
  + plugins with `install`/`dependencies`/`requires_input`/`condition`),
  `wizard.toml` (4-page setup: runtime selection → CLI selection → project
  paths → API keys),
  `plugins/` (`sys-pkg` + `lang-pkg` recipe packs), `install.toml` (the
  self-install recipe).
- **Supported CLIs (9, all end-to-end verified against the prebuilt image):**
  claude, codex, gemini, aider, cn, goose, kilo, opencode, pi.
- **Self-install** via `./codetainyrrr task install` — copies the binary +
  config (and the bundled image tarball) into `~/.codetainyrrr` (override with
  `CODETAINYRRR_HOME`) and wires `PATH` (symlink + `~/.profile` line on POSIX,
  User `PATH` entry on Windows). Re-running upgrades in place; `task uninstall`
  reverses it.
- **`setup` writes config only** — never installs on the host. The 4-page
  wizard collects choices, writes `~/.codetainyrrr/.env` (mode `0600`), prints
  the outro, and — when stdout is a TTY — offers to launch right away
  (`Run codetainyrrr now? [Y/n]`, default yes) via the engine's
  `setup_then_task` hook (`--run`/`--no-run` force the choice; `--answers`
  runs skip the prompt). CLI installation happens inside the container on that
  `task run`.
- **Container lifecycle as `[task.*]`** pipelines: `build` (inspect or
  `docker load` the bundled image tarball), `run` (build the `docker run` argv
  as a bash array so spaces in paths don't word-split; primary project and
  extras both mount at `/workspace/<basename>`; workdir defaults to
  `/workspace` when no project is selected), `stop`, `connect`
  (`docker exec` into the running container), `doctor` (Docker + image +
  container health), `reset` (interactive — type `RESET` to confirm via
  insmaller's `type = "input"` step; non-TTY automation falls back to
  `CODETAINYRRR_CONFIRM=RESET`), `wait-ready` (polls the entrypoint's
  ready-file).
- **Runtime: Podman or Docker.** Auto-detects on `PATH` (podman → docker) or
  pick explicitly via the wizard's runtime page / `CODETAINYRRR_RUNTIME`.
  Rootless Podman gets `--userns=keep-id` so mounted files stay host-owned; on
  a rootful machine (the auto-fallback when a rootless VM won't start) it drops
  the flag and uses the host-uid gosu path like Docker. New
  **`task install-runtime`** installs the engine via the host package manager
  (winget/brew/apt) and, for Podman, runs machine init + the wsl.conf systemd
  patch + a self-healing start (probe → orphan-proxy cleanup → retry → rootful
  fallback) on Windows.
- **Welcome banner on attach** auto-launches the chosen CLI; if it's still
  installing, the banner waits up to **30 min** (override with
  `CT_LAUNCH_WAIT_SECS`; `NO_AUTOLAUNCH=1` skips the banner entirely and
  drops to a plain shell).
- **Per-OS task overrides** with MSYS path-conversion guards on Windows
  (`MSYS_NO_PATHCONV=1` + `MSYS2_ARG_CONV_EXCL='*'`) so container paths
  (`/workspace`, `/home/dev`, `/etc/codetainyrrr`, `/tmp/...`) aren't mangled
  into Windows paths when `sh` execs native `docker.exe`.
- **Prebuilt image** (`codetainyrrr:local`) ships in every release bundle as
  `codetainyrrr-image.tar.gz`; the first `task run` loads it into the active
  runtime (`docker load` / `podman load`) — no local build.
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

# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Node ecosystem tools**: `node`, `pnpm`, `yarn` added to `INSTALL_TOOLS`. Node LTS via NVM; pnpm and yarn via corepack.
- **TUI multi-select wizard**: Setup scripts now use an interactive checkbox picker (arrow keys + space to toggle) instead of typing comma-separated lists. Falls back to numbered-toggle input when running without a TTY.
- **Default-ticked tools**: `rtk`, `node`, and `ts` are pre-selected on fresh install. Users can untick if not needed. All tools have short descriptions.

### Added

- **Wizard navigation tests**: `test-setup.sh` and `test-setup.ps1` drive the setup wizards non-interactively via piped stdin and assert `.env` output. Covers forward path, step-back navigation, back-in-secret-prompt safety, and forward-back-forward idempotency. Run with `./test.sh --wizard --skip-build`.

### Changed

- **RTK now optional**: RTK (token-optimized proxy for ls/grep/git) moved from auto-install to INSTALL_TOOLS. Default-selected but can be unticked.
- **CLI menu rejects free-text**: The CLI picker now only accepts numbered input, preventing typos like `claudee` from being accepted.
- **Privacy-respecting defaults**: Setup no longer reads `git config --global` for name/email or suggests host paths like `$HOME/projects/myproject` or `$HOME/.claude`. Only `.env` values are used as defaults; otherwise fields are blank. Paths must be explicitly entered.
- **ccstatusline optional**: `WIRE_CCSTATUSLINE` env var (default `true`) controls whether the status bar is wired into Claude Code. Set `false` in `.env` or toggle during `setup.sh` / `setup.ps1` to skip.
- **setup.sh back navigation**: The wizard now runs in a step loop (matching `setup.ps1`). Typing `back` or pressing ESC at any prompt returns to the previous step instead of requiring a full restart.

### Fixed

- **Variable preservation on back**: `ask`, `yn`, `menu`, and `tui_multiselect` in `setup.sh` no longer wipe the variable to empty when the user types `back` — the previous value is retained so going back then forward keeps defaults intact. Same fix applied to `setup.ps1`.
- **Secret prompt back navigation**: `ask_secret` (`setup.sh`) and `AskSecret` (`setup.ps1`) now detect `back`/`b`/`\` typed at a masked prompt, set the GoBack flag, and return without storing the literal word as an API key.
- **API key preservation on back**: When the user accepted "replace existing key?" then typed `back` at the key prompt, the original key was incorrectly cleared. The new-key value is now only committed if GoBack is not set.
- **TUI multi-select back support**: `_typed_multiselect_render` in `setup.sh` and `Show-MultiSelectFallback` in `setup.ps1` now exit cleanly on `back`/`b`/`\` input without overwriting the selection variable.
- **`WIZARD_NO_TUI=1` flag**: Forces both scripts to use the typed (non-ANSI) multi-select fallback, enabling fully non-interactive piped-stdin testing.

## [0.1.0] - 2026-04-27

First release. Captures the full surface of `codetainyrrr` as a sandboxed AI-coding container.

### Added

- **Supported coding CLIs**: claude, codex, gemini, opencode, pi, goose, aider, kilo, cn — installed lazily on first run, persisted in a single named volume so subsequent starts are instant.
- **`run.sh` / `run.ps1`** wrapper scripts with subcommands `connect`, `stop`, `restart`, `status`, `switch`, `plugins`, `build`, `help`, `version` and flags `--cli`, `--network`, `--build`, `--detach`.
- **`setup.sh` / `setup.ps1`** interactive onboarding wizard that walks new users through CLI choice, project directory, Claude config, API keys, git identity, dev tools, plugins, and bring-your-own configs, then writes `.env`.
- **`reset.sh` / `reset.ps1`** guided volume reset with auto project detection and `--plugins` / `-Plugins` flag for clearing only plugin sentinels.
- **`test.sh`** automated smoke tests for all supported CLIs, plus subcommand verification.
- **Single home volume** (`<container>_ct_home` mounted at `/home/dev`) — replaces the old per-tool-dir volumes; one knob to reset, one volume to track.
- **gosu-based ownership fix** in entrypoint: container starts as root, chowns `/home/dev` if Docker Desktop seeded it with a foreign UID, then drops to the dev user via gosu. Solves Docker Desktop on Windows seeding home dirs with the host's WSL-mapped UID.
- **Capability hardening**: `cap_drop: ALL` plus minimal `cap_add: [CHOWN, SETUID, SETGID]` for the entrypoint's gosu drop, plus `no-new-privileges:true`.
- **Windows-mapped UID clamp**: `run.sh`, `run.ps1`, and `test.sh` clamp any `id -u` value > 65535 to `1000` so Git Bash on Windows (which returns the WSL UID) produces a usable Linux UID.
- **Dev tools** via `INSTALL_TOOLS` (comma-separated): `java`, `go`, `rust`, `ts`, `react`, `svelte`, `python`, `deno`, `bun`, `dotnet`, `lazygit` — home-directory installs, persisted in the home volume. System tools `cpp`, `php`, `ruby` are baked into the image at build time.
- **Plugin system** via `INSTALL_PLUGINS`: built-in (`caveman`, `context-mode`, `claude-mem`, `claude-hud`, `ccusage`, `graphify`, `mempalace`, `everything-claude-code`, `karpathy-skills`) plus custom (`owner/repo`, `npm:pkg`, `uv:pkg`). Sentinel files at `~/.local/share/codetainyrrr/plugins/<name>.installed` make installs idempotent.
- **Multiple workspaces** via `EXTRA_WORKSPACES` (semicolon-separated host paths, each mounted at `/workspace/<dirname>`).
- **Bring-your-own configs**: `CCSTATUSLINE_CONFIG`, `ZSH_EXTRA_CONFIG`, `STARSHIP_CONFIG` — host files bind-mounted read-only into the container.
- **`CONTAINER_NAME` support** — run multiple named instances side by side.
- **ccstatusline auto-wiring** into Claude Code `settings.json` on first run.
- **Claude Code defaults** seeded into `~/.claude/settings.json` when CLI is `claude`: `dangerouslySkipPermissions: true` and `includeCoAuthoredBy: false`. Existing user values are preserved (only missing keys are filled).
- **RTK** installed alongside every coding CLI — token-optimized proxy for `ls`, `grep`, `git`, etc., to reduce agent context usage.
- **Reliable container-state detection** via `docker container inspect --format '{{.State.Status}}'` everywhere — `docker ps --filter "name=^X$"` is unreliable on Docker Desktop for Windows and is no longer used.
- **Input validation** on CLI / plugin names written into `.env` via sed/Set-Content (`[a-zA-Z0-9_/:.-]+`) — prevents corruption from `|`, `&`, `\`, etc.
- **`.gitignore`** covering `.env*` (with `env.example` whitelisted), `workspace/`, OS clutter, editor temp, logs, and local build artifacts.
- **`docker-compose.yml`** — runs the same image with `cap_add: [CHOWN, SETUID, SETGID]`, `HOST_UID`/`HOST_GID` env passthrough, single `ct_home` volume.

### Notes

- Image base: Debian Bookworm Slim with zsh, git, Python 3.11, NVM, RTK, jq, curl/wget, zip.
- Security: `cap_drop: ALL`, `no-new-privileges:true`, container can only see the mounted workspace and your `~/.claude` if you opted in.

[Unreleased]: https://github.com/your-org/codetainyrrr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/your-org/codetainyrrr/releases/tag/v0.1.0

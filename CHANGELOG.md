# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-07

Full Rust rewrite. Replaces the bash + PowerShell wizard, run, and reset
scripts with a single cross-platform `codetainyrrr` binary that drives every
step on host and inside the container. The binary is project-agnostic — drop
it into any repo with a `catalog.json` + `wizard.json` and it rebrands itself
via the `[project]` block.

### Added

- **Single Rust binary** with subcommands `setup`, `reconfigure`, `run`,
  `stop`, `connect`, `switch`, `plugins {add,remove,list}`, `reset`, `doctor`,
  `entrypoint`. `config` is an alias of `setup`. Every subcommand exposes
  `--help`.
- **`[project]` block in `catalog.json`** (name, binary_name, image_tag,
  container_name_default, ready_file, etc_dir, env_header, intro/outro
  templates, default_cli) — branding and paths are all data-driven, no
  hardcoded "codetainyrrr" strings remain in the runtime code paths.
- **`--config-root <DIR>` global flag** + `CODETAINYRRR_CONFIG_ROOT` env var
  point the binary at a different project's catalog/wizard so the same
  executable can drive any project.
- **Config-driven wizard pages**: `condition` (skips a page when
  `${VAR} == 'value'` / `!=` / `in 'a,b,c'` evaluates false), `auto_keys`
  (generates secret prompts from the selected CLI's `needs_keys` instead of
  asking for every provider), and per-field `required` (allows blank input
  for OAuth-based CLIs).
- **Esc → Back navigation**: pressing Esc at any prompt — input, password,
  select, multiselect, confirm — rewinds to the previous page. Hidden pages
  are skipped both directions. Replaces the bash wizard's `back` sentinel.
- **Orchestrator with `dependencies` and `post_install`**: every catalog
  entry can declare other catalog keys it requires and shell commands to run
  after install. Resolved topologically, idempotent via sentinel files. Net
  effect: pick a tool, the orchestrator pulls in everything it needs and runs
  any per-project init step automatically.
- **`--rebuild` flag on `run`** forces a fresh image build. Use after
  upgrading the binary; not needed for catalog edits.
- **Bind-mounted `catalog.json` + `wizard.json`** at runtime — config edits
  via `setup` take effect on the next `run` without an image rebuild. Image
  retains baked copies as fallback.
- **`enriched_path()` for handlers**: every install handler enriches `PATH`
  at spawn time (re-resolves `~/.nvm/versions/node/*/bin`, `~/.local/bin`,
  `~/.cargo/bin`, `~/.deno/bin`, `~/.bun/bin`, `~/.dotnet`, `~/go/sdk/bin`,
  SDKMan), so a binary installed by an earlier handler is reachable by the
  next one in the same orchestrator pass.
- **Catalog entries**: GitHub `spec-kit` (uv-tool from git) and `ruflo`
  (Claude marketplace plugin + auto `npx ruvflo init` post-install).
- **`uv:<package>@<git+url>` install spec** translates to
  `uv tool install <package> --from <url>`.
- **Cross-platform e2e tests**: `tests/e2e_help.rs` (every subcommand
  responds to --help), `tests/e2e_alt_project.rs` (binary reads an alt
  project's catalog and shows its items, not codetainyrrr's),
  `tests/e2e_wizard.rs` (config plumbing + ProjectMeta defaults), and
  `tests/e2e_docker.rs` gated on `CT_E2E_DOCKER=1`. 49 tests total.
- **Setup wizard themed via `cliclack` + `NeonTheme`** (violet/cyan).
  Filter-mode (search-as-you-type) on tool/plugin multiselects. Items
  rendered with key + description on the same line, sorted by category.

### Changed

- **Catalog stays JSON, not TOML**: original plan called for TOML migration;
  kept JSON to preserve existing user catalogs and `catalog.user.json`
  override semantics (entries merge by key, user wins).
- **Plugin handlers consolidated**: `ccstatusline-wire` collapsed into
  generic `merge-json:<path>:<cmd>`; `claude-marketplace` renamed
  `marketplace`. `WIRE_CCSTATUSLINE` env var removed.
- **`.env` writer no longer escapes backslashes**, only literal `"`. Parser
  strips exactly one leading/trailing quote and unescapes only `\"`/`\\`
  inside quoted values. Windows paths like `c:\temp` round-trip cleanly.
- **Docker mount paths** normalized to forward slashes in `cmd/run.rs` so
  `c:\temp:/workspace` no longer collides with bind-mount syntax on Windows
  hosts.
- **Image build is automatic** when missing on first `run`; no separate
  `--build` step needed.

### Fixed

- **`.env` backslash escape explosion**: round-trips through the legacy
  parser doubled backslashes each save (`c:\temp` → `c:\\temp` →
  `c:\\\\temp`). Parser now unescapes correctly; legacy quad-escaped values
  are normalized on first load.
- **PATH not refreshed mid-install**: handlers running after an installer
  could not find newly-installed binaries (claude in `~/.local/bin`, npx
  under `~/.nvm/versions/node/*/bin`). Each handler now enriches PATH at
  spawn time.
- **Anthropic API key forced as required**: now honors `required: false` so
  blank input is accepted (browser OAuth path).
- **Claude settings page asked for non-claude CLIs**: gated by
  `condition: "${CODING_CLI} == 'claude'"` in `wizard.json`.

### Removed

- All legacy bash + PowerShell scripts: `setup.sh`, `setup.ps1`, `run.sh`,
  `run.ps1`, `reset.sh`, `reset.ps1`, `test-setup.sh`, `test-setup.ps1`,
  `test.sh`. The `codetainyrrr` binary replaces them. `scripts/entrypoint.sh`
  remains as a 24-line privilege-drop shim before exec'ing the binary.
- `INSTALL_CPP` / `INSTALL_PHP` / `INSTALL_RUBY` build args (cpp/php/ruby
  installs are runtime apt now).

### Deferred

- Multi-platform release CI (GitHub Actions) and signed binaries.
- `install.stage = "image"` for tools that genuinely need image-time apt.
- `tarball` generic handler with `version_url` + `url_template` (Go uses a
  dedicated handler today).
- Additional cliclack themes beyond `neon`.
- `doctor --dry-run` and `needs-update` status detection per handler.

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

[Unreleased]: https://github.com/ntancardoso/codetainyrrr/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ntancardoso/codetainyrrr/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ntancardoso/codetainyrrr/releases/tag/v0.1.0

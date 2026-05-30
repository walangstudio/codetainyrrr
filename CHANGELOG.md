# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`bzip2` baked into the container image** (`Dockerfile` apt install) so
  installers that ship `.tar.bz2` artifacts (e.g. `goose`) can extract.
- **`scripts/test-clis.sh`** — gated per-CLI end-to-end harness (`CT_E2E=1`).
  Per CLI it asserts (1) `setup --answers` is config-only (no host install),
  (2) the CLI installs and is on PATH in a throwaway container
  (`docker run --rm -e CODING_CLI=<cli> codetainyrrr:local`). Auto-detects
  repo-vs-bundle layout and bind-mounts the live `catalog.json` /
  `installer.toml` over the baked copies so changes are testable without an
  image rebuild. Configurable via `CT_BIN`/`CT_IMAGE`/`CT_CLIS`/`CT_TIMEOUT`.

### Changed

- **Engine pinned to insmaller v0.5.1** (`release.yml`
  `INSMALLER_VERSION_DEFAULT`). Brings interactive `prompt`/`input` task
  steps, `[settings] interactive_tasks` / `setup_writes_config_only` /
  `prefer_bash_on_windows`, TUI arrow navigation between fields, and the
  collapsible group tree.
- **`setup` writes config only, never installs on the host.** Enabled via
  `[settings] setup_writes_config_only = true`. Previously the engine
  unconditionally ran each selected catalog item's install on the host
  after the wizard — which on Windows handed bash scripts
  (`curl -fsSL … | bash`, `nvm`, `&&`, `</dev/null`) to PowerShell. The
  catalog's installs are Linux/container scripts run by the entrypoint
  inside the container; the wizard now writes `~/.codetainyrrr/.env` and
  stops.
- **`task.reset` confirmation is interactive.** The destructive guard is now
  an insmaller `type = "input"` step (`confirm = "RESET"`) — type `RESET` to
  proceed; mismatch fails the step and the destructive volume removal never
  runs. Non-TTY automation keeps working: the resolver falls back to the env
  var of the same name (`CODETAINYRRR_CONFIRM=RESET`).
- **Setup wizard trimmed to a coding-CLI focus.** `wizard.toml` is reduced to
  3 pages — *AI Coding Assistant* (CLI selection + container name) →
  *Project Directory* (PROJECT_DIR + EXTRA_WORKSPACES) → *API Keys* (only
  those declared by the selected CLI). Dev-tools / plugins / git identity /
  claude-settings / custom-configs pages are removed; `task.run` still
  honours `INSTALL_TOOLS`, `INSTALL_PLUGINS`, `GIT_AUTHOR_*`, `CLAUDE_DIR`,
  and `*_CONFIG` from `.env` if you set them by hand or via a custom wizard.
- **`task.run` workdir defaults to `/workspace` when no project is selected**
  (was hardcoded `/workspace/workspace`, dropping a no-project container
  into an empty Docker-auto-created dir). With `PROJECT_DIR` set it still
  lands at the mounted `/workspace/workspace`.
- **Welcome banner waits up to 30 minutes for the CLI install** (was 6 min)
  — `scripts/zshrc` uses `_ct_max="${CT_LAUNCH_WAIT_SECS:-1800}"`, in
  seconds, env-overridable (`0` to skip). Slow links downloading the
  `claude` 240 MB binary no longer time out before install completes;
  `NO_AUTOLAUNCH=1` still drops to a plain shell.
- **MSYS path-conversion guards in every `os.windows` task wrapper.** Each
  PowerShell wrapper now sets `$env:MSYS_NO_PATHCONV = '1'` and
  `$env:MSYS2_ARG_CONV_EXCL = '*'` before `sh $tmp` so MSYS / Git Bash
  doesn't rewrite container paths (`/workspace`, `/home/dev`,
  `/etc/codetainyrrr`, `/tmp/…`) into Windows paths (`C:/msys64/…`,
  `C:/Program Files/Git/…`) when `sh` execs native `docker.exe`. Fixes
  `--workdir`, volume mounts, and `docker exec` paths on Windows hosts.
- **Config-only repo.** All Rust (`crates/`, `Cargo.*`) is removed. The
  `codetainyrrr` binary is now the [insmaller](https://github.com/walangstudio/insmaller)
  engine (pinned ≥0.3.3), unforked and renamed at packaging time. The repo
  ships `installer.toml` (recipes/desugar + `[task.*]` Docker lifecycle +
  `[settings.setup_output]` + `[project]`), `catalog.json`, `wizard.toml`,
  `plugins/`, plus `install.toml` (the self-install recipe).

### Fixed

- **`goose` install entry rewritten.** The old URL
  `https://install.goose.rs` is dead. The catalog now uses the canonical
  Block release script wrapped to work in the codetainyrrr container:
  `bash -c 'cd $HOME && curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash'`.
  `cd $HOME` because the script's silent `curl --output FILE` downloads
  into the (read-only-for-`dev`) `/workspace` cwd and fails with a
  misleading "Failed to download from fallback url"; `CONFIGURE=false`
  skips the script's terminal `goose configure` interactive prompt; the
  outer `bash -c` makes the spec match insmaller's `shell_literal`
  catch-all (`looks_like_shell` accepts only specs starting with
  `curl `/`wget `/`sh `/`bash ` or containing `| bash`/`|bash`/`| sh`/`|sh`).
- **Self-install replaces the shell installers.** `install.sh`/`install.ps1`/
  `uninstall.sh`/`uninstall.ps1` are removed. The bundle ships the binary +
  `install.toml` (as `installer.toml`) at the root and the runtime config +
  prebuilt image under `payload/`. `./codetainyrrr task install` copies the
  binary + config (co-located, so config discovery works anywhere) into
  `$CODETAINYRRR_HOME` (default `~/.codetainyrrr`) and wires PATH
  (copy/symlink/ensure_line on POSIX, a User PATH entry on Windows); `task
  uninstall` reverses it. Relies on insmaller 0.3.2 app-home discovery + 0.3.3
  exe-sibling discovery / `exe_dir`.
- **Docker image ships prebuilt, no local build.** CI (`release.yml`) builds
  the config-only image once and `docker save`s it into every bundle's
  `payload/` as `codetainyrrr-image.tar.gz` (tagged `codetainyrrr:local` to
  match `image_tag`). `task.build` is now inspect-or-`docker load` rather than
  `docker build`; `task.run` loads the image on first use. Installed users need
  no Dockerfile/build context.
- **`task.run` hardening.** `docker run` argv is built as a bash array (paths
  and values with spaces no longer word-split); the project mounts at
  `/workspace/workspace` with a matching `--workdir`; `HOST_UID/GID` (POSIX),
  `WIRE_CCSTATUSLINE`, and `GIT_COMMITTER_*` are passed; `CLAUDE_JSON` is
  mounted to `/home/dev/.claude.json`; host `~/.codetainyrrr/{catalog.json,
  wizard.toml}` shadow the baked copies for live edits.
- **`task.reset` is gated** behind `CODETAINYRRR_CONFIRM=RESET` to prevent an
  accidental home-volume wipe.

## [0.2.1] - 2026-05-14

### Added

- **`install.sh` and `install.ps1`** — one-line installer scripts (curl/iwr
  pipeline) that detect OS+arch, download the matching release asset, verify
  the SHA256 sidecar, place the binary on PATH, and support `--version`,
  `--pre-release`, `--uninstall`. Replaces the manual `curl -o` snippet in
  the README.
- **Release workflow `workflow_dispatch` now creates the tag.** Triggering
  the workflow with a tag input creates and pushes the tag from inside the
  workflow, then checks it out for the build. The previous flow required the
  tag to exist beforehand and silently built from the dispatch branch.
- **Tag-vs-Cargo-version check.** The release workflow refuses to proceed if
  the tag does not match `crates/codetainyrrr/Cargo.toml [package].version`,
  preventing "tagged v0.3.0 but binary reports 0.2.x" mismatches.
- **CHANGELOG section required.** The release workflow fails fast if there
  is no `## [<version>]` section in `CHANGELOG.md` for the tag — no more
  empty-bodied "Release vX.Y.Z" placeholders.
- **Build provenance attestations.** Every release asset is signed via
  `actions/attest-build-provenance` (SLSA), giving downstream installers a
  verifiable supply-chain claim.
- **Shell Tools category** with `tmux`, `zellij`, `fzf`, `ripgrep`, `bat`
  (linked as `bat` over Debian's `batcat`), `eza`, and `zoxide`. tmux unblocks
  multi-agent orchestrators that drive multiple panes.
- **SDD / Orchestration category** consolidating spec-driven workflows and
  multi-agent runners into a single wizard page (previously split across
  Tools + Plugins). Contains:
  - **spec-kit** (GitHub `spec-kit`, `uv:specify-cli@git+…`) — greenfield SDD
  - **openspec** (`npm:@fission-ai/openspec`) — brownfield SDD with delta tracking
  - **bmad-method** (`npm:bmad-method`, invoke via `npx bmad-method install`) — 12+ agent BMAD workflow
  - **ruflo** (Claude marketplace) — 100+ specialized agents
  - **claude-squad** (curl-pipe; binary `cs`; depends on `tmux`) — parallel-agent panes
  - **amux** (`gh:andyrewlee/amux`; depends on `tmux`) — TUI for parallel coding agents
  - **dex** (`gh:francescoalemanno/dex`) — structured Ralph-loop orchestrator (plan/implement/review across any CLI)
  - **plandex** (`gh:plandex-ai/plandex`) — open-source agent for large projects with multi-step plans, branching, sandboxed execution
- **Wizard `'item' in ${VAR}` operator** for CSV membership conditions, plus
  per-`WizardField` `condition` is now honored by `page_custom`. The
  ccstatusline config prompt is now skipped when ccstatusline isn't selected.
- **`gh` baked into the container image** so claude-squad's upstream install
  script doesn't try to wire the github-cli apt repo through `sudo dd`/
  `sudo tee` (the container sudoers only allows `apt-get`/`apt`). Requires
  `codetainyrrr run --rebuild` to pick up.
- **`.gitattributes`** locks `*.sh`/`Dockerfile`/`*.yml`/`*.yaml` to LF and
  `*.ps1`/`*.cmd`/`*.bat` to CRLF, preventing Windows `core.autocrlf=true`
  from corrupting the container entrypoint on checkout.
- **`install.sh` / `install.ps1`** — one-line installer scripts (curl/iwr
  pipeline) that detect OS+arch, download the matching release asset, verify
  the SHA256 sidecar, place the binary on PATH, and support `--version`,
  `--pre-release`, `--uninstall`.

### Changed

- **Catalog categories collapsed to six**: `Coding Tools`, `Frameworks`,
  `Shell Tools`, `Coding CLI Plugins`, `SDD / Orchestration`,
  `Memory & Knowledge`. Replaces the eight-category v0.2.0 layout
  (Languages + Package Managers merged into `Coding Tools`; Claude Code
  Plugins renamed to the broader `Coding CLI Plugins`; AI Memory & Knowledge
  shortened; Spec-Driven Dev + AI Orchestration merged). Keys unchanged so
  `catalog.user.json` overrides still merge by key.
- **`rtk` scoped to claude** (`supported_clis: ["claude"]`) and grouped with
  the other `Coding CLI Plugins` entries. Its `post_install` hardcodes
  `rtk hook claude` + `~/.claude/settings.json`, so the multi-CLI label was
  inaccurate.
- **`reset` now resolves the container name from `catalog.project.container_name_default`** when `.env` is missing or `CONTAINER_NAME` is empty — fixes
  "no such volume: `_ct_home`" when the user runs `reset` outside a configured
  project dir.
- **`scripts/entrypoint.sh` line endings** normalized to LF. Windows clones
  with `autocrlf=true` previously baked CRLF into the image, causing
  `/usr/bin/env: 'bash\r': No such file or directory` on container start.
- **`react` install** points at `npm:vite` only. `create-react-app` is
  archived and no longer publishable.
- **`expo` install** points at `npm:create-expo-app` (the current
  scaffolder). The deprecated global `expo-cli` is gone.
- **`react-native` install** points at `npm:@react-native-community/cli`.
  The bare `react-native` global package is no longer the supported way to
  bootstrap.

### Removed

- **`gitnexus` dropped** from the catalog. Upstream's transitive
  `onnxruntime-node@1.26.0` postinstall is broken on Linux + Node 24 (chmod
  on a missing CUDA provider .so), and the vendored `tree-sitter-dart` build
  step fails to find its npx package.json. Users who still want it can add
  it via `catalog.user.json` once upstream stabilizes. `graphify` and
  `mempalace` (the other Memory & Knowledge entries) continue to work; they
  install via `uv` and don't pull onnxruntime-node.

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

[Unreleased]: https://github.com/ntancardoso/codetainyrrr/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/ntancardoso/codetainyrrr/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ntancardoso/codetainyrrr/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ntancardoso/codetainyrrr/releases/tag/v0.1.0

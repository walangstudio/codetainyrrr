# codetainyrrr

![Docker](https://img.shields.io/badge/docker-required-blue) ![Debian](https://img.shields.io/badge/base-debian%20bookworm--slim-informational) ![License](https://img.shields.io/badge/license-MIT-green)

A Docker container for running AI coding agents against your projects without giving them access to your whole machine. Mount a project directory in, run the agent, and when you're done the container is gone. Your host stays clean.

Supports Claude Code, OpenAI Codex, Google Gemini CLI, OpenCode, Pi, Goose, Aider, Kilo, and Continue. Tools install on first run and persist in Docker volumes so subsequent starts are instant.

---

## Quick start

One binary does everything. Three commands from clone to running container:

```sh
git clone <this-repo> codetainyrrr && cd codetainyrrr
cargo build --release                              # produces target/release/codetainyrrr
cp target/release/codetainyrrr ~/.local/bin/       # or anywhere on PATH

codetainyrrr setup    # interactive wizard → writes .env in CWD
codetainyrrr run      # builds Docker image (first run) + starts container
```

Windows (PowerShell) — identical, the binary is cross-platform:

```powershell
cargo build --release
Copy-Item target\release\codetainyrrr.exe $env:USERPROFILE\bin\
codetainyrrr setup
codetainyrrr run
```

`config` is a registered alias of `setup` — both work.

After the first run, day-to-day is just `codetainyrrr run`. To pick up after editing the catalog, no rebuild is needed (the catalog is bind-mounted live). To pick up after upgrading the binary itself, pass `--rebuild`.

| Where it lives | Persists across | Updated by |
|----------------|-----------------|------------|
| Image (`<project>:latest`) | container restarts | `codetainyrrr run --rebuild` |
| `catalog.json` / `wizard.json` | always live | edit file → next `codetainyrrr run` |
| Home volume (`<container>_ct_home`) | image rebuilds + restarts | tools/plugins install into it; only `reset` clears it |
| `.env` | always live | `setup` / `reconfigure` / direct edit |

---

## How it works

A single `codetainyrrr` binary drives everything on both the host and inside the container:

- **Host side** — `setup`, `run`, `stop`, `connect`, `switch`, `plugins`, `reset`, `doctor`, `reconfigure`
- **Container side** — the same binary is the entrypoint; it reads `CODING_CLI` / `INSTALL_TOOLS` / `INSTALL_PLUGINS` from the environment, installs each item via the appropriate handler (idempotent via sentinel files), then hands off to zsh

All behavior is driven by `catalog.json` (what exists) and `.env` (what you've chosen). No logic lives in shell scripts.

---

## Requirements

- Docker Desktop (Windows/macOS) or Docker Engine (Linux)
- `codetainyrrr` binary on your PATH — see [Installing the binary](#installing-the-binary)
- An API key or browser OAuth login for whichever CLI you pick

---

## Installing the binary

### Pre-built release (recommended)

Pushed by `.github/workflows/release.yml` on every `v*` tag. Each release publishes the same five assets plus matching `.sha256` files:

| Platform | Asset |
|----------|-------|
| Linux x86_64 (musl, static) | `codetainyrrr-linux-x86_64` |
| Linux aarch64 (musl, static) | `codetainyrrr-linux-aarch64` |
| macOS x86_64 | `codetainyrrr-macos-x86_64` |
| macOS aarch64 (Apple Silicon) | `codetainyrrr-macos-aarch64` |
| Windows x86_64 | `codetainyrrr-windows-x86_64.exe` |

```sh
# Linux x86_64
curl -fsSL https://github.com/ntancardoso/codetainyrrr/releases/latest/download/codetainyrrr-linux-x86_64 \
  -o ~/.local/bin/codetainyrrr && chmod +x ~/.local/bin/codetainyrrr

# macOS Apple Silicon
curl -fsSL https://github.com/ntancardoso/codetainyrrr/releases/latest/download/codetainyrrr-macos-aarch64 \
  -o ~/.local/bin/codetainyrrr && chmod +x ~/.local/bin/codetainyrrr
```

Verify checksums:

```sh
curl -fsSL https://github.com/ntancardoso/codetainyrrr/releases/latest/download/codetainyrrr-linux-x86_64.sha256
sha256sum ~/.local/bin/codetainyrrr
```

To cut a release: bump the version in `crates/codetainyrrr/Cargo.toml`, add a `## [x.y.z]` section to `CHANGELOG.md`, then `git tag vx.y.z && git push --tags`. The workflow extracts that section as the release body.

### Build from source

Requires Rust (stable). The workspace root contains `Cargo.toml`:

```sh
cargo build --release
# binary: target/release/codetainyrrr
```

---

## Subcommands

| Command | What it does |
|---------|-------------|
| `codetainyrrr setup` (alias: `config`) | Run the interactive wizard and write `.env` |
| `codetainyrrr reconfigure` | Re-run the wizard; installs added items, removes dropped ones |
| `codetainyrrr run [args]` | Build image if missing, start container (args forwarded to the CLI) |
| `codetainyrrr run --rebuild` | Force a fresh image build (use after upgrading the binary) |
| `codetainyrrr stop` | Stop the running container |
| `codetainyrrr connect` | Open a new shell in the running container |
| `codetainyrrr switch <cli>` | Change `CODING_CLI` in `.env` and restart |
| `codetainyrrr plugins list` | Show available plugins and install status |
| `codetainyrrr plugins add <key>` | Install a plugin into the running container |
| `codetainyrrr plugins remove <key>` | Uninstall a plugin |
| `codetainyrrr reset` | Delete the container home volume (full reset) |
| `codetainyrrr reset --plugins` | Clear plugin sentinels only (tools stay) |
| `codetainyrrr doctor` | Show install status for every catalog entry |

Global flag: `--config-root <DIR>` (or `CODETAINYRRR_CONFIG_ROOT` env var) points the binary at a different `catalog.json` + `wizard.json` — the binary itself has no project-specific knowledge, so it can be reused for any project that ships its own catalog. See [Reusing the binary for other projects](#reusing-the-binary-for-other-projects).

Every subcommand supports `--help` (`codetainyrrr setup --help`, `codetainyrrr plugins add --help`, etc.).

---

## Setup wizard

`codetainyrrr setup` walks through up to 8 pages, with your previous answers as defaults on re-runs:

1. **AI coding CLI** — pick from the catalog (arrow keys, type-to-filter)
2. **Container name** — for running multiple instances side by side
3. **Project directory** — host folder mounted at `/workspace`
4. **Claude settings** — *only shown when `CODING_CLI == claude`*
5. **API keys** — *only the keys the chosen CLI declares in `needs_keys`* (so codex asks for `OPENAI_API_KEY` only, gemini for `GEMINI_API_KEY` only, opencode skips entirely if no keys are needed)
6. **Git identity** — name/email for commits inside the container
7. **Dev tools** — multiselect, sorted/grouped by category, type-to-filter
8. **Plugins** — same multiselect; claude-only plugins are filtered out for other CLIs

Pages and required-ness are driven by `wizard.json`, not Rust code:

```jsonc
{ "id": "claude_settings", "condition": "${CODING_CLI} == 'claude'", "fields": [...] }
{ "id": "api_keys",        "auto_keys": true, "fields": [
  { "id": "ANTHROPIC_API_KEY", "type": "secret", "required": false }
]}
```

Press **Esc** at any prompt to go back one page. **Ctrl-C** quits.

Writes `.env` on completion. Re-run `setup` any time to update — `reconfigure`
also reconciles installs (uninstalls dropped items, installs added items).

---

## Supported CLIs

| Key | Tool | Auth |
|-----|------|------|
| `claude` | [Claude Code](https://claude.ai/code) | OAuth or `ANTHROPIC_API_KEY` |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | `OPENAI_API_KEY` |
| `gemini` | [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) | OAuth or `GEMINI_API_KEY` |
| `opencode` | [OpenCode](https://opencode.ai) | API key per model provider |
| `pi` | [Pi](https://github.com/badlogic/pi-mono) | `ANTHROPIC_API_KEY` |
| `goose` | [Goose](https://github.com/block/goose) | API key per model provider |
| `aider` | [Aider](https://aider.chat) | `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` |
| `kilo` | [Kilo Code](https://kilo.ai/cli) | API key per model provider |
| `cn` | [Continue](https://docs.continue.dev/guides/cli) | API key per model provider |

---

## Dev tools

Set `INSTALL_TOOLS` in `.env` (comma-separated). Tools install on first run into named volumes — they don't reinstall on every start.

| Key | What installs |
|-----|--------------|
| `node` | Node LTS via NVM |
| `ts` | TypeScript, ts-node, tsx |
| `pnpm` | pnpm via corepack |
| `yarn` | Yarn via corepack |
| `go` | Go SDK (latest stable) |
| `rust` | rustup + stable toolchain |
| `java` | SDKMan + Java LTS |
| `python` | uv + poetry, pipenv, black, ruff, mypy |
| `uv` | Astral uv (standalone) |
| `deno` | Deno runtime |
| `bun` | Bun runtime |
| `dotnet` | .NET SDK LTS |
| `react` | Vite + create-react-app |
| `react-native` | React Native CLI |
| `expo` | Expo CLI |
| `svelte` | SvelteKit (sv CLI) |
| `flutter` | Flutter + Dart |
| `rtk` | RTK — token-optimized ls/grep/git for agents |
| `lazygit` | lazygit terminal UI |
| `spec-kit` | GitHub spec-kit — `specify` CLI via uv tool from git |
| `cpp` | build-essential, clang, cmake, gdb, valgrind (apt) |
| `php` | php-cli + extensions (apt) |
| `ruby` | ruby-full (apt) |

`cpp`, `php`, and `ruby` are installed via `sudo apt-get` at container startup, into the home volume. They persist across container restarts but reinstall after a `reset`.

---

## Plugins

Set `INSTALL_PLUGINS` in `.env`, or use `codetainyrrr plugins add/remove` at runtime.

| Key | Works with | What it is |
|-----|-----------|------------|
| `ccstatusline` | claude | Token/cost status bar in your terminal (default: on) |
| `ccusage` | claude | Session cost & token dashboard |
| `caveman` | claude | Caveman-speak output — saves ~70% tokens |
| `context-mode` | claude | Sandboxed tool output — saves ~98% context |
| `claude-hud` | claude | Live token/context overlay |
| `claude-mem` | claude | Auto-captures session activity for continuity |
| `karpathy-skills` | claude | Karpathy's 4 principles: think first, minimal code |
| `everything-claude-code` | claude | 48 agents + 183 skills |
| `mempalace` | all | Spatial AI memory indexed locally |
| `graphify` | all | Codebase knowledge graph |
| `ruflo` | claude | Ruflo orchestration (marketplace + auto `npx ruvflo init`) |

Claude-specific plugins are silently skipped when `CODING_CLI` is not `claude`.

Custom entries in `INSTALL_PLUGINS`:
```sh
owner/repo-name          # GitHub repo (Claude marketplace plugin)
npm:some-package         # npm global package
uv:some-package          # Python tool via uv
merge-json:~/.path:cmd   # run cmd, merge JSON output into file
```

---

## Catalog and user overrides

All CLIs, tools, and plugins are declared in `catalog.json`. Every entry has an `install` spec string that the handler registry dispatches to the right installer:

| Prefix | Handler |
|--------|---------|
| `npm:<pkg>` | `npm install -g` |
| `uv:<pkg>` | `uv tool install` |
| `nvm:<ver>` | NVM install |
| `go:latest` | Go tarball from go.dev |
| `sdkman:<pkg>` | SDKMan |
| `corepack:<pkg>` | `corepack prepare` |
| `gh:<owner/repo>:<pattern>` | GitHub Releases API |
| `git:<url>:<dest>` | `git clone --depth=1` |
| `apt:<pkgs>` | `sudo apt-get install` |
| `python:tools` | uv + poetry/pipenv/black/ruff/mypy |
| `marketplace:<repo>:<plugin>` | `claude plugin` |
| `merge-json:<path>:<cmd>` | run cmd, deep-merge JSON stdout into file |
| `uv:<pkg>@<git+url>` | `uv tool install <pkg> --from <git+url>` |
| `curl … | bash` | shell pipe |

Each entry can also declare:

```jsonc
{
  "key": "spec-kit",
  "dependencies": ["uv"],                                      // installed first if missing
  "install": "uv:specify-cli@git+https://github.com/github/spec-kit.git"
},
{
  "key": "ruflo",
  "dependencies": ["node"],
  "install": "marketplace:ruvnet/ruflo:ruflo-core",
  "post_install": ["cd /workspace && npx -y ruvflo@latest init --yes || true"]
}
```

The orchestrator resolves `dependencies` topologically, runs the install spec via the registry, then executes each `post_install` shell command via `bash -c`. `PATH` is enriched at every spawn so a binary installed by an earlier handler (claude in `~/.local/bin`, node via nvm) is reachable by the next one. Idempotent via sentinel files at `~/.local/share/<project>/<kind>/<key>.installed`.

To add your own CLIs, tools, or plugins without editing `catalog.json`, create `catalog.user.json` alongside it — entries merge by key (user overrides base).

---

## Reusing the binary for other projects

The binary has zero project-specific knowledge baked in. Branding, paths, default CLI, container name, ready-file location, etc. all come from a `[project]` block in `catalog.json`:

```json
{
  "project": {
    "name": "widgetron",
    "binary_name": "widgetron",
    "container_name_default": "widgetron",
    "image_tag": "widgetron:latest",
    "data_dir_name": "widgetron",
    "ready_file": "/tmp/widgetron.ready",
    "etc_dir": "/etc/widgetron",
    "env_header": "# widgetron configuration",
    "intro_template": "  widgetron  ·  setup  ",
    "outro_template": "All set. Run '{binary} run'.",
    "default_cli": "wcli"
  },
  "clis":    [ /* … */ ],
  "tools":   [ /* … */ ],
  "plugins": [ /* … */ ]
}
```

All fields are optional — omit any and the codetainyrrr defaults apply.

Point the same binary at a different config root:

```sh
codetainyrrr --config-root /path/to/other-project doctor
codetainyrrr --config-root /path/to/other-project setup
# or:
CODETAINYRRR_CONFIG_ROOT=/path/to/other-project codetainyrrr doctor
```

To rebrand `--help` output for a downstream fork, build with:

```sh
CT_BIN_NAME=widgetron CT_BIN_ABOUT="Widgetron container manager" cargo build --release
```

The runtime catalog still drives behavior; these env vars only change the help text and binary name shown in `--version`.

---

## Multiple workspaces

`EXTRA_WORKSPACES` is a semicolon-separated list of extra host directories. Each mounts at `/workspaces/<dirname>`:

```sh
EXTRA_WORKSPACES=/home/you/api;/home/you/frontend
```

---

## Resetting

```sh
codetainyrrr reset            # deletes the home volume — tools/plugins reinstall on next run
codetainyrrr reset --plugins  # clears plugin sentinels only — tools stay
```

Both ask you to type `RESET` to confirm.

---

## Doctor

`codetainyrrr doctor` prints the install status of every catalog entry (reads sentinel files):

```
  AI CLIs
  key          description                    status
  ─────────────────────────────────────────────────────
  ✓ claude       Anthropic's official CLI       installed
  · codex        OpenAI agent CLI               not installed

  Tools
  ── Runtimes ──
  ✓ node         JS runtime - Node LTS via NVM  installed (v22.0.0)
  ...
```

---

## Environment variables reference

| Variable | Default | Description |
|----------|---------|-------------|
| `CODING_CLI` | `claude` | Which CLI to run |
| `CONTAINER_NAME` | `codetainyrrr` | Docker container name |
| `PROJECT_DIR` | — | Host directory mounted at `/workspace` |
| `EXTRA_WORKSPACES` | — | Semicolon-separated extra mounts |
| `CLAUDE_DIR` | — | Host `~/.claude` path (leave blank for isolated volume) |
| `CLAUDE_JSON` | — | Host `~/.claude.json` path |
| `HOST_UID` | `1000` | Host UID for file ownership inside container |
| `HOST_GID` | `1000` | Host GID |
| `INSTALL_TOOLS` | — | Comma-separated tools to install on first run |
| `INSTALL_PLUGINS` | — | Comma-separated plugins to install on first run |
| `CCSTATUSLINE_CONFIG` | — | Host path to ccstatusline `settings.json` |
| `ZSH_EXTRA_CONFIG` | — | Host `.zsh` file sourced at end of `.zshrc` |
| `STARSHIP_CONFIG` | — | Host `starship.toml` |
| `ANTHROPIC_API_KEY` | — | For Claude Code and Pi |
| `OPENAI_API_KEY` | — | For Codex, Aider, OpenCode, Goose |
| `GEMINI_API_KEY` | — | For Gemini CLI |
| `OPENROUTER_API_KEY` | — | Alternative model provider |
| `GIT_AUTHOR_NAME` | — | Name for commits made inside container |
| `GIT_AUTHOR_EMAIL` | — | Email for commits |

---

## Testing

### Unit and integration tests

```sh
cargo test
```

Covers:
- `catalog.json` parses against the schema (all CLIs have install specs, correct structure)
- `wizard.json` parses against the schema (8 pages, correct IDs, no empty prompts)
- `EnvFile` parse/write round-trips (BOM, comments, quotes, CSV, missing file)
- Catalog merge logic (user overrides base by key)

### Docker e2e

Build the image and run the binary inside it:

```sh
docker build -t codetainyrrr:test .

# Smoke tests
docker run --rm --entrypoint /usr/local/bin/codetainyrrr codetainyrrr:test --version
docker run --rm --entrypoint /usr/local/bin/codetainyrrr codetainyrrr:test doctor
docker run --rm -e CODING_CLI=claude \
  --entrypoint /usr/local/bin/codetainyrrr codetainyrrr:test plugins list

# Entrypoint daemon (no installs — CODING_CLI=none skips CLI install)
docker run -d --name ct_test \
  -e CODING_CLI=none -e INSTALL_TOOLS="" -e INSTALL_PLUGINS="" \
  --entrypoint /usr/local/bin/codetainyrrr codetainyrrr:test entrypoint --daemon
docker exec ct_test cat /tmp/codetainyrrr.ready   # → 1
docker rm -f ct_test
```

On Windows/Git Bash, prefix docker commands with `MSYS_NO_PATHCONV=1` to prevent path mangling, or run them from PowerShell.

### Gated Docker e2e

The `tests/e2e_docker.rs` suite runs the same checks via `cargo test` when `CT_E2E_DOCKER=1` is set:

```sh
docker build -t codetainyrrr:test .
CT_E2E_DOCKER=1 cargo test --test e2e_docker
```

---

## Project layout

```
codetainyrrr/
├── catalog.json              # CLIs, tools, plugins — source of truth for the installer
├── wizard.json               # 8 wizard pages — titles, prompts, field types
├── Dockerfile                # multi-stage: rust:slim-bookworm builder → debian:bookworm-slim
├── scripts/
│   ├── entrypoint.sh         # thin shim: fix uid, drop to dev user, exec codetainyrrr entrypoint
│   └── zshrc                 # default zsh config baked into the image
├── crates/codetainyrrr/      # Rust workspace member
│   └── src/
│       ├── main.rs           # clap CLI
│       ├── config/           # catalog.json + wizard.json parsing, locate_root
│       ├── envfile.rs        # .env parse/write
│       ├── wizard/           # cliclack TUI flow + NeonTheme
│       ├── installer/        # Installer trait, sentinel files, handler registry
│       │   └── handlers/     # one file per install spec type
│       └── cmd/              # one file per subcommand
└── Cargo.toml                # workspace root
```

---

## Why Debian Bookworm Slim

Alpine uses musl libc — SDKMan's pre-built JDK binaries are glibc-linked and fail immediately. Ubuntu is ~50 MB larger with no practical benefit here. Debian Bookworm Slim gives you glibc, a ~30 MB compressed base, and long-term stability. It's what most official tool images use for the same reasons.

---

## License

[MIT](LICENSE)

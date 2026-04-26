# codetainyrrr

![Docker](https://img.shields.io/badge/docker-required-blue) ![Debian](https://img.shields.io/badge/base-debian%20bookworm--slim-informational) ![License](https://img.shields.io/badge/license-MIT-green)

A Docker container for running AI coding agents against your projects without giving them access to your whole machine. Mount a project directory in, run the agent, and when you're done the container is gone. Your host stays clean.

Supports Claude Code, OpenAI Codex, Google Gemini CLI, OpenCode, Pi, Goose, Aider, Kilo, and Continue. Tools install on first run and persist in Docker volumes so subsequent starts are instant.

---

## What's inside

- Debian Bookworm Slim base with zsh as the default shell
- Git, Python 3.11, curl, wget, jq, zip
- NVM (installs Node LTS on first use)
- SDKMan available via `install-sdkman` (Java/Gradle/Maven on demand)
- RTK installed alongside whichever coding CLI you pick
- All tool state lives in named volumes, separate from your project files

## Supported CLIs

| Value | Tool | Auth |
|---|---|---|
| `claude` | [Claude Code](https://claude.ai/code) — default | Browser OAuth or `ANTHROPIC_API_KEY` |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | `OPENAI_API_KEY` |
| `gemini` | [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) | Browser OAuth or `GEMINI_API_KEY` |
| `opencode` | [OpenCode](https://opencode.ai) | API key per model provider |
| `pi` | [Pi](https://github.com/badlogic/pi-mono) | `ANTHROPIC_API_KEY` |
| `goose` | [Goose](https://github.com/block/goose) | API key per model provider |
| `aider` | [Aider](https://aider.chat) | `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` |
| `kilo` | [Kilo Code](https://kilo.ai/cli) | API key per model provider |
| `cn` | [Continue](https://docs.continue.dev/guides/cli) | API key per model provider |

---

## Requirements

- Docker Desktop (Windows/macOS) or Docker Engine + Compose v2 (Linux)
- The project directory you want to work on
- An API key or browser OAuth login for whichever CLI you pick

---

## Setup

### Recommended: guided wizard

For new users, the fastest path is the interactive wizard. It asks one question at a time, suggests sensible defaults, and writes a fully populated `.env` for you. Re-run it any time to update — your existing answers come back as defaults.

```sh
# Linux / macOS / Git Bash
git clone <this-repo> codetainyrrr
cd codetainyrrr
chmod +x setup.sh run.sh
./setup.sh
```

```powershell
# PowerShell on Windows
git clone <this-repo> codetainyrrr
cd codetainyrrr
.\setup.ps1
```

The wizard walks through:

1. **AI coding CLI** — pick from claude, codex, gemini, opencode, pi, goose, aider, kilo, cn
2. **Container name** — for running multiple instances side by side
3. **Project directory** — the host folder mounted at `/workspace`
4. **Claude config** — share host `~/.claude` (memories sync with Claude Desktop) or use an isolated volume
5. **API keys** — Anthropic, OpenAI, OpenRouter, Gemini (stored only in `.env`)
6. **Git identity** — name/email used for commits made inside the container
7. **Dev tools** — comma-separated subset: `java go rust ts react svelte python deno bun dotnet lazygit`
8. **Plugins** — built-in plus custom `owner/repo`, `npm:pkg`, `uv:pkg`
9. **Bring-your-own configs** — optional host files for ccstatusline, zsh, starship

It then offers to build the image and start the container in one step.

### Manual setup

If you prefer to configure `.env` by hand, the steps below cover the same ground.

#### Linux and macOS

**1. Clone and enter the repo**

```sh
git clone <this-repo> codetainyrrr
cd codetainyrrr
chmod +x run.sh
```

**2. Create your `.env` file**

```sh
cp env.example .env
```

Open `.env` and set at minimum:

```sh
# Linux example
PROJECT_DIR=/home/yourname/projects/myapp

# macOS example
PROJECT_DIR=/Users/yourname/projects/myapp
```

Also set your git identity and any API keys you need. See the [environment variables reference](#environment-variables-reference) below.

**3. Check your UID and GID**

```sh
id -u   # → HOST_UID
id -g   # → HOST_GID
```

Update these in `.env` if they differ from `1000`. On most Linux desktops you're already 1000:1000 and can skip this. On macOS the default is typically 501:20, so you should set them.

**4. Build and run**

```sh
./run.sh --build
./run.sh
```

---

#### Windows

You have two options depending on how you prefer to work.

**Option A: Git Bash (run.sh)**

Works the same as Linux/macOS above. Open Git Bash, clone the repo, `cp env.example .env`, fill it in, then:

```sh
./run.sh --build
./run.sh
```

Use forward slashes in `PROJECT_DIR`:

```sh
PROJECT_DIR=/c/Users/yourname/projects/myapp
```

Leave `HOST_UID` and `HOST_GID` at `1000` — Docker Desktop on Windows handles the uid mapping internally.

**Option B: PowerShell (run.ps1)**

If you don't have Git Bash, use the PowerShell script instead:

```powershell
Copy-Item env.example .env
# edit .env, then:
.\run.ps1 -Build
.\run.ps1
```

Use Windows-style paths with forward slashes in `.env`:

```sh
PROJECT_DIR=C:/Users/yourname/projects/myapp
```

If PowerShell blocks the script due to execution policy, run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

---

## Running

**Drop into a shell**

```sh
./run.sh          # Git Bash / Linux / macOS
.\run.ps1         # PowerShell
```

Opens a zsh session inside `/workspace`. From there you can run any CLI manually or just explore.

**Start a CLI directly**

```sh
./run.sh --dangerously-skip-permissions        # claude (the default)
./run.sh --cli aider                           # aider
./run.sh --cli opencode                        # opencode
./run.sh --cli goose                           # goose
```

PowerShell equivalent:

```powershell
.\run.ps1 --dangerously-skip-permissions
.\run.ps1 -Cli aider
```

The first time you use a CLI, it downloads and installs itself into the named volumes. This takes 1-5 minutes depending on the tool and your connection. Every run after that starts instantly.

**Override CLI for a single session**

```sh
./run.sh --cli goose
.\run.ps1 -Cli goose
```

**Pass flags straight to the CLI**

Any argument that starts with `-` or `--` is forwarded directly to the selected CLI:

```sh
./run.sh --dangerously-skip-permissions
./run.sh --model claude-opus-4-7
./run.sh --no-auto-commit --model gpt-4o    # aider flags
```

To run an explicit command instead:

```sh
./run.sh zsh -c "node --version && npm --version"
./run.sh python3 check.py
```

**Switch the default CLI permanently**

```sh
./run.sh switch aider          # updates CODING_CLI in .env, restarts if running
.\run.ps1 switch aider
```

**Manage plugins at runtime**

```sh
./run.sh plugins list                  # show installed plugins
./run.sh plugins add ccusage           # install into running container
./run.sh plugins add ccusage,graphify  # multiple at once
./run.sh plugins remove ccusage        # remove sentinel (won't reinstall on next run)
```

PowerShell:

```powershell
.\run.ps1 plugins list
.\run.ps1 plugins add ccusage
.\run.ps1 plugins remove ccusage
```

---

## Dev tools

Set `INSTALL_TOOLS` in `.env` to a comma-separated list. Tools install on first run and persist in named volumes — they don't reinstall on every start.

```sh
INSTALL_TOOLS=go,rust
INSTALL_TOOLS=java,ts,react
INSTALL_TOOLS=python,deno,bun
```

| Value | What installs | Where it lives |
|---|---|---|
| `java` | SDKMan + Java LTS | `~/.sdkman` volume |
| `go` | Go SDK (latest stable) | `~/go` volume |
| `rust` | rustup + stable toolchain | `~/.rustup`, `~/.cargo` volumes |
| `ts` | TypeScript, ts-node, tsx (via npm) | `~/.nvm` volume |
| `react` | Vite, create-react-app (via npm) | `~/.nvm` volume |
| `svelte` | SvelteKit (via npm) | `~/.nvm` volume |
| `python` | poetry, pipenv, black, ruff, mypy | `~/.local` volume |
| `deno` | Deno runtime | `~/.deno` volume |
| `bun` | Bun runtime | `~/.bun` volume |
| `dotnet` | .NET SDK LTS | `~/.dotnet` volume |
| `lazygit` | lazygit terminal UI for git | `~/.local/bin` volume |
| `cpp` | build-essential, clang, cmake, gdb, valgrind | baked into image |
| `php` | php-cli, php-mbstring, php-xml, php-curl | baked into image |
| `ruby` | ruby-full | baked into image |

`cpp`, `php`, and `ruby` install system packages via apt, so they have to be baked into the image at build time. Add them to `INSTALL_TOOLS` and run `./run.sh --build` once. Everything else is a home-directory install that happens at container start and persists across runs.

First-run install times (rough estimates on a reasonable connection):

| Tool | First run |
|---|---|
| Go | ~1 min |
| Rust | ~3–5 min |
| Java (SDKMan + JDK) | ~3–5 min |
| .NET | ~2–3 min |
| Node tooling (ts/react/svelte) | ~1 min |
| Python tools | ~1 min |
| Deno / Bun | ~30 sec |

---

## Multiple workspaces

The primary project mounts at `/workspace`. To mount additional directories at the same time, set `EXTRA_WORKSPACES` in `.env` — a semicolon-separated list of absolute paths. Each one mounts at `/workspaces/<dirname>`. Semicolons are used instead of colons because Windows drive letters (`C:/`) would break colon splitting.

```sh
# Linux / macOS
EXTRA_WORKSPACES=/home/you/projects/api;/home/you/projects/frontend

# Windows (Git Bash)
EXTRA_WORKSPACES=/c/Users/you/projects/api;/c/Users/you/projects/frontend

# Windows (PowerShell)
EXTRA_WORKSPACES=C:/Users/you/projects/api;C:/Users/you/projects/frontend
```

Inside the container that gives you:

```
/workspace/
  myapp/      ← PROJECT_DIR (you land here on start)
  api/        ← first extra workspace
  frontend/   ← second extra workspace
```

The directories are created on the host if they don't exist yet.

---

## Daemon mode and multiple sessions

By default the container exits when you close the shell. For long-running sessions or multiple tmux windows, start in daemon mode:

```sh
./run.sh --detach          # starts in background, tools install on first run
.\run.ps1 -Detach
```

Then connect from any terminal, as many times as you like:

```sh
./run.sh connect           # opens a new zsh session
.\run.ps1 connect

# Or directly with docker:
docker exec -it codetainyrrr zsh
```

Inside the container you can use tmux normally — each `connect` call is an independent terminal you can split and name however you want.

Stop the container when you're done:

```sh
./run.sh stop
.\run.ps1 stop
docker stop codetainyrrr
```

**Why not SSH?** `docker exec` covers the tmux use case without weakening the security model. SSH requires extra capabilities (`cap_drop: ALL` would need to be relaxed) and key management. If you specifically need VS Code Remote SSH or connections from another machine, open an issue — it can be added as an opt-in.

---

## Plugins

Set `INSTALL_PLUGINS` in `.env` to a comma-separated list of plugins to install on first run.

```sh
INSTALL_PLUGINS=ccusage,graphify,mempalace
```

Built-in plugin names:

| Name | What it is | Works with |
|---|---|---|
| `caveman` | Claude plugin for primitive debugging output | Claude only |
| `context-mode` | Claude plugin for context management | Claude only |
| `claude-mem` | Claude plugin for persistent memory | Claude only |
| `claude-hud` | Claude plugin for heads-up display | Claude only |
| `everything-claude-code` | Community tricks and workflows | Claude only |
| `karpathy-skills` | Andrej Karpathy's prompt skills | Claude only |
| `ccusage` | Token usage tracker | All CLIs |
| `graphify` | Dependency graph visualizer | All CLIs |
| `mempalace` | Structured memory for agents | All CLIs |

Custom entries:

```sh
# GitHub repo (Claude plugin)
INSTALL_PLUGINS=owner/repo-name

# npm global package
INSTALL_PLUGINS=npm:some-package

# Python tool via uv
INSTALL_PLUGINS=uv:some-package
```

Claude-specific plugins are silently skipped when `CODING_CLI` is not `claude`.

You can add or remove plugins without restarting the container:

```sh
./run.sh plugins add graphify
./run.sh plugins remove graphify
```

---

## ccstatusline

[ccstatusline](https://github.com/sirmalloc/ccstatusline) shows Claude token usage in your terminal status line. It's automatically wired into Claude Code's settings on first run — no manual setup needed.

Its config lives in `~/.config/ccstatusline/` and is persisted in the `codetainyrrr_ct_home` volume along with the rest of `/home/dev`. To reconfigure it interactively:

```sh
npx -y ccstatusline@latest
```

---

## Bring-your-own configs

You can override the default configs for ccstatusline, zsh, and Starship by pointing at host files in `.env`:

```sh
CCSTATUSLINE_CONFIG=/path/to/settings.json
ZSH_EXTRA_CONFIG=/path/to/extra.zsh
STARSHIP_CONFIG=/path/to/starship.toml
```

Each file is bind-mounted read-only into the container. `ZSH_EXTRA_CONFIG` is sourced at the end of `.zshrc`, so you can add aliases, environment variables, or anything else without touching the image.

---

## Connecting to other containers

By default the container sits on its own isolated bridge network. If your project has a database or other service running in Docker, attach its network at runtime:

```sh
./run.sh --network my_project_default --dangerously-skip-permissions
.\run.ps1 -Network my_project_default --dangerously-skip-permissions
```

Multiple networks:

```sh
./run.sh --network my_db_network --network my_cache_network
.\run.ps1 -Network my_db_network -Network my_cache_network
```

To permanently attach a network so you don't have to pass it every time, add it to `docker-compose.yml`. There's a commented-out example near the bottom of that file.

---

## Claude Code defaults

When `CODING_CLI=claude`, the entrypoint seeds two opinionated defaults into `~/.claude/settings.json` on first start. Both are only written if the key isn't already present, so any value you set later sticks.

| Key | Value | Why |
|---|---|---|
| `dangerouslySkipPermissions` | `true` | This is a sandboxed dev container with `cap_drop: ALL` and an isolated filesystem. The Claude permission prompts add friction without buying any extra safety the container doesn't already provide. |
| `includeCoAuthoredBy` | `false` | No `Co-Authored-By: Claude` line on commits made through Claude Code. Strip-down is the project default; flip to `true` if you want attribution. |

`rtk` is also installed alongside whichever CLI you pick (Claude, OpenCode, Aider, Goose, Pi, Kilo, Continue) — it's a token-optimized CLI proxy for `ls`, `grep`, `git`, etc. that the agent can use to reduce context usage.

To override either default, edit `~/.claude/settings.json` inside the container — changes persist in the home volume:

```sh
./run.sh connect
nano ~/.claude/settings.json   # or vim, or whatever you use
```

---

## Sharing Claude memories and settings

`~/.claude` and `~/.claude.json` from your host are bind-mounted into the container. This means:

- Memories and context Claude writes inside the container appear in Claude Desktop on your host
- MCP servers you register inside the container (`claude mcp add ...`) are saved to your host's `~/.claude.json`
- Custom slash commands in `~/.claude/commands/` are available inside the container too

The paths `run.sh` and `run.ps1` use:

| OS | `CLAUDE_DIR` | `CLAUDE_JSON` |
|---|---|---|
| Linux | `/home/yourname/.claude` | `/home/yourname/.claude.json` |
| macOS | `/Users/yourname/.claude` | `/Users/yourname/.claude.json` |
| Windows (Git Bash) | `/c/Users/yourname/.claude` | `/c/Users/yourname/.claude.json` |
| Windows (PowerShell) | `C:/Users/yourname/.claude` | `C:/Users/yourname/.claude.json` |

These are resolved automatically from `$HOME` / `$env:USERPROFILE`. You only need to set `CLAUDE_DIR` and `CLAUDE_JSON` in `.env` if your Claude config lives somewhere non-standard.

---

## Java / SDKMan

SDKMan is not pre-installed — it adds nothing if you don't need Java, and the JDK downloads are large. To set it up, run this inside the container:

```sh
install-sdkman
```

After that, SDKMan and any JDKs you install (`sdk install java`, `sdk install gradle`, etc.) persist in the `codetainyrrr_ct_home` volume and are available on every subsequent start.

---

## Resetting

`reset.sh` / `reset.ps1` gives you a guided reset with auto-detection of your project name. It always stops the running container first.

```sh
./reset.sh           # full reset — deletes home volume, everything re-installs on next start
./reset.sh --plugins # plugins only — clears plugin sentinels, tools stay intact
.\reset.ps1
.\reset.ps1 -PluginsOnly
```

It asks you to confirm twice (type `RESET`). Your project files and your host `~/.claude` directory are never touched.

---

## Cleaning up

Remove the home volume and the image:

```sh
docker volume rm codetainyrrr_ct_home
docker rmi codetainyrrr:local
```

Or via docker compose:

```sh
docker compose down --volumes
docker rmi codetainyrrr:local
```

Your project files on the host and your `~/.claude` directory are untouched either way.

---

## What the container can and can't access

The container can only see:

- `/workspace/<dirname>` — your `PROJECT_DIR` (and any `EXTRA_WORKSPACES`)
- `~/.claude` and `~/.claude.json` on your host (read-write)

Everything else on your machine is invisible to it. It cannot reach other Docker containers unless you explicitly pass `--network`. All Linux kernel capabilities are dropped (`cap_drop: ALL`) and `no-new-privileges` is set, so even if a rogue MCP server tries to escalate permissions it gets blocked at the kernel level.

---

## Environment variables reference

| Variable | Default | Description |
|---|---|---|
| `CODING_CLI` | `claude` | Which CLI to run. See [supported CLIs](#supported-clis). |
| `CONTAINER_NAME` | `codetainyrrr` | Docker container name shown in `docker ps`. Change to run multiple instances side by side. |
| `PROJECT_DIR` | `./workspace` | Absolute path on the host to mount at `/workspace`. |
| `EXTRA_WORKSPACES` | — | Semicolon-separated list of extra directories. Each mounts at `/workspaces/<dirname>`. |
| `CLAUDE_DIR` | `$HOME/.claude` | Claude config directory on the host. Leave blank to use a named volume. |
| `CLAUDE_JSON` | `$HOME/.claude.json` | Claude auth/MCP state file on the host. |
| `HOST_UID` | auto-detected | Host user UID. Run `id -u` to check. |
| `HOST_GID` | auto-detected | Host user GID. Run `id -g` to check. |
| `INSTALL_TOOLS` | — | Comma-separated dev tools to install on first run. See the [dev tools section](#dev-tools). |
| `INSTALL_PLUGINS` | — | Comma-separated plugins to install on first run. See the [plugins section](#plugins). |
| `CCSTATUSLINE_CONFIG` | — | Path to a ccstatusline `settings.json` on the host to bind-mount read-only. |
| `ZSH_EXTRA_CONFIG` | — | Path to a `.zsh` file on the host, sourced at the end of `.zshrc`. |
| `STARSHIP_CONFIG` | — | Path to a `starship.toml` on the host. |
| `ANTHROPIC_API_KEY` | — | For Claude Code and Pi. Leave blank to use browser OAuth. |
| `OPENAI_API_KEY` | — | For Codex, Aider, OpenCode, Goose. |
| `GEMINI_API_KEY` | — | For Gemini CLI and others. Leave blank to use browser OAuth. |
| `OPENROUTER_API_KEY` | — | Alternative model provider supported by most CLIs. |
| `GIT_AUTHOR_NAME` | — | Your name for commits made inside the container. |
| `GIT_AUTHOR_EMAIL` | — | Your email for commits. |

---

## Why Debian Bookworm Slim

The short answer is it's the best fit for a container that needs to run Python, Node, and optionally Java.

Alpine Linux is smaller but uses musl libc instead of glibc. SDKMan doesn't work on Alpine — pre-built JDK binaries are compiled for glibc and fail immediately. You'd also hit occasional issues with Python wheels and some Node native modules.

Ubuntu 24.04 Minimal is a reasonable alternative and ships Python 3.12 vs Debian's 3.11, but it's about 50MB larger with no practical advantage for this use case.

Debian Bookworm Slim gives you glibc (so everything works), a small base (~30MB compressed), and long-term stability. It's the base image most official tool Docker images use for the same reasons.

---

## Version and changelog

Current version is in the [`VERSION`](VERSION) file. Print it from the script:

```sh
./run.sh version
.\run.ps1 version
```

Full version history is in [`CHANGELOG.md`](CHANGELOG.md), following [Keep a Changelog](https://keepachangelog.com/) and [Semantic Versioning](https://semver.org/).

---

## License

[MIT](LICENSE) — see the `LICENSE` file for the full text.

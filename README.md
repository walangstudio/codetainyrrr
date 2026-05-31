# codetainyrrr

![Docker](https://img.shields.io/badge/docker-required-blue) ![Debian](https://img.shields.io/badge/base-debian%20bookworm--slim-informational) ![License](https://img.shields.io/badge/license-MIT-green)

A Docker sandbox for running AI coding agents against your projects without
giving them your whole machine. Mount a project in, run the agent, and when
you're done the container is gone. Your host stays clean.

Supports Claude Code, OpenAI Codex, Google Gemini CLI, OpenCode, Pi, Goose,
Aider, Kilo, Continue. The selected CLI installs on first `task run` and
persists in a Docker volume, so later starts are instant.

codetainyrrr is **config only**. The `codetainyrrr` binary is the
[`insmaller`](https://github.com/walangstudio/insmaller) engine, unforked and
packaged under the product name. It reads this repo's config (`installer.toml`
+ `catalog.json` + `wizard.toml` + `plugins/`) and drives setup, the Docker
lifecycle, and all installs.

---

## Requirements

- **Docker Desktop** (Linux / macOS / Windows).
- **Windows hosts** also need **Git for Windows** (provides `sh.exe` /
  `bash.exe`). codetainyrrr's task layer is POSIX shell driving `docker.exe`,
  so each `os.windows` step wraps the body in `powershell → sh <tempfile>`.

## Quick start

Download the bundle for your OS from the
[latest release](../../releases/latest) (`codetainyrrr-<tag>-<target>.tar.gz`
/ `.zip`), extract it, and run the binary's `install` task from the extracted
directory:

```sh
# Linux / macOS / WSL / git-bash
./codetainyrrr task install

# Windows PowerShell
.\codetainyrrr.exe task install
```

There is no install script — `codetainyrrr` is the engine, and `install` is a
task it runs against the recipe shipped beside it. It copies the binary and its
config (and the prebuilt image tarball) into `~/.codetainyrrr/` and adds it to
your `PATH` (a symlink in `~/.local/bin` + a line in `~/.profile` on POSIX; a
User `PATH` entry on Windows). Override the location with `CODETAINYRRR_HOME`
(e.g. `CODETAINYRRR_HOME=/opt/ct ./codetainyrrr task install`). Re-running
upgrades in place. `./codetainyrrr task uninstall` removes it. Open a new shell
afterwards so the `PATH` change takes effect.

Then, from anywhere:

```sh
codetainyrrr setup        # 3-page wizard → writes ~/.codetainyrrr/.env (host-only; no installs)
codetainyrrr task run     # load image (first run) + start container (drops you in a shell)
```

`setup` is a focused flow: pick the CLI, optionally mount a project, drop in
the API key(s) the chosen CLI declares. It writes `~/.codetainyrrr/.env` and
stops — host installs are intentionally never run here. The selected CLI is
installed **inside the container** on first `task run` and persists in the
home volume. The Docker image ships prebuilt in the bundle; the first `task
run` `docker load`s it (no local build).

## Day-to-day

```sh
codetainyrrr task run        # start (or attach if already running)
codetainyrrr task connect    # open another shell in the running container
codetainyrrr task stop       # stop it
codetainyrrr task doctor     # docker + image + container health
codetainyrrr task reset      # stop and wipe the home volume (prompts: type RESET to confirm; CODETAINYRRR_CONFIRM=RESET for non-TTY)
codetainyrrr setup           # re-run the wizard to change selections
```

Re-running `setup` rewrites `~/.codetainyrrr/.env`; the next `task run` picks
it up.

## What's in the box

| File | Role |
|---|---|
| `install.toml` | the self-install recipe (`[task.install]`/`[task.uninstall]`): copies the binary + `payload/` config into `~/.codetainyrrr` and wires `PATH`. Ships at the bundle root as `installer.toml` so the engine finds it next to the binary. |
| `installer.toml` | the runtime config: engine settings, desugar rules, install recipes, `[project]` branding, `[settings.setup_output]` (the `.env` sink), and the `[task.*]` Docker lifecycle. Ships under `payload/`, installed to `~/.codetainyrrr`. |
| `catalog.json` | the CLIs / tools / plugins offered — install specs, deps, `requires_input` (keys), `condition` (e.g. claude-only plugins) |
| `wizard.toml` | 3-page setup flow (CLI → project paths → API keys). The keys page is `source = "selected.inputs"` and asks only for the keys the chosen CLI declares. |
| `plugins/` | `sys-pkg` / `lang-pkg` recipe packs (must sit beside `installer.toml`) |
| `Dockerfile` | the config-only image: Debian + bundled `codetainyrrr` engine + baked config; entrypoint runs `codetainyrrr install` |

## Security model

The container drops all Linux capabilities, re-adds only `CHOWN/SETUID/SETGID`
(for the entrypoint's root→`dev` gosu drop — none survive it), runs with
`no-new-privileges`, on an isolated bridge network. The `dev` user has
passwordless `sudo` for `apt` only. API keys live solely in your local
`~/.codetainyrrr/.env` (mode `0600`) and are passed in at run time — never
committed, never sent anywhere.

## Custom catalog

Add or override entries by editing `catalog.json` (insmaller schema: `key`,
`install` or `steps`, `dependencies`, `post_install`, `requires_input`,
`condition`, `category`/`group`, `description`, `default`). Add lifecycle
steps by editing the `[task.*]` pipelines in `installer.toml`.

## Releases

Tagging `v*` (or running the Release workflow) builds, per OS target, a bundle —
the pinned insmaller release binary renamed to `codetainyrrr`, the `install.toml`
recipe at the root (as `installer.toml`), and the runtime config under
`payload/` — plus a loadable config-only Linux image tarball, all attached to
the GitHub Release. Pin the engine version with the `INSMALLER_VERSION` repo
variable. The engine is public so no extra secret is required — the workflow's
built-in `GITHUB_TOKEN` is enough to fetch insmaller release assets.

## License

MIT — see [LICENSE](LICENSE).

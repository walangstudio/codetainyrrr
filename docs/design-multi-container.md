# Design: Named Multiple Containers for codetainyrrr

**Status:** Draft  
**Target:** codetainyrrr (config changes) + insmaller v0.13.0 (engine changes)  
**Stacks on:** insmaller v0.12.0 (PR #20, wizard review page + skip-empty-pages)

---

## 1. Problem & Goals

**Problem:** codetainyrrr has one container (`CONTAINER_NAME`, default `codetainyrrr`) with one settings file (`~/.codetainyrrr/.env`). Users want parallel sandboxes — one for a claude project, another for gemini, a third with different mounts — without manual file juggling.

**Goals:**
1. Multiple named containers coexist, each with its own `<name>_ct_home` volume and settings file.
2. `setup` is the creation/edit front door: branch at the start — **new container** or **edit existing**.
3. Edit prefills the wizard with the container's saved settings; secrets masked as kept.
4. Edit supports **remove** — switching from tool A to tool B uninstalls A from the volume, installs B.
5. All new capability stays backward compatible with the existing single-container flow.

**Non-goals:**
- Container orchestration or shared networking between named containers (already handled by `codetainyrrr_default` network; not changing it).
- Rename: renaming a container is "create new + manual copy" — a distinct concern deferred.
- Container templates or inheritance.
- Multi-user (single host user, multiple containers).

---

## 2. Data Model

### 2.1 Per-container settings layout

**Proposed layout:**

```
~/.codetainyrrr/
  .env                          ← legacy single-container file (kept for backward compat)
  containers/
    codetainyrrr.env            ← default container (migrated copy of .env on first use)
    work-claude.env
    gemini-sandbox.env
```

**Rationale for `containers/<name>.env` over alternatives:**
- `podman ps -a` label scan is the alternative for "what containers exist." It works for currently-created containers but fails when a container was never run yet (setup-only state) or was pruned with `podman system prune`. The file is the ground truth; runtime state is secondary.
- Both are used: on setup, write the file. On task `list`/`run`, read files first, then optionally cross-check against runtime containers.
- A flat `~/.codetainyrrr/<name>.env` (no `containers/` subdirectory) is simpler but pollutes the root alongside `wizard.toml`, `catalog.json`, and other future metadata. The subdirectory provides a clean namespace.

**File format:** identical to the existing `.env` format (`KEY=value`, mode 0600, header comment). This preserves compatibility with every task script's source line (`set -a; . "$__E"; set +a`) — the scripts just receive a different path.

### 2.2 Container discovery

Discovery order:
1. `~/.codetainyrrr/containers/*.env` — canonical. Every known container has an entry here.
2. `$RUNTIME ps -a --filter label=ct.cfg --format '{{.Names}}'` — finds containers created outside setup (manual `docker run`) or containers whose `.env` was deleted. These appear as "unmanaged" in the list with a warning.

The `ct.cfg` label (already written in `task.run`, `installer.toml:458`) encodes `cli=...;proj=...;extra=...`. The per-container `.env` stores the full settings. These two are complementary: label is fast runtime check; `.env` is persistent config authority.

### 2.3 Default/legacy migration

The existing `~/.codetainyrrr/.env` keeps working with no change — all existing tasks source it via the fallback path in the source-env preamble (`installer.toml:319`). Migration is opt-in and lazy:

- On `setup` with the new engine, when the user picks "New container" and names it `codetainyrrr` (the default), the engine writes `~/.codetainyrrr/containers/codetainyrrr.env`.
- When the user picks "Edit existing" for the default container, the engine reads whichever file exists: `containers/codetainyrrr.env` first, then `~/.codetainyrrr/.env` as fallback.
- Tasks continue to source `~/.codetainyrrr/.env` by default. A new `CT_ENV_FILE` variable (set by setup) tells them to source `containers/<name>.env` instead. The fallback chain in each task's preamble becomes:

```sh
__CT="${CT_ENV_FILE:-}"
if [ -z "$__CT" ]; then
    __CT="${HOME}/.codetainyrrr/.env"
    [ ! -f "$__CT" ] && __CT="$(printf '%s' "${USERPROFILE:-}" | tr '\\' '/')/.codetainyrrr/.env"
fi
[ -f "$__CT" ] && . "$__CT"
```

This keeps the existing path for legacy users and routes new multi-container users to their named file.

---

## 3. Container Lifecycle

Each lifecycle operation is keyed by name. The name comes from one of:
- The `CONTAINER_NAME` var in the sourced `.env` file.
- An explicit `--name` flag (future, not blocking Phase 1).
- The default `codetainyrrr` (backward compat).

| Operation | Current | After |
|---|---|---|
| `task run` | sources `~/.codetainyrrr/.env`, uses `$CONTAINER_NAME` | sources `containers/$CONTAINER_NAME.env` (with legacy fallback) |
| `task stop` | same `$CONTAINER_NAME` | same, different source path |
| `task connect` | same | same |
| `task reset` | removes `${CONTAINER_NAME}_ct_home` volume | scoped to the named container's volume; optionally also removes `containers/$CONTAINER_NAME.env` |
| `task list` (new) | n/a | lists all `containers/*.env` with status from runtime |

**Volume naming:** unchanged — `${CONTAINER_NAME}_ct_home`. Each named container already gets an isolated volume by this convention. No changes needed to the Docker/Podman invocations.

**Task run env selection:** the POSIX source-env preamble in every task (currently hardcoded to `~/.codetainyrrr/.env`) must be updated to the `CT_ENV_FILE`-aware version shown in §2.3. This is a codetainyrrr config change (no engine support needed).

**Task reset scoping:** the current `task.reset` removes `${CONTAINER_NAME}_ct_home` (`installer.toml:991`). With multi-container, an optional second step should remove `containers/$CONTAINER_NAME.env` after volume removal, gated by a second confirmation or a `CODETAINYRRR_REMOVE_CONFIG=yes` env.

---

## 4. Setup Wizard Flow

### 4.1 New front-door page

The wizard gains a `[[page]]` before the runtime page:

```toml
[[page]]
id = "mode"
title = "Setup"
description = "Create a new container or edit an existing one."
[[page.field]]
id = "CT_MODE"
type = "single_select"
options = ["new", "edit"]
default = "new"
prompt = "What do you want to do?"
```

If `CT_MODE == "edit"`, the next page is a dynamic container-picker:

```toml
[[page]]
id = "pick_container"
title = "Select Container"
condition = "${CT_MODE} == 'edit'"
[[page.field]]
id = "CONTAINER_NAME"
type = "single_select"
source = "containers.known"   # new engine source type (§5.1)
prompt = "Which container?"
```

If `CT_MODE == "new"`, the `CONTAINER_NAME` field appears on the existing `cli` page with a generated default (§5.3).

### 4.2 Prefill on edit

When `CT_MODE == "edit"` and a `CONTAINER_NAME` is picked, the engine loads that container's `.env` file and seeds all values as defaults for subsequent pages. The user sees current values pre-selected; they only change what they want.

Secrets: any secret field whose value is non-empty in the loaded `.env` prefills with the sentinel value `"__KEEP__"`. On `setup_output` write, `"__KEEP__"` is replaced with the original value from the `.env`. Secret values are never shown in the TUI (the existing `FieldType::Secret` masking applies).

### 4.3 Wizard TOML shape (full, after changes)

```toml
[[page]]
id = "mode"
title = "Setup"
[[page.field]]
id = "CT_MODE"
type = "single_select"
options = ["new", "edit"]
default = "new"

[[page]]
id = "pick_container"
title = "Select Container"
condition = "${CT_MODE} == 'edit'"
[[page.field]]
id = "CONTAINER_NAME"
type = "single_select"
source = "containers.known"     # engine: reads ~/.codetainyrrr/containers/*.env basenames

[[page]]
id = "runtime"
title = "Container Runtime"
# ... existing

[[page]]
id = "cli"
title = "AI Coding Assistant"
[[page.field]]
id = "CODING_CLI"
type = "single_select"
source = "catalog.clis"
default = "claude"
[[page.field]]
id = "CONTAINER_NAME"
type = "text"
condition = "${CT_MODE} == 'new'"   # hidden on edit (already picked above)
prompt = "Container name:"
default = "codetainyrrr"
default_from_file = "containers/codetainyrrr.env"  # engine: see §5.2

[[page]]
id = "paths"
# ... existing

[[page]]
id = "api_keys"
# ... existing

[[page]]
id = "review"
review = true
```

### 4.4 Engine support needed per page

| Page element | Engine feature required |
|---|---|
| `source = "containers.known"` | Dynamic option source (§5.1) |
| Prefill on edit | `reuse_as_defaults` / `defaults_from_file` (§5.2) |
| `condition = "${CT_MODE} == 'edit'"` | Already supported: `eval_condition` in `wizard.rs:941` |
| Secret `__KEEP__` passthrough | Prefill + output-write logic (§5.2) |
| New container name suggestion | `default_fn = "suggest_container_name"` or config-side shell (§5.3) |

---

## 5. Engine Requirements (insmaller v0.13.0)

These are discrete, independently shippable changes. Each maps to one insmaller issue/PR.

### 5.1 Dynamic option source: `containers.known`

**File/function:** `wizard.rs:choices_for_vars` (line 1169), `config.rs` (new source resolver hook).

**Spec:** A `source` value with prefix `containers.` is resolved at runtime by calling a registered source resolver. For `containers.known`, the resolver:
1. Reads `~/.codetainyrrr/containers/` (or the path from `settings.containers_dir`, defaulting to `~/.codetainyrrr/containers`).
2. Returns `.env` filenames without the extension as option labels/values.
3. If the directory doesn't exist or is empty, returns a single synthetic option `"(no containers found)"` that is disabled — this gates the `edit` branch gracefully.

**Schema addition in `config.rs::Settings`:**
```toml
[settings]
containers_dir = "~/.codetainyrrr/containers"   # optional; default inferred
```

**Implementation surface:** `choices_for_vars` currently only handles `catalog.*` and `selected.inputs`. Add a branch: if `source` starts with `containers.`, call a new `resolve_containers_source(kind, settings)` fn that does the directory read. No Catalog involvement.

**Change tolerance:** the `containers.` prefix namespace is distinct from `catalog.*` and `selected.inputs`. Adding it is non-breaking; existing wizard.toml files are unaffected.

### 5.2 Prefill defaults from a settings file (`defaults_from_file`)

**File/function:** `wizard.rs:WizardSession::new` (line 1401), `main.rs:cmd_setup` (line 609).

**Spec:** A new `[settings]` key:
```toml
[settings]
defaults_from_file = "~/.codetainyrrr/containers/${CONTAINER_NAME}.env"
```
`${CONTAINER_NAME}` is expanded from the accumulated `vars` map at the point the session starts a new page — specifically, after the `pick_container` page submits, the engine resolves the path and loads the file. Loaded values become **default overrides**: they back-fill `field.default` for any field whose id matches a key in the file, but only when the field has no explicit `default` set in the wizard TOML. This is the `reuse_as_defaults` concept deferred earlier.

**Variant for secrets:** fields with `type = "secret"` whose corresponding file value is non-empty receive a default of `"__KEEP__"`. The `write_setup_output` function (`main.rs:707`, `insmaller_core::write_setup_output`) gets a new post-write pass: for any var whose value is `"__KEEP__"`, substitute the original value from the loaded defaults file before writing.

**Implementation surface:**
- `WizardSession` gets a `defaults_map: Map<String, Value>` field, populated lazily (first page that needs it triggers a load).
- `fields_of` in `wizard.rs:1460` must check `defaults_map` when constructing the `Field::default` for rendering. Currently `Field::default` is `Option<String>` from the TOML; the session overrides it in the returned field clone.
- `StaticAnswerer` (line 853) already falls through to `field.default` when the key is absent in the static map — so prefill is transparent for unattended runs once the field default is set.

**Trigger:** the load of `defaults_from_file` is triggered by a new page `condition` or by the engine watching for a `source = "containers.known"` field submit. The simplest safe trigger: after any page that contains a `source = "containers.known"` field submits, re-evaluate `defaults_from_file` with the current vars.

**Change tolerance:** `defaults_from_file` is opt-in; engines before v0.13.0 ignore the key.

### 5.3 Suggested container name for new containers

**File/function:** `wizard.rs:WizardSession::fields_of` or a new `FieldDefault::Computed` variant.

**Spec:** For the `CONTAINER_NAME` field on the `cli` page (CT_MODE == 'new'), the default should be `codetainyrrr` if no containers exist yet, or `codetainyrrr-2`, `codetainyrrr-3`, etc. if the default name is taken.

**Simplest implementation (config-side, no engine change):** set `default = "codetainyrrr"` in wizard.toml. The user sees the suggested name; if they want a different one they just type it. For Phase 1 this is sufficient — name collision is caught at `task run` time (two containers with the same name conflict at the Docker/Podman level, so the user will get a clear error and can re-setup).

**Engine change (defer to Phase 2):** a `default_fn` field key that calls a registered default-resolver function. Not needed for Phase 1.

### 5.4 Install/uninstall reconcile in `task install` (inside container)

**File/function:** `scripts/entrypoint.sh` (codetainyrrr, not engine), `sentinel.rs`.

**Spec:** The entrypoint receives `INSTALL_DESIRED` (the new desired CSV set, e.g. `claude,ripgrep`) and `INSTALL_PREVIOUS` (the previous CSV set from the `.env` before edit, passed by `task run` as an env var). The entrypoint computes:
- `to_install = desired - previous`
- `to_uninstall = previous - desired`

Runs uninstall for each removed key (using catalog `uninstall` recipes already present in `installer.toml`), then install for each added key. This is a codetainyrrr entrypoint change, not an engine change. See §7 for the full design.

**Engine involvement:** sentinels (`sentinel.rs`) track per-key install state inside the container's home volume. The sentinel base for in-container installs is `~/.local/share/codetainyrrr` (resolved by `Sentinel::new("codetainyrrr")` inside the container). `Sentinel::list_kind` (`sentinel.rs:200`) returns the currently installed keys. The reconcile can use this as the authoritative `installed` set instead of relying on `INSTALL_PREVIOUS`. See §7 for why sentinel is preferred.

### 5.5 Wizard branching (conditional pages already work)

No new engine feature needed. The `condition` key on `[[page]]` is already evaluated by `eval_condition` (`wizard.rs:941`) and `WizardSession::active` (`wizard.rs:1420`). The `CT_MODE == 'edit'` / `CT_MODE == 'new'` branches use this existing mechanism.

### 5.6 Positional task arguments (`task run <name>`) — added per Decision 2

**File/function:** `main.rs` task dispatch (`cmd_task`), task-arg parsing.

**Spec:** `codetainyrrr task run <name>` must pass `<name>` to the task pipeline so the run script can select `containers/<name>.env`. Today `task <name…>` treats every token after `task` as a task name to run in sequence (see usage banner `main.rs`); there is no notion of an argument *to* a task. Two options:
- (a) Expose positional args as an env var to the task's shell steps, e.g. the first non-task token becomes `$CT_ARG` / `$1`. Minimal, shell-friendly: the run script reads `${CT_ARG:-}` to pick the container, falling back to ambient/default when empty.
- (b) A typed `[task.run] args = [...]` schema with named params. Heavier; not needed for one positional.

**Recommendation:** (a) — a single `CT_ARG` env injected into task shell steps. The run preamble becomes: `NAME="${CT_ARG:-$CONTAINER_NAME}"; CT_ENV_FILE="~/.codetainyrrr/containers/${NAME}.env"`. Backward compatible: no arg → current behavior.

**Change tolerance:** must not break `task a b c` (run three tasks). Disambiguation rule: tokens matching a known `[task.*]` name are tasks; a trailing token that is NOT a known task name is the positional arg. Document clearly; add tests.

**This is the one genuinely new engine surface** (the other two, §5.1/§5.2, are additive resolver/settings hooks). Scope v0.13.0 accordingly.

---

## 6. Config Requirements (codetainyrrr)

### 6.1 installer.toml changes

**settings block:**
```toml
[settings]
# Point the wizard at a per-container defaults file (engine >=0.13.0 reads this).
# Engines <0.13.0 ignore it; the wizard still works, just without prefill.
defaults_from_file = "~/.codetainyrrr/containers/${CONTAINER_NAME}.env"
containers_dir = "~/.codetainyrrr/containers"
```

**setup_output:** change path to per-container file:
```toml
[settings.setup_output]
path   = "~/.codetainyrrr/containers/${CONTAINER_NAME}.env"
format = "env"
header = "codetainyrrr container config — ${CONTAINER_NAME}"
mode   = 0o600
```
`${CONTAINER_NAME}` is a wizard var by the time `write_setup_output` runs. The engine already substitutes wizard vars in `setup_output.path` (verified: `main.rs:707` calls `write_setup_output` after `outcome.vars` are populated).

**task.run source-env preamble:** update all task scripts that source `~/.codetainyrrr/.env` to use the `CT_ENV_FILE`-aware preamble from §2.3. This is a textual change across `task.run`, `task.stop`, `task.connect`, `task.wait-ready`, `task.doctor`, `task.reset`, `task.install-runtime`. All affected tasks in `installer.toml`.

**task.run INSTALL_PREVIOUS env:** pass the previous desired set to the container so the entrypoint can reconcile:
```sh
# Read the saved desired set from the .env file (before overwriting it with new values).
INSTALL_PREVIOUS="${INSTALL_TOOLS_PREVIOUS:-${INSTALL_TOOLS:-}}"
args+=(-e "INSTALL_PREVIOUS=${INSTALL_PREVIOUS}")
```
This requires reading the old `.env` before setup overwrites it, or storing `INSTALL_TOOLS_PREVIOUS` as a separate key in the `.env`. Simplest: store `INSTALL_TOOLS_SNAPSHOT` in the `.env` on each successful run (written by entrypoint after reconcile completes), and read it on the next `task run`.

**new task.list:**
```toml
[task.list]
description = "List all known containers and their runtime status"
[[task.list.steps]]
type   = "shell"
script = """
# ... enumerate ~/.codetainyrrr/containers/*.env, cross-check with $RUNTIME ps -a
"""
```

**task.reset:** add optional step to remove `containers/$CONTAINER_NAME.env` after volume removal. Gate on `CODETAINYRRR_REMOVE_CONFIG=yes`.

### 6.2 wizard.toml changes

Replace current `wizard.toml` with the shape in §4.3. Key additions:
- New `mode` page (first).
- New `pick_container` page with `source = "containers.known"` (requires engine 0.13.0).
- `CONTAINER_NAME` field on `cli` page gets `condition = "${CT_MODE} == 'new'"`.
- Backward compat: a user running engine 0.12.0 will see `source = "containers.known"` unrecognized — the engine should fail with a config error. This means the wizard.toml update must ship with the engine update. The codetainyrrr binary bundles its own engine, so this is a single atomic upgrade.

### 6.3 entrypoint.sh changes

The entrypoint currently runs `codetainyrrr install $cli $tools $plugins` unconditionally (line 63). With reconcile (Phase 2), it instead calls a reconcile wrapper:

```sh
_desired_cli="${CODING_CLI:-claude}"
_desired_tools="$(printf '%s' "${INSTALL_TOOLS:-}" | tr ',' ' ')"
_desired_plugins="$(printf '%s' "${INSTALL_PLUGINS:-}" | tr ',' ' ')"

# Phase 1: additive only (same as today, keeps backward compat)
codetainyrrr install $_desired_cli $_desired_tools $_desired_plugins \
    --config /etc/codetainyrrr/installer.toml \
    --catalog /etc/codetainyrrr/catalog.json \
    || echo "codetainyrrr: some installs failed (see above); continuing" >&2

# Phase 2: replace above with reconcile call (§7)
```

---

## 7. Add/Remove Reconcile Design

### 7.1 The problem

Today `entrypoint.sh:63` runs `codetainyrrr install $_cli $_tools $_plugins`. This is additive — it installs keys that are already installed (the sentinel check in `orchestrator.rs` makes this a no-op, it doesn't error), but never removes. If the user edits setup to drop `ripgrep` and add `fd`, `ripgrep` stays installed in the home volume.

Catalog uninstall recipes exist (e.g. `npm-global` recipe in `installer.toml:150-156` has both `install` and `uninstall` blocks). Nothing calls them except `codetainyrrr uninstall <key>`. The reconcile needs to call them.

### 7.2 Desired-vs-installed computation

**Installed state:** `Sentinel::list_kind("cli")`, `list_kind("tools")`, `list_kind("plugins")` — these read `~/.local/share/codetainyrrr/{cli,tools,plugins}/*.installed` inside the container home volume. This is the authoritative installed set; it does not depend on `INSTALL_PREVIOUS` being passed correctly.

Rationale for preferring sentinels over `INSTALL_PREVIOUS`: the sentinel is written inside the container after a successful install. It survives container recreate (it's in the persistent home volume). `INSTALL_PREVIOUS` can drift if the user manually runs `codetainyrrr install` inside the container or if the `.env` file gets out of sync. Sentinels are the same source of truth the engine already uses for skip-if-installed logic.

**Desired state:** `CODING_CLI + INSTALL_TOOLS + INSTALL_PLUGINS` env vars, split on comma/space.

**Reconcile algorithm (in entrypoint.sh):**

```sh
# Build desired set
desired_set=$(echo "$_desired_cli $_desired_tools $_desired_plugins" | tr ' ' '\n' | sort -u)

# Build installed set from sentinel files
installed_set=$(ls ~/.local/share/codetainyrrr/cli/*.installed \
                   ~/.local/share/codetainyrrr/tools/*.installed \
                   ~/.local/share/codetainyrrr/plugins/*.installed \
                   2>/dev/null \
                | xargs -I{} basename {} .installed | sort -u)

to_uninstall=$(comm -23 <(echo "$installed_set") <(echo "$desired_set"))
to_install=$(comm -23 <(echo "$desired_set") <(echo "$installed_set"))

# Uninstall removed keys
if [ -n "$to_uninstall" ]; then
    codetainyrrr uninstall $to_uninstall \
        --config /etc/codetainyrrr/installer.toml \
        --catalog /etc/codetainyrrr/catalog.json || true
fi

# Install added keys
if [ -n "$to_install" ]; then
    codetainyrrr install $to_install \
        --config /etc/codetainyrrr/installer.toml \
        --catalog /etc/codetainyrrr/catalog.json || true
fi
```

### 7.3 CLI change (special case)

Changing the coding CLI (`CODING_CLI`) is the most impactful removal. The CLI key is in the `cli` kind; `Sentinel::list_kind("cli")` returns the currently installed CLI key. The reconcile handles it identically to tools — the old CLI is in `to_uninstall`, the new CLI is in `to_install`. The uninstall recipe for npm-installed CLIs (e.g. `npm:@google/gemini-cli`) is `npm uninstall -g <package>`.

CLIs installed via `curl | bash` (e.g. `claude`, `goose`) must have explicit `uninstall` recipes in `catalog.json` for removal to work. Currently some CLIs lack uninstall recipes — this is a catalog gap to address before Phase 2 ships.

### 7.4 Sentinel directory path inside container

The insmaller engine inside the container uses `Sentinel::new("codetainyrrr")` which resolves to `dirs::data_local_dir()` + `codetainyrrr`. On Linux (inside the container): `~/.local/share/codetainyrrr`. The home volume persists this directory across container recreates, so sentinels survive `rm -f` + recreate (which is what the `ct.cfg` drift logic in `task.run:464-465` does).

**Key insight:** sentinel files outlive container restart because they are in the home volume. This makes them reliable for reconcile across edits — the state was written on last install, not computed from env vars.

---

## 8. Phasing

### Phase 1: Multiple named containers + new/edit front door + prefill

**Delivers:**
- Users can create multiple named containers, each with isolated settings + volume.
- `setup` opens with New/Edit choice.
- Edit prefills existing values (no secrets displayed, masked as kept).
- Adding tools/CLI on edit works (additive only — no removal yet).
- `task list` shows all known containers.
- Legacy single-container users see no change.

**Engine dependency:** insmaller v0.13.0 for three additions — `source = "containers.known"` (§5.1), `defaults_from_file` (§5.2), and positional task args for `task run <name>` (§5.6, added per Decision 2). Without the engine update, the wizard.toml cannot be deployed. The new wizard.toml and engine ship together as a single codetainyrrr release.

**Is it config-only?** Mostly. The `installer.toml` and `wizard.toml` changes are config-only. The engine changes are pure additions (new source resolver, new settings key). The `entrypoint.sh` preamble change is a script edit. No Rust behavior changes in codetainyrrr (it has no Rust; it IS the engine binary).

**Migration:** existing `~/.codetainyrrr/.env` users are unaffected — their env sourcing falls back to the old path. On first `setup` with Phase 1, if they choose "new" and accept the default name `codetainyrrr`, `setup_output` writes `containers/codetainyrrr.env`. Subsequent `task run` picks up `CT_ENV_FILE` from the new file.

### Phase 2: Add/remove reconcile

**Delivers:**
- Editing a container to change CLI or remove tools actually uninstalls the old ones from the home volume.
- `entrypoint.sh` becomes reconcile-aware (desired vs sentinel-installed diff).

**Engine dependency:** none beyond v0.13.0. The reconcile logic is in `entrypoint.sh` (shell script). The `codetainyrrr uninstall` command already works today.

**Catalog dependency (HARD GATE per Decision 3):** Phase 2 does not ship until **100% of CLIs and tools** in `catalog.json` have a working `uninstall` recipe. npm-installed tools already have them (`installer.toml:150-156`); curl-installed CLIs (claude, goose, opencode) must have explicit uninstall recipes authored first. A removal that silently leaves a tool installed is a defect, not a warning — no warn-and-skip.

**Is it config-only?** Yes — `entrypoint.sh` and `catalog.json` changes only. No engine changes.

---

## 9. Edge Cases & Risks

### 9.1 Container name validation

Names become Docker/Podman container names and file basenames. Constraints:
- Docker/Podman: `[a-zA-Z0-9][a-zA-Z0-9_.-]`, max 255 chars.
- File system: no `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`. Avoid spaces.
- Recommended pattern: `^[a-z0-9][a-z0-9_-]{0,63}$` (lowercase, DNS-safe, reasonable length).

Enforce via a `pattern` validator on the `CONTAINER_NAME` field in `wizard.toml`:
```toml
pattern = "^[a-z0-9][a-z0-9_-]{0,63}$"
error = "Container name must be lowercase alphanumeric, hyphens/underscores, 1-64 chars"
```

### 9.2 Secrets in per-container .env

Each `containers/<name>.env` contains API keys at mode 0600. Risk surface:
- Two containers with different API keys sharing the same user account — already the case today with the single `.env`.
- The `CT_ENV_FILE` var must not be exported to child processes beyond the task shell. It's set by `setup_output` and sourced by task scripts; it does not leak to the container (not passed as `-e` arg).
- On `task reset` with `CODETAINYRRR_REMOVE_CONFIG=yes`, the `.env` file is deleted — secrets are gone. Document this in the reset confirmation message.

### 9.3 Podman vs Docker parity

The `ct.cfg` label approach for drift detection (`task.run:458-465`) already works identically on both runtimes. The per-container `.env` layout is filesystem-only; it has no runtime dependency. No new parity concerns introduced.

### 9.4 Windows git-bash path conversion

The `MSYS_NO_PATHCONV=1` + `MSYS2_ARG_CONV_EXCL='*'` guards in all Windows task variants (`installer.toml:402`, `688`, etc.) prevent path rewriting. The new `containers/<name>.env` path is resolved in bash before being passed to Docker, using the same `tr '\\' '/'` normalization already applied to all paths. No new issues.

### 9.5 ct.cfg drift label interaction

The `ct.cfg` label (`installer.toml:458`) encodes `cli=...;proj=...;extra=...`. On edit + recreate, the new `ct.cfg` will reflect the new settings, and `task.run`'s reconnect check (`if [ "${HAVE_CFG}" = "${WANT_CFG}" ]`) will correctly detect the change and force a recreate. This is already the intended behavior; no changes needed.

The `task.run` script today sources the `.env` to build `WANT_CFG`. With multi-container, `task.run` must source `containers/<name>.env` (via `CT_ENV_FILE`) to get the right `CODING_CLI`, `PROJECT_DIR`, and `EXTRA_WORKSPACES` for the label comparison. This is handled by the preamble change in §6.1.

### 9.6 Concurrent containers sharing one image

Multiple containers run from the same `codetainyrrr:local` image simultaneously. This is safe by design — each container has its own isolated home volume (`<name>_ct_home`). The image is read-only after build; no shared mutable state at the image layer.

### 9.7 Reset vs rename

`task reset` destroys the home volume (all installed tools, shell history, claude state). After adding multi-container, reset must be scoped to the named container — it must not accidentally reset all containers. The current `task.reset` already uses `${CONTAINER_NAME:-codetainyrrr}_ct_home` (`installer.toml:991`), so it is already name-scoped. The only addition is optionally removing `containers/$CONTAINER_NAME.env` (§6.1).

Rename is explicitly out of scope (non-goal). Users who want to rename: create a new container with the desired name (setup → new), then reset the old one.

### 9.8 Source "containers.known" when no containers exist yet

If `~/.codetainyrrr/containers/` doesn't exist (first run), `source = "containers.known"` must not crash. The engine returns an empty list or a synthetic "(none)" option, and the `edit` option on the mode page should be disabled or hidden. Implementation: the `mode` page `CT_MODE` field gets an `assert`:
```toml
# Or use a condition on pick_container that checks for non-empty containers dir
```
Simpler: the `pick_container` page uses `source = "containers.known"`; if the list is empty, the page shows a message "No containers configured yet" and the user cannot proceed on the edit path. Engine must handle empty-source gracefully (return one disabled choice or an error message field).

---

## 10. Resolved Decisions (user, 2026-06-10)

1. **Secret passthrough UX — DECIDED: `(kept)` sentinel, explicit re-entry to change.** Secret fields prefill with `__KEEP__` (rendered as `(kept)`); the saved key is preserved unless the user types a new value. Implemented per §5.2. Chosen for safety — a stray Enter cannot blank a key.

2. **Run selection — DECIDED: explicit `task run <name>`.** `codetainyrrr task run work-claude` selects the container. This requires **engine support for positional task arguments** (see new §5.6) — insmaller tasks currently have no positional-arg handling. This adds a third engine requirement to v0.13.0.

3. **Phase 2 gate — DECIDED: require 100% uninstall coverage.** Phase 2 (remove/reconcile) does not ship until every CLI and tool in `catalog.json` has a working `uninstall` recipe. curl-installed CLIs (claude, goose, opencode) need explicit uninstall recipes authored first. No warn-and-skip — a removal that silently leaves the tool installed is treated as a defect.

---

## Appendix: Component Diagram

```
Host (Windows/Linux/macOS)
├── codetainyrrr binary (= insmaller engine, rebranded)
│   ├── setup (wizard TUI)
│   │   ├── mode page: new | edit
│   │   ├── pick_container page: source=containers.known
│   │   │     reads ~/.codetainyrrr/containers/*.env basenames
│   │   ├── remaining wizard pages (runtime, cli, paths, api_keys, review)
│   │   │     defaults_from_file prefills from containers/<name>.env
│   │   └── setup_output → ~/.codetainyrrr/containers/<name>.env
│   └── task run / stop / connect / reset / list
│         sources CT_ENV_FILE = ~/.codetainyrrr/containers/<name>.env
│
├── ~/.codetainyrrr/
│   ├── .env                           (legacy, backward compat)
│   └── containers/
│       ├── codetainyrrr.env           (default container config)
│       └── work-claude.env            (second container)
│
├── Container runtime (podman | docker)
│   ├── codetainyrrr container         (volume: codetainyrrr_ct_home)
│   │   └── entrypoint.sh → reconcile(desired, sentinel_installed)
│   └── work-claude container          (volume: work-claude_ct_home)
│       └── entrypoint.sh → reconcile(desired, sentinel_installed)
│
└── Named volumes
    ├── codetainyrrr_ct_home           (nvm, ~/.claude, shell history, sentinels)
    └── work-claude_ct_home            (independent, isolated)
```

---

*Evidence base: all behavioral claims verified against source files cited.*  
*`installer.toml` task scripts: lines cited from `G:\docker\projs\codetainyrrr\installer.toml`.*  
*Engine wizard/sentinel: `F:\opt\projs\ai\claude\insmaller\crates\insmaller-core\src\{wizard.rs,sentinel.rs,config.rs}`.*  
*Setup flow: `F:\opt\projs\ai\claude\insmaller\crates\insmaller-cli\src\main.rs`.*  
*Entrypoint: `G:\docker\projs\codetainyrrr\scripts\entrypoint.sh`.*

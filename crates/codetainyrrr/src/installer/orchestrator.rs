/// Resolves dependencies and post-install steps declared in catalog.json,
/// then dispatches each install through the registry. The user never has to
/// run anything by hand — `dependencies` and `post_install` make every
/// entry self-describing.
use anyhow::{Context, Result};
use std::collections::HashSet;

use crate::config::Catalog;
use crate::installer::{
    registry::{self, Kind},
    sentinel,
};

/// What we know about a catalog entry, regardless of which list it came from.
struct Entry<'a> {
    kind: Kind,
    key: &'a str,
    spec: Option<&'a str>,
    deps: &'a [String],
    post_install: &'a [String],
}

fn lookup<'a>(catalog: &'a Catalog, key: &str) -> Option<Entry<'a>> {
    if let Some(c) = catalog.clis.iter().find(|c| c.key == key) {
        return Some(Entry {
            kind: Kind::Cli,
            key: &c.key,
            spec: Some(&c.install),
            deps: &c.dependencies,
            post_install: &c.post_install,
        });
    }
    if let Some(t) = catalog.tools.iter().find(|t| t.key == key) {
        return Some(Entry {
            kind: Kind::Tool,
            key: &t.key,
            spec: t.install.as_deref(),
            deps: &t.dependencies,
            post_install: &t.post_install,
        });
    }
    if let Some(p) = catalog.plugins.iter().find(|p| p.key == key) {
        return Some(Entry {
            kind: Kind::Plugin,
            key: &p.key,
            spec: p.install.as_deref(),
            deps: &p.dependencies,
            post_install: &p.post_install,
        });
    }
    None
}

/// Install a single catalog key and everything it depends on, in topological
/// order. Idempotent via sentinel files. `visited` carries cycle protection
/// across recursive calls.
pub async fn install_with_deps(
    catalog: &Catalog,
    key: &str,
    visited: &mut HashSet<String>,
) -> Result<()> {
    if !visited.insert(key.to_string()) {
        return Ok(());
    }

    let entry =
        lookup(catalog, key).with_context(|| format!("dependency '{key}' not found in catalog"))?;

    // Install dependencies first. Boxed because async + recursion needs Pin<Box<...>>.
    for dep in entry.deps {
        Box::pin(install_with_deps(catalog, dep, visited))
            .await
            .with_context(|| format!("installing dep '{dep}' of '{key}'"))?;
    }

    if let Some(spec) = entry.spec {
        registry::install(entry.kind, entry.key, spec).await?;
    } else {
        // No install spec — must be a meta-entry. Mark sentinel so we don't
        // re-run post_install on every entrypoint pass.
        sentinel::mark(entry_kind_str(&entry.kind), entry.key, "meta", None)?;
    }

    // Post-install runs once per install, gated by a separate `<key>.post`
    // sentinel. Without this gate, every entrypoint cycle would re-run hooks
    // — fine for idempotent jq merges, wasteful (or wrong) for anything else.
    let kind_str = entry_kind_str(&entry.kind);
    if !entry.post_install.is_empty() && !sentinel::post_install_done(kind_str, entry.key) {
        for cmd in entry.post_install {
            run_post_install(entry.key, cmd)
                .await
                .with_context(|| format!("post_install of '{}': {cmd}", entry.key))?;
        }
        sentinel::mark_post_install(kind_str, entry.key)?;
    }

    Ok(())
}

/// Outcome of `install_many` — completed and failed lists. We collect failures
/// instead of bailing on the first one so a single broken handler (e.g. nvm
/// network blip) doesn't prevent every other unrelated tool from installing.
/// The caller surfaces the failed list to the user (banner at end of run) so
/// they know exactly what to retry.
#[derive(Debug, Default)]
pub struct InstallSummary {
    pub completed: Vec<String>,
    pub failed: Vec<(String, String)>,
}

/// Install a list of keys, resolving each one's dependencies. Used by the
/// container entrypoint and by the wizard's reconfigure flow. Top-level
/// errors are collected, not propagated — siblings keep installing. A dep
/// failure still kills its dependent (cascade), which is intentional: ts
/// can't install if node failed.
pub async fn install_many(catalog: &Catalog, keys: &[String]) -> InstallSummary {
    let mut visited = HashSet::new();
    let mut summary = InstallSummary::default();
    for key in keys {
        match install_with_deps(catalog, key, &mut visited).await {
            Ok(()) => summary.completed.push(key.clone()),
            Err(e) => summary.failed.push((key.clone(), format!("{e:#}"))),
        }
    }
    summary
}

fn entry_kind_str(kind: &Kind) -> &'static str {
    match kind {
        Kind::Cli => "cli",
        Kind::Tool => "tools",
        Kind::Plugin => "plugins",
    }
}

async fn run_post_install(key: &str, cmd: &str) -> Result<()> {
    cliclack::log::info(format!("post_install ({key}): {cmd}")).ok();
    let status = tokio::process::Command::new("bash")
        .args(["-c", cmd])
        .env("PATH", crate::installer::handlers::enriched_path())
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("post_install command failed: {cmd}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::schema::{CatalogCli, CatalogPlugin, CatalogTool, ProjectMeta};

    fn empty() -> Catalog {
        Catalog {
            project: ProjectMeta::default(),
            clis: vec![],
            tools: vec![],
            plugins: vec![],
        }
    }

    fn tool(key: &str, install: Option<&str>, deps: &[&str], post: &[&str]) -> CatalogTool {
        CatalogTool {
            key: key.into(),
            name: None,
            category: "test".into(),
            default: false,
            supported_clis: vec!["*".into()],
            description: String::new(),
            install: install.map(String::from),
            dependencies: deps.iter().map(|s| s.to_string()).collect(),
            post_install: post.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn lookup_finds_entries_across_kinds() {
        let mut c = empty();
        c.clis.push(CatalogCli {
            key: "x".into(),
            name: "X".into(),
            description: "".into(),
            needs_keys: vec![],
            oauth_supported: false,
            bin: "x".into(),
            install: "npm:x".into(),
            dependencies: vec![],
            post_install: vec![],
        });
        c.tools.push(tool("y", Some("npm:y"), &[], &[]));
        c.plugins.push(CatalogPlugin {
            key: "z".into(),
            name: None,
            category: "".into(),
            default: false,
            supported_clis: vec!["*".into()],
            description: "".into(),
            install: Some("npm:z".into()),
            dependencies: vec![],
            post_install: vec![],
        });
        assert!(lookup(&c, "x").is_some());
        assert!(lookup(&c, "y").is_some());
        assert!(lookup(&c, "z").is_some());
        assert!(lookup(&c, "nope").is_none());
    }

    #[test]
    fn missing_key_is_a_clear_error() {
        // We don't actually call install (no docker / network) — just verify
        // the orchestrator's error path when a dep references a missing key.
        let c = empty();
        let mut visited = HashSet::new();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let err = rt.block_on(install_with_deps(&c, "ghost", &mut visited));
        assert!(err.is_err());
        let msg = format!("{:?}", err.unwrap_err());
        assert!(
            msg.contains("ghost"),
            "error should mention missing key, got: {msg}"
        );
    }
}

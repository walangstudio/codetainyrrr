pub mod apt;
pub mod corepack;
pub mod git_clone;
pub mod github_release;
pub mod go_lang;
pub mod marketplace;
pub mod merge_json;
pub mod npm;
pub mod nvm;
pub mod python;
pub mod sdkman;
pub mod shell;
pub mod uv;

use anyhow::{Context, Result};
use tokio::process::Command;

/// Expand `~/` and `$HOME/` prefixes to the actual home directory.
pub(crate) fn expand_home(path: &str) -> Result<String> {
    let home = dirs::home_dir().context("could not determine home directory")?;
    if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("$HOME/")) {
        return Ok(home.join(rest).to_string_lossy().into_owned());
    }
    if path == "~" || path == "$HOME" {
        return Ok(home.to_string_lossy().into_owned());
    }
    Ok(path.to_owned())
}

/// Build a PATH that includes every directory tools install into. Re-resolved
/// each time so dirs created earlier in the same orchestrator run (e.g. nvm
/// node bin) become available to later handlers without restarting.
pub(crate) fn enriched_path() -> String {
    let home = dirs::home_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/home/dev".into());

    let mut extras: Vec<String> = vec![
        format!("{home}/.local/bin"),
        format!("{home}/.cargo/bin"),
        format!("{home}/.deno/bin"),
        format!("{home}/.bun/bin"),
        format!("{home}/.dotnet"),
        format!("{home}/go/sdk/bin"),
        format!("{home}/.sdkman/candidates/java/current/bin"),
    ];

    // nvm puts node under ~/.nvm/versions/node/<version>/bin — version dir
    // is unknown until install completes, so glob each time.
    if let Ok(entries) = glob::glob(&format!("{home}/.nvm/versions/node/*/bin")) {
        for e in entries.flatten() {
            if e.is_dir() {
                extras.push(e.to_string_lossy().into_owned());
            }
        }
    }

    let current = std::env::var("PATH").unwrap_or_default();
    format!("{}:{current}", extras.join(":"))
}

/// Find `program` in `path` (colon-separated). Returns absolute path or None.
/// Required because Rust's `Command::new("X")` does its PATH lookup using the
/// *parent* process's PATH (via posix_spawnp), so binaries installed mid-run
/// — like npm after nvm:lts — aren't visible even when we set .env("PATH",...)
/// on the child.
pub(crate) fn resolve_in_path(program: &str, path: &str) -> Option<std::path::PathBuf> {
    if program.contains('/') {
        let p = std::path::PathBuf::from(program);
        return p.is_file().then_some(p);
    }
    for dir in path.split(':').filter(|s| !s.is_empty()) {
        let candidate = std::path::Path::new(dir).join(program);
        if candidate.is_file() { return Some(candidate); }
    }
    None
}

/// Run a shell command. Resolves `program` against the enriched PATH so
/// freshly-installed binaries (npm via nvm, claude via its installer, etc.)
/// are reachable. Wraps spawn failures with the program name + PATH so a
/// missing binary doesn't surface as a bare "os error 2".
pub(crate) async fn run_cmd(program: &str, args: &[&str]) -> Result<()> {
    let path = enriched_path();
    let resolved = resolve_in_path(program, &path)
        .ok_or_else(|| anyhow::anyhow!("'{program}' not found in PATH={path}"))?;
    let status = Command::new(&resolved)
        .args(args)
        .env("PATH", &path)
        .status()
        .await
        .with_context(|| format!("could not spawn '{}'", resolved.display()))?;
    if !status.success() {
        anyhow::bail!("{program} {} exited with {status}", args.join(" "));
    }
    Ok(())
}

/// Run a shell snippet via bash -c.
pub(crate) async fn run_sh(script: &str) -> Result<()> {
    let path = enriched_path();
    let status = Command::new("bash")
        .args(["-c", script])
        .env("PATH", &path)
        .status()
        .await
        .with_context(|| format!("could not spawn 'bash' (PATH={path})"))?;
    if !status.success() {
        anyhow::bail!("shell script exited with {status}");
    }
    Ok(())
}

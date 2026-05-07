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

/// Run a shell command, streaming stdout/stderr, returning error if non-zero.
pub(crate) async fn run_cmd(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("{program} {} exited with {status}", args.join(" "));
    }
    Ok(())
}

/// Run a shell snippet via bash -c.
pub(crate) async fn run_sh(script: &str) -> Result<()> {
    let status = Command::new("bash")
        .args(["-c", script])
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("shell script exited with {status}");
    }
    Ok(())
}

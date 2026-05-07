pub mod apt;
pub mod corepack;
pub mod git_clone;
pub mod github_release;
pub mod go_lang;
pub mod marketplace;
pub mod npm;
pub mod nvm;
pub mod python;
pub mod sdkman;
pub mod shell;
pub mod uv;
pub mod wire_ccstatusline;

use anyhow::Result;
use tokio::process::Command;

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

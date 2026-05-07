pub mod marketplace;
pub mod npm;
pub mod shell;
pub mod uv;

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

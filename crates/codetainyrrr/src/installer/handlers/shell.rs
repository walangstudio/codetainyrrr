use super::run_sh;
use crate::installer::{async_trait, InstallStatus, Installer};
use anyhow::Result;

/// Handles raw shell-pipe specs: `curl -fsSL <url> | bash` and similar.
pub struct ShellPipeHandler;

#[async_trait]
impl Installer for ShellPipeHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        run_sh(spec).await
    }

    async fn uninstall(&self, _key: &str, _spec: &str) -> Result<()> {
        // shell-pipe installs have opaque uninstall paths; mark sentinel removed and warn.
        eprintln!("warn: no automatic uninstall for shell-pipe installs — sentinel removed, binary may remain");
        Ok(())
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

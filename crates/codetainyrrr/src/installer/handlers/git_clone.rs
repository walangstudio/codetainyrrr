/// Handler for `git:<url>:<install_to>` specs.
use anyhow::{bail, Result};
use async_trait::async_trait;

use super::{expand_home, run_sh};
use crate::installer::{InstallStatus, Installer};

pub struct GitCloneHandler;

#[async_trait]
impl Installer for GitCloneHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let rest = spec.strip_prefix("git:").unwrap_or(spec);
        let parts: Vec<&str> = rest.splitn(2, ':').collect();
        if parts.len() != 2 {
            bail!("git: spec must be git:<url>:<install_to>, got: {spec}");
        }
        let url = parts[0];
        let dest = expand_home(parts[1])?;

        run_sh(&format!("git clone --depth=1 {url} {dest:?}")).await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let rest = spec.strip_prefix("git:").unwrap_or(spec);
        if let Some(raw_dest) = rest.splitn(2, ':').nth(1) {
            let dest = expand_home(raw_dest)?;
            run_sh(&format!("rm -rf {dest:?}")).await?;
        }
        Ok(())
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

use anyhow::Result;
use async_trait::async_trait;

use super::run_cmd;
use crate::installer::{InstallStatus, Installer};

pub struct CorepackHandler;

#[async_trait]
impl Installer for CorepackHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let package = spec.strip_prefix("corepack:").unwrap_or(spec);
        run_cmd("corepack", &["prepare", &format!("{package}@latest"), "--activate"]).await
    }

    async fn uninstall(&self, _key: &str, _spec: &str) -> Result<()> {
        Ok(())
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

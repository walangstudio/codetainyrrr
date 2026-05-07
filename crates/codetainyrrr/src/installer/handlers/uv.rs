use super::run_cmd;
use crate::installer::{async_trait, InstallStatus, Installer};
use anyhow::Result;

pub struct UvHandler;

#[async_trait]
impl Installer for UvHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let package = spec.strip_prefix("uv:").unwrap_or(spec);
        run_cmd("uv", &["tool", "install", package]).await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let package = spec.strip_prefix("uv:").unwrap_or(spec);
        run_cmd("uv", &["tool", "uninstall", package]).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

use anyhow::Result;
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct AptHandler;

#[async_trait]
impl Installer for AptHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let packages = spec.strip_prefix("apt:").unwrap_or(spec);
        run_sh(&format!(
            "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y {packages}"
        ))
        .await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let packages = spec.strip_prefix("apt:").unwrap_or(spec);
        run_sh(&format!("sudo apt-get remove -y {packages}")).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

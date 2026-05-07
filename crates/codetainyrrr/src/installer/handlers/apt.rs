use anyhow::Result;
use async_trait::async_trait;
use tokio::process::Command;

use crate::installer::{InstallStatus, Installer};

pub struct AptHandler;

#[async_trait]
impl Installer for AptHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let packages: Vec<&str> = spec
            .strip_prefix("apt:")
            .unwrap_or(spec)
            .split_whitespace()
            .collect();
        apt_get(&["install", "-y"], &packages).await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let packages: Vec<&str> = spec
            .strip_prefix("apt:")
            .unwrap_or(spec)
            .split_whitespace()
            .collect();
        apt_get(&["remove", "-y"], &packages).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

async fn apt_get(sub_args: &[&str], packages: &[&str]) -> Result<()> {
    let mut args = vec!["apt-get"];
    args.extend_from_slice(sub_args);
    args.extend_from_slice(packages);

    let status = Command::new("sudo")
        .env("DEBIAN_FRONTEND", "noninteractive")
        .args(&args)
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("apt-get {:?} exited with {status}", sub_args);
    }
    Ok(())
}

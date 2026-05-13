use super::run_cmd;
use crate::installer::{async_trait, InstallStatus, Installer};
use anyhow::Result;

pub struct NpmHandler;

#[async_trait]
impl Installer for NpmHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let packages = spec.strip_prefix("npm:").unwrap_or(spec);
        let args: Vec<&str> = packages.split_whitespace().collect();
        let mut cmd_args = vec!["install", "-g"];
        cmd_args.extend(args.iter().copied());
        run_cmd("npm", &cmd_args).await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let packages = spec.strip_prefix("npm:").unwrap_or(spec);
        let args: Vec<&str> = packages.split_whitespace().collect();
        let mut cmd_args = vec!["uninstall", "-g"];
        cmd_args.extend(args.iter().copied());
        run_cmd("npm", &cmd_args).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

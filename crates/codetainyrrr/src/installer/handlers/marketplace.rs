/// marketplace:<owner/repo>:<plugin-name>[:<marketplace-name>]
use super::run_cmd;
use crate::installer::{async_trait, InstallStatus, Installer};
use anyhow::{bail, Result};

pub struct MarketplaceHandler;

fn parse_spec(spec: &str) -> Result<(String, String, String)> {
    let rest = spec.strip_prefix("marketplace:").unwrap_or(spec);
    let parts: Vec<&str> = rest.splitn(3, ':').collect();
    if parts.len() < 2 {
        bail!("invalid marketplace spec: {spec}");
    }
    let repo   = parts[0].to_string();
    let plugin = parts[1].to_string();
    let mkt    = parts.get(2).copied().unwrap_or(parts[1]).to_string();
    Ok((repo, plugin, mkt))
}

#[async_trait]
impl Installer for MarketplaceHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let (repo, plugin, mkt) = parse_spec(spec)?;
        // claude plugin marketplace add <owner/repo>
        run_cmd("claude", &["plugin", "marketplace", "add", &repo]).await?;
        // claude plugin install <plugin>@<mkt-name>
        let plugin_ref = format!("{plugin}@{mkt}");
        run_cmd("claude", &["plugin", "install", &plugin_ref]).await?;
        Ok(())
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let (_repo, plugin, _mkt) = parse_spec(spec)?;
        run_cmd("claude", &["plugin", "uninstall", &plugin]).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

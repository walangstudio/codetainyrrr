/// Dispatch an install spec string to the correct handler.
///
/// Spec formats (mirrors entrypoint.sh _install_from_spec):
///   npm:<packages>                   → NpmHandler
///   uv:<package>                     → UvHandler
///   marketplace:<repo>:<plugin>[:<mkt>] → MarketplaceHandler
///   curl -fsSL <url> | bash          → ShellPipeHandler (raw shell)
///   <anything else>                  → ShellHandler
use anyhow::{bail, Result};

use super::handlers::{
    marketplace::MarketplaceHandler, npm::NpmHandler, shell::ShellPipeHandler,
    uv::UvHandler,
};
use super::{InstallStatus, Installer};
use crate::installer::sentinel;

pub enum Kind {
    Cli,
    Tool,
    Plugin,
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Cli    => "cli",
            Self::Tool   => "tools",
            Self::Plugin => "plugins",
        }
    }
}

pub async fn install(kind: Kind, key: &str, spec: &str) -> Result<()> {
    if sentinel::is_installed(kind.as_str(), key) {
        return Ok(());
    }
    let handler = handler_for(spec)?;
    handler.install(key, spec).await?;
    sentinel::mark(kind.as_str(), key, spec, None)?;
    Ok(())
}

pub async fn uninstall(kind: Kind, key: &str, spec: &str) -> Result<()> {
    let handler = handler_for(spec)?;
    handler.uninstall(key, spec).await?;
    sentinel::remove(kind.as_str(), key)?;
    Ok(())
}

pub async fn status(kind: Kind, key: &str) -> Result<InstallStatus> {
    if sentinel::is_installed(kind.as_str(), key) {
        let v = sentinel::read(kind.as_str(), key).and_then(|s| s.version);
        Ok(InstallStatus::Installed { version: v })
    } else {
        Ok(InstallStatus::Missing)
    }
}

fn handler_for(spec: &str) -> Result<Box<dyn Installer>> {
    if spec.starts_with("npm:") {
        return Ok(Box::new(NpmHandler));
    }
    if spec.starts_with("uv:") {
        return Ok(Box::new(UvHandler));
    }
    if spec.starts_with("marketplace:") {
        return Ok(Box::new(MarketplaceHandler));
    }
    if spec.contains("| bash") || spec.contains("| sh") || spec.starts_with("curl") {
        return Ok(Box::new(ShellPipeHandler));
    }
    bail!("No handler for install spec: {spec}")
}

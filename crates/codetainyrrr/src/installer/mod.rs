pub mod handlers;
pub mod orchestrator;
pub mod registry;
pub mod sentinel;

use anyhow::Result;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum InstallStatus {
    Installed { version: Option<String> },
    Missing,
    NeedsUpdate { current: String, wanted: String },
}

impl fmt::Display for InstallStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Installed { version: Some(v) } => write!(f, "installed ({v})"),
            Self::Installed { version: None }    => write!(f, "installed"),
            Self::Missing                        => write!(f, "missing"),
            Self::NeedsUpdate { current, .. }   => write!(f, "outdated ({current})"),
        }
    }
}

/// Every install handler implements this trait.
#[async_trait::async_trait]
pub trait Installer: Send + Sync {
    async fn install(&self, key: &str, spec: &str) -> Result<()>;
    async fn uninstall(&self, key: &str, spec: &str) -> Result<()>;
    async fn status(&self, key: &str) -> Result<InstallStatus>;
}

// Re-export async_trait so handlers don't need to add the dep themselves.
pub use async_trait::async_trait;

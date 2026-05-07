use anyhow::Result;
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct NvmHandler;

#[async_trait]
impl Installer for NvmHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let version = spec.strip_prefix("nvm:").unwrap_or("lts");
        run_sh(&format!(
            r#"
            export NVM_DIR="${{HOME}}/.nvm"
            if [ ! -f "$NVM_DIR/nvm.sh" ]; then
                curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
            fi
            . "$NVM_DIR/nvm.sh"
            nvm install {version}
            nvm alias default {version}
            "#
        ))
        .await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let version = spec.strip_prefix("nvm:").unwrap_or("lts");
        run_sh(&format!(
            r#"
            export NVM_DIR="${{HOME}}/.nvm"
            [ -f "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm uninstall {version} || true
            "#
        ))
        .await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

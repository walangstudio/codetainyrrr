use anyhow::Result;
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct SdkmanHandler;

#[async_trait]
impl Installer for SdkmanHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let package = spec.strip_prefix("sdkman:").unwrap_or(spec);
        run_sh(&format!(
            r#"
            set -e
            export SDKMAN_DIR="${{HOME}}/.sdkman"
            # The sdkman installer refuses to run if SDKMAN_DIR exists, even if
            # it's an empty stub (Dockerfile pre-creates dev-owned home dirs).
            # Treat 'dir without bin/sdkman-init.sh' as broken state, clear it.
            if [ ! -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
                rm -rf "$SDKMAN_DIR"
                curl -fsSL https://get.sdkman.io | bash
            fi
            . "$SDKMAN_DIR/bin/sdkman-init.sh"
            sdk install {package}
            "#
        ))
        .await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let package = spec.strip_prefix("sdkman:").unwrap_or(spec);
        run_sh(&format!(
            r#"
            export SDKMAN_DIR="${{HOME}}/.sdkman"
            [ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ] && . "$SDKMAN_DIR/bin/sdkman-init.sh" && sdk uninstall {package} || true
            "#
        ))
        .await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

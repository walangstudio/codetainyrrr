use anyhow::Result;
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct GoHandler;

#[async_trait]
impl Installer for GoHandler {
    async fn install(&self, _key: &str, _spec: &str) -> Result<()> {
        run_sh(
            r#"
            VERSION=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)
            ARCHIVE="${VERSION}.linux-amd64.tar.gz"
            curl -fsSL "https://go.dev/dl/${ARCHIVE}" -o "/tmp/${ARCHIVE}"
            mkdir -p "$HOME/go/sdk"
            tar -C "$HOME/go/sdk" --strip-components=1 -xzf "/tmp/${ARCHIVE}"
            rm -f "/tmp/${ARCHIVE}"
            "$HOME/go/sdk/bin/go" version
        "#,
        )
        .await
    }

    async fn uninstall(&self, _key: &str, _spec: &str) -> Result<()> {
        run_sh("rm -rf \"$HOME/go/sdk\"").await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

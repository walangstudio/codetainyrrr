use anyhow::Result;
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct NvmHandler;

/// Translate user-facing version into the form `nvm install` accepts.
///   "lts"      → "--lts"   (special, otherwise `nvm install lts` errors)
///   "lts/*"    → "--lts"
///   "20", "v20", "20.1.0" → pass through as-is
fn to_nvm_install_arg(v: &str) -> String {
    match v {
        "lts" | "lts/*" => "--lts".into(),
        other           => other.into(),
    }
}

fn to_nvm_alias_target(v: &str) -> String {
    // `nvm alias default` accepts "lts/*" or a concrete version, but not "--lts".
    match v {
        "lts" => "lts/*".into(),
        other => other.into(),
    }
}

#[async_trait]
impl Installer for NvmHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let version = spec.strip_prefix("nvm:").unwrap_or("lts");
        let install_arg = to_nvm_install_arg(version);
        let alias_arg   = to_nvm_alias_target(version);
        // `set -e` so any step failing aborts. `node --version` at the end is
        // the real success gate — without it, nvm warning-but-exit-0 would
        // silently leave us with no node.
        run_sh(&format!(
            r#"
            set -e
            export NVM_DIR="${{HOME}}/.nvm"
            if [ ! -f "$NVM_DIR/nvm.sh" ]; then
                curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
            fi
            . "$NVM_DIR/nvm.sh"
            nvm install {install_arg}
            nvm alias default '{alias_arg}'
            nvm use default
            node --version
            npm --version
            "#
        ))
        .await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let version = spec.strip_prefix("nvm:").unwrap_or("lts");
        let target = to_nvm_alias_target(version);
        run_sh(&format!(
            r#"
            export NVM_DIR="${{HOME}}/.nvm"
            [ -f "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm uninstall '{target}' || true
            "#
        ))
        .await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

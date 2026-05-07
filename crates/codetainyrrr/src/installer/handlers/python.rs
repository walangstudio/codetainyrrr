/// Handler for `python:tools` — installs uv, then common Python dev tools via uv.
use anyhow::Result;
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct PythonHandler;

const PYTHON_TOOLS: &[&str] = &["poetry", "pipenv", "black", "ruff", "mypy"];

#[async_trait]
impl Installer for PythonHandler {
    async fn install(&self, _key: &str, _spec: &str) -> Result<()> {
        run_sh(&format!(
            r#"
            if ! command -v uv >/dev/null 2>&1; then
                curl -LsSf https://astral.sh/uv/install.sh | sh
            fi
            export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
            {tool_installs}
            "#,
            tool_installs = PYTHON_TOOLS
                .iter()
                .map(|t| format!("uv tool install {t}"))
                .collect::<Vec<_>>()
                .join("\n            ")
        ))
        .await
    }

    async fn uninstall(&self, _key: &str, _spec: &str) -> Result<()> {
        run_sh(&format!(
            r#"
            export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
            {tool_uninstalls}
            "#,
            tool_uninstalls = PYTHON_TOOLS
                .iter()
                .map(|t| format!("uv tool uninstall {t} 2>/dev/null || true"))
                .collect::<Vec<_>>()
                .join("\n            ")
        ))
        .await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

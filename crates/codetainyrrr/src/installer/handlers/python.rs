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

            # Debian only ships python3 — every script that does `#!/usr/bin/env python`
            # is broken without this. Symlink instead of installing python-is-python3
            # (apt) so we don't need sudo for it.
            mkdir -p "$HOME/.local/bin"
            if ! command -v python >/dev/null 2>&1; then
                ln -sf "$(command -v python3)" "$HOME/.local/bin/python"
            fi
            if ! command -v pip >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
                ln -sf "$(command -v pip3)" "$HOME/.local/bin/pip"
            fi
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

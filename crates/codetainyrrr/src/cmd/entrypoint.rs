/// Container entrypoint: reads INSTALL_TOOLS / INSTALL_PLUGINS / CODING_CLI from env,
/// installs each via the registry (idempotent via sentinels), then execs zsh.
use anyhow::Result;
use indicatif::{ProgressBar, ProgressStyle};
use std::time::Duration;

use crate::config::loader;
use crate::installer::registry::{self, Kind};

pub async fn run(_reconcile: bool, daemon: bool) -> Result<()> {
    let root = crate::config::locate_root();
    let cfg = loader::load(&root)?;

    let coding_cli      = std::env::var("CODING_CLI").unwrap_or_else(|_| "claude".to_string());
    let install_tools   = std::env::var("INSTALL_TOOLS").unwrap_or_default();
    let install_plugins = std::env::var("INSTALL_PLUGINS").unwrap_or_default();

    // Install CLI
    if let Some(cli_entry) = cfg.catalog.clis.iter().find(|c| c.key == coding_cli) {
        install_one("cli", &cli_entry.key, &cli_entry.install, Kind::Cli).await?;
    }

    // Install tools
    let tool_keys: Vec<&str> = install_tools.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
    for key in &tool_keys {
        if let Some(tool) = cfg.catalog.tools.iter().find(|t| t.key.as_str() == *key) {
            if let Some(spec) = &tool.install {
                install_one("tool", key, spec, Kind::Tool).await?;
            } else {
                eprintln!("warn: tool '{key}' has no install spec in catalog — skipping");
            }
        } else {
            eprintln!("warn: tool '{key}' not found in catalog — skipping");
        }
    }

    // Install plugins
    let plugin_keys: Vec<&str> = install_plugins.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
    for key in &plugin_keys {
        if let Some(plugin) = cfg.catalog.plugins.iter().find(|p| p.key.as_str() == *key) {
            if let Some(spec) = &plugin.install {
                install_one("plugin", key, spec, Kind::Plugin).await?;
            }
        }
    }

    if daemon {
        // Write ready file and sleep forever
        let _ = std::fs::write("/tmp/codetainyrrr.ready", "1");
        loop {
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    }

    // exec zsh as pid 1 (Linux/macOS only — the binary only runs as a container entrypoint)
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let err = std::process::Command::new("zsh").exec();
        return Err(anyhow::anyhow!("exec zsh: {err}"));
    }
    #[cfg(not(unix))]
    anyhow::bail!("entrypoint is only supported on Linux/macOS")
}

async fn install_one(kind_label: &str, key: &str, spec: &str, kind: Kind) -> Result<()> {
    use crate::installer::sentinel;
    if sentinel::is_installed(kind.as_str(), key) {
        return Ok(());
    }
    let pb = ProgressBar::new_spinner();
    pb.enable_steady_tick(Duration::from_millis(80));
    pb.set_style(
        ProgressStyle::with_template("  {spinner:.cyan} {msg}")
            .unwrap()
            .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]),
    );
    pb.set_message(format!("installing {kind_label}: {key}"));
    let result = registry::install(kind, key, spec).await;
    match result {
        Ok(()) => {
            pb.finish_with_message(format!("✓ {kind_label}: {key}"));
            Ok(())
        }
        Err(e) => {
            pb.finish_with_message(format!("✗ {kind_label}: {key} — {e}"));
            Err(e)
        }
    }
}


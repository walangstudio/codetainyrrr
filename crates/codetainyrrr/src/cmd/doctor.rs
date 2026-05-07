use anyhow::Result;

use crate::config::loader;
use crate::installer::{registry::{self, Kind}, InstallStatus};

pub async fn run() -> Result<()> {
    let root = std::env::current_dir()?;
    let cfg = loader::load(&root)?;

    println!("  {:<28} {:<12} {}", "Item", "Kind", "Status");
    println!("  {}", "─".repeat(60));

    // CLIs
    for item in &cfg.catalog.clis {
        let s = registry::status(Kind::Cli, &item.key).await?;
        print_row(&item.key, "cli", &s);
    }
    println!();

    // Tools
    for item in &cfg.catalog.tools {
        let s = registry::status(Kind::Tool, &item.key).await?;
        print_row(&item.key, "tool", &s);
    }
    println!();

    // Plugins
    for item in &cfg.catalog.plugins {
        let s = registry::status(Kind::Plugin, &item.key).await?;
        print_row(&item.key, "plugin", &s);
    }

    Ok(())
}

fn print_row(key: &str, kind: &str, status: &InstallStatus) {
    let indicator = match status {
        InstallStatus::Installed { .. }    => "✓",
        InstallStatus::Missing             => " ",
        InstallStatus::NeedsUpdate { .. }  => "↑",
    };
    println!("  [{indicator}] {key:<26} {kind:<12} {status}");
}

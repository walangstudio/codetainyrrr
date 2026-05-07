use anyhow::Result;
use console::style;

use crate::config::loader;
use crate::installer::{registry::{self, Kind}, InstallStatus};

pub async fn run() -> Result<()> {
    let root = std::env::current_dir()?;
    let cfg = loader::load(&root)?;

    header("AI CLIs");
    for item in &cfg.catalog.clis {
        let s = registry::status(Kind::Cli, &item.key).await?;
        row(&item.key, &item.description, &s);
    }

    header("Tools");
    let mut last_cat = String::new();
    for item in &cfg.catalog.tools {
        if item.category != last_cat {
            println!("  {}", style(format!("── {} ──", item.category)).dim());
            last_cat = item.category.clone();
        }
        let s = registry::status(Kind::Tool, &item.key).await?;
        row(&item.key, &item.description, &s);
    }

    header("Plugins");
    for item in &cfg.catalog.plugins {
        let s = registry::status(Kind::Plugin, &item.key).await?;
        row(&item.key, &item.description, &s);
    }

    Ok(())
}

fn header(title: &str) {
    println!();
    println!("  {}", style(title).bold().underlined());
    println!("  {}", style(format!("{:<24} {:<40} {}", "key", "description", "status")).dim());
    println!("  {}", style("─".repeat(72)).dim());
}

fn row(key: &str, description: &str, status: &InstallStatus) {
    let (icon, key_styled, status_styled) = match status {
        InstallStatus::Installed { version: Some(v) } => (
            style("✓").green().bold().to_string(),
            style(key).green().to_string(),
            style(format!("installed ({v})")).green().dim().to_string(),
        ),
        InstallStatus::Installed { version: None } => (
            style("✓").green().bold().to_string(),
            style(key).green().to_string(),
            style("installed").green().dim().to_string(),
        ),
        InstallStatus::Missing => (
            style("·").dim().to_string(),
            style(key).dim().to_string(),
            style("not installed").dim().to_string(),
        ),
        InstallStatus::NeedsUpdate { current, .. } => (
            style("↑").yellow().bold().to_string(),
            style(key).yellow().to_string(),
            style(format!("update available (current: {current})")).yellow().to_string(),
        ),
    };

    let desc_trimmed = if description.len() > 38 {
        format!("{}…", &description[..37])
    } else {
        description.to_string()
    };

    println!(
        "  {icon} {key_styled:<24} {desc:<40} {status}",
        desc = style(desc_trimmed).dim(),
        status = status_styled,
    );
}

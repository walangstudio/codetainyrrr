use anyhow::{bail, Result};

use crate::config::loader;
use crate::envfile::EnvFile;
use crate::installer::registry::{self, Kind};
use crate::installer::sentinel;

pub async fn add(key: String) -> Result<()> {
    let root = crate::config::locate_root();
    let cfg = loader::load(&root)?;
    let env_path = root.join(".env");
    let mut env = EnvFile::load(&env_path)?;
    let cli = if env.get("CODING_CLI").is_empty() {
        std::env::var("CODING_CLI").unwrap_or_default()
    } else {
        env.get("CODING_CLI").to_string()
    };

    let plugin = cfg
        .catalog
        .plugins
        .iter()
        .find(|p| p.key == key)
        .ok_or_else(|| anyhow::anyhow!("plugin '{key}' not found in catalog"))?;

    if !plugin.supports_cli(&cli) {
        bail!("plugin '{key}' does not support CLI '{cli}'");
    }

    let spec = plugin.install.as_deref()
        .ok_or_else(|| anyhow::anyhow!("plugin '{key}' has no install spec"))?;

    registry::install(Kind::Plugin, &key, spec).await?;

    // Update INSTALL_PLUGINS in .env
    let mut plugins = env.keys_csv("INSTALL_PLUGINS");
    if !plugins.contains(&key) {
        plugins.push(key.clone());
        env.set("INSTALL_PLUGINS", &plugins.join(","));
        env.write(&env_path, "# codetainyrrr configuration")?;
    }

    println!("Plugin '{key}' installed.");
    Ok(())
}

pub async fn remove(key: String) -> Result<()> {
    let root = crate::config::locate_root();
    let cfg = loader::load(&root)?;
    let env_path = root.join(".env");
    let mut env = EnvFile::load(&env_path)?;

    let plugin = cfg
        .catalog
        .plugins
        .iter()
        .find(|p| p.key == key)
        .ok_or_else(|| anyhow::anyhow!("plugin '{key}' not found in catalog"))?;

    let spec = plugin.install.as_deref()
        .ok_or_else(|| anyhow::anyhow!("plugin '{key}' has no install spec"))?;

    registry::uninstall(Kind::Plugin, &key, spec).await?;

    let mut plugins = env.keys_csv("INSTALL_PLUGINS");
    plugins.retain(|p| p != &key);
    env.set("INSTALL_PLUGINS", &plugins.join(","));
    env.write(&env_path, "# codetainyrrr configuration")?;

    println!("Plugin '{key}' removed.");
    Ok(())
}

pub async fn list() -> Result<()> {
    let root = crate::config::locate_root();
    let cfg = loader::load(&root)?;
    let env = EnvFile::load(&root.join(".env"))?;
    let cli_from_env = std::env::var("CODING_CLI").unwrap_or_default();
    let cli = if env.get("CODING_CLI").is_empty() { cli_from_env.as_str() } else { env.get("CODING_CLI") };
    let installed = sentinel::list_kind("plugins");

    println!("Plugins (CLI: {cli}):");
    for plugin in cfg.catalog.plugins.iter().filter(|p| p.supports_cli(cli)) {
        let status = if installed.contains(&plugin.key) { "✓" } else { " " };
        println!(
            "  [{status}] {key:<24} {desc}",
            key = plugin.key,
            desc = plugin.description,
        );
    }
    Ok(())
}

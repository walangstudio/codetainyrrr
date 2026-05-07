use anyhow::Result;
use tokio::process::Command;

use crate::envfile::EnvFile;
use crate::installer::sentinel;

pub async fn run(plugins_only: bool) -> Result<()> {
    let env = EnvFile::load(&std::env::current_dir()?.join(".env"))?;
    let container = env.get("CONTAINER_NAME").to_string();

    if plugins_only {
        reset_plugins(&container).await
    } else {
        reset_full(&container).await
    }
}

async fn reset_plugins(container: &str) -> Result<()> {
    println!("This will uninstall all plugins from container '{container}'.");
    print!("Type RESET to confirm: ");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    if input.trim() != "RESET" {
        println!("Aborted.");
        return Ok(());
    }

    let keys = sentinel::list_kind("plugins");
    for key in &keys {
        sentinel::remove("plugins", key)?;
        println!("  removed sentinel: {key}");
    }
    println!("Plugin sentinels cleared. Restart the container to re-install.");
    Ok(())
}

async fn reset_full(container: &str) -> Result<()> {
    let volume = format!("{container}_ct_home");
    println!("This will PERMANENTLY DELETE volume '{volume}' — all container home data lost.");
    print!("Type RESET to confirm: ");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    if input.trim() != "RESET" {
        println!("Aborted.");
        return Ok(());
    }

    // Stop container first if running
    let _ = Command::new("docker").args(["stop", container]).status().await;
    // Remove volume
    let status = Command::new("docker").args(["volume", "rm", &volume]).status().await?;
    if status.success() {
        println!("Volume '{volume}' removed.");
    } else {
        println!("Volume not found or already removed.");
    }
    Ok(())
}

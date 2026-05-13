use anyhow::Result;
use std::io::Write;
use std::process::Stdio;
use tokio::process::Command;

use crate::envfile::EnvFile;
use crate::installer::sentinel;

/// Print a prompt that lives on the same line as the user's reply, then read
/// stdin. `print!` is stdout-buffered, so without an explicit flush the prompt
/// stays invisible until *something else* triggers a flush — making `read_line`
/// look like it's hanging on a blank line.
fn prompt(text: &str) -> Result<String> {
    print!("{text}");
    std::io::stdout().flush()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    Ok(input)
}

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
    let input = prompt("Type RESET to confirm: ")?;
    if input.trim() != "RESET" {
        println!("Aborted.");
        return Ok(());
    }

    let keys = sentinel::list_kind("plugins");
    for key in &keys {
        sentinel::remove("plugins", key)?;
        // Clear post_install marker too so init steps re-run on next start.
        // Without this, install handler re-fires but post_install is skipped,
        // leaving plugin MCP wiring / settings.json patches missing.
        sentinel::remove_post("plugins", key)?;
        println!("  removed sentinel: {key}");
    }
    println!("Plugin sentinels cleared. Restart the container to re-install.");
    Ok(())
}

async fn reset_full(container: &str) -> Result<()> {
    let volume = format!("{container}_ct_home");
    println!("This will PERMANENTLY DELETE volume '{volume}' — all container home data lost.");
    let input = prompt("Type RESET to confirm: ")?;
    if input.trim() != "RESET" {
        println!("Aborted.");
        return Ok(());
    }

    // Stop container if running. Container absent is the normal case after a
    // prior reset — don't leak docker's "No such container" stderr to the user.
    let _ = Command::new("docker")
        .args(["stop", container])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await;
    // Remove volume
    let status = Command::new("docker")
        .args(["volume", "rm", &volume])
        .status()
        .await?;
    if status.success() {
        println!("Volume '{volume}' removed.");
    } else {
        println!("Volume not found or already removed.");
    }
    Ok(())
}

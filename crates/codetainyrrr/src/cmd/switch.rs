use anyhow::{bail, Result};

use crate::config::loader;
use crate::envfile::EnvFile;
use crate::installer::registry::{self, Kind};

pub async fn run(cli: String) -> Result<()> {
    let root = std::env::current_dir()?;
    let cfg = loader::load(&root)?;

    let env_path = root.join(".env");
    let mut env = EnvFile::load(&env_path)?;

    let valid = cfg.catalog.clis.iter().map(|c| c.key.as_str()).collect::<Vec<_>>();
    if !valid.contains(&cli.as_str()) {
        bail!("Unknown CLI '{cli}'. Valid options: {}", valid.join(", "));
    }

    let old_cli = env.get("CODING_CLI").to_string();
    if old_cli == cli {
        println!("Already using {cli}");
        return Ok(());
    }

    // Install new CLI if it has a spec
    if let Some(c) = cfg.catalog.clis.iter().find(|c| c.key == cli) {
        println!("Switching to {cli}...");
        registry::install(Kind::Cli, &cli, &c.install).await?;
    }

    env.set("CODING_CLI", &cli);
    let header = "# codetainyrrr configuration";
    env.write(&env_path, header)?;
    println!("Switched to {cli}. Restart the container to apply.");
    Ok(())
}

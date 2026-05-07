use anyhow::Result;
use tokio::process::Command;

use crate::envfile::EnvFile;

pub async fn run(extra_args: Vec<String>) -> Result<()> {
    let env = load_env()?;
    let container = env.get("CONTAINER_NAME");

    if is_running(container).await? {
        connect_to(container).await
    } else {
        start(container, &env, extra_args).await
    }
}

pub async fn stop() -> Result<()> {
    let env = load_env()?;
    let container = env.get("CONTAINER_NAME").to_string();
    let status = Command::new("docker")
        .args(["stop", &container])
        .status()
        .await?;
    if status.success() {
        println!("Stopped {container}");
    }
    Ok(())
}

pub async fn connect() -> Result<()> {
    let env = load_env()?;
    connect_to(env.get("CONTAINER_NAME")).await
}

async fn is_running(container: &str) -> Result<bool> {
    let out = Command::new("docker")
        .args(["ps", "-q", "--filter", &format!("name=^{container}$")])
        .output()
        .await?;
    Ok(!out.stdout.is_empty())
}

async fn connect_to(container: &str) -> Result<()> {
    let status = Command::new("docker")
        .args(["exec", "-it", container, "zsh"])
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("docker exec exited with {status}");
    }
    Ok(())
}

async fn start(container: &str, env: &EnvFile, extra_args: Vec<String>) -> Result<()> {
    let project_dir = env.get("PROJECT_DIR");
    let claude_dir  = env.get("CLAUDE_DIR");
    let image       = format!("{container}:latest");

    let mut args = vec![
        "run".to_string(), "--rm".to_string(), "-it".to_string(),
        "--name".to_string(), container.to_string(),
        "-v".to_string(), format!("{container}_ct_home:/root"),
        "-v".to_string(), format!("{project_dir}:/workspace"),
    ];

    if !claude_dir.is_empty() {
        args.push("-v".to_string());
        args.push(format!("{claude_dir}:/root/.claude:ro"));
    }

    // Forward known API keys as env vars
    for key in &["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "GEMINI_API_KEY"] {
        let val = env.get(key);
        if !val.is_empty() {
            args.push("-e".to_string());
            args.push(format!("{key}={val}"));
        }
    }

    // Forward INSTALL_TOOLS / INSTALL_PLUGINS / CODING_CLI for entrypoint
    for key in &["CODING_CLI", "INSTALL_TOOLS", "INSTALL_PLUGINS",
                 "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"] {
        let val = env.get(key);
        args.push("-e".to_string());
        args.push(format!("{key}={val}"));
    }

    args.extend(extra_args);
    args.push(image);

    let status = Command::new("docker").args(&args).status().await?;
    if !status.success() {
        anyhow::bail!("docker run exited with {status}");
    }
    Ok(())
}

fn load_env() -> Result<EnvFile> {
    let path = std::env::current_dir()?.join(".env");
    let env = EnvFile::load(&path)?;
    if env.get("CODING_CLI").is_empty() {
        anyhow::bail!(".env not found or CODING_CLI unset — run 'codetainyrrr setup' first");
    }
    Ok(env)
}

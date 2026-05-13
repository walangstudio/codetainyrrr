use anyhow::Result;
use tokio::process::Command;

use crate::config::loader;
use crate::envfile::EnvFile;

pub async fn run(rebuild: bool, extra_args: Vec<String>) -> Result<()> {
    let env = load_env()?;
    let cfg = loader::load(&crate::config::locate_root())?;
    let container = env.get("CONTAINER_NAME");

    if is_running(container).await? {
        connect_to(container).await
    } else {
        if rebuild {
            let _ = Command::new("docker")
                .args(["rmi", "-f", &cfg.catalog.project.image_tag])
                .status()
                .await;
        }
        ensure_image(&cfg.catalog.project.image_tag, &cfg.root).await?;
        start(
            container,
            &env,
            &cfg.catalog.project.image_tag,
            &cfg.root,
            extra_args,
        )
        .await
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

async fn image_exists(tag: &str) -> Result<bool> {
    let out = Command::new("docker")
        .args(["images", "-q", tag])
        .output()
        .await?;
    Ok(!out.stdout.is_empty())
}

/// Returns the image's creation timestamp, or `None` if the image doesn't exist
/// or docker can't be reached. Uses RFC 3339 / ISO 8601 from `docker inspect`.
async fn image_created_at(tag: &str) -> Result<Option<std::time::SystemTime>> {
    let out = Command::new("docker")
        .args(["image", "inspect", "--format", "{{.Created}}", tag])
        .output()
        .await?;
    if !out.status.success() {
        return Ok(None);
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        return Ok(None);
    }
    // RFC 3339 like "2026-05-08T12:34:56.789012345Z" — strip subseconds for
    // the simple parse path; chrono would be cleaner but adding a dep just for
    // this is overkill.
    Ok(parse_rfc3339(&s))
}

fn parse_rfc3339(s: &str) -> Option<std::time::SystemTime> {
    // Accept "YYYY-MM-DDTHH:MM:SS[.fffffffff]Z" or "...+00:00"
    let s = s.trim_end_matches('Z');
    let (date_time, _tz) = s.split_once('+').unwrap_or((s, ""));
    let (date, time) = date_time.split_once('T')?;
    let mut dp = date.split('-');
    let y: i64 = dp.next()?.parse().ok()?;
    let mo: u32 = dp.next()?.parse().ok()?;
    let d: u32 = dp.next()?.parse().ok()?;
    let time = time.split('.').next()?;
    let mut tp = time.split(':');
    let h: u64 = tp.next()?.parse().ok()?;
    let mi: u64 = tp.next()?.parse().ok()?;
    let sec: u64 = tp.next()?.parse().ok()?;
    let days_from_civil = |y: i64, m: u32, d: u32| -> i64 {
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = (y - era * 400) as u64;
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) as u64 + 2) / 5 + d as u64 - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146097 + doe as i64 - 719468
    };
    let days = days_from_civil(y, mo, d);
    let secs = (days * 86400) + (h * 3600 + mi * 60 + sec) as i64;
    if secs < 0 {
        return None;
    }
    Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs as u64))
}

/// Latest mtime across files that, if newer than the image, mean the image is
/// stale: Dockerfile, Cargo manifests/lock, and the binary's source tree.
fn latest_source_mtime(root: &std::path::Path) -> std::time::SystemTime {
    let mut max = std::time::UNIX_EPOCH;
    let bump = |p: &std::path::Path, max: &mut std::time::SystemTime| {
        if let Ok(m) = std::fs::metadata(p).and_then(|m| m.modified())
            && m > *max
        {
            *max = m;
        }
    };
    for f in &[
        "Dockerfile",
        "Cargo.toml",
        "Cargo.lock",
        "crates/codetainyrrr/Cargo.toml",
    ] {
        bump(&root.join(f), &mut max);
    }
    walk_max_mtime(&root.join("crates/codetainyrrr/src"), &mut max);
    max
}

fn walk_max_mtime(dir: &std::path::Path, max: &mut std::time::SystemTime) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_max_mtime(&path, max);
        } else if let Ok(m) = entry.metadata().and_then(|m| m.modified())
            && m > *max
        {
            *max = m;
        }
    }
}

/// True if the source tree has been touched after the image was built. Returns
/// false (don't rebuild) if anything is uncertain — better to skip rebuild
/// than to rebuild on every run.
async fn image_is_stale(tag: &str, root: &std::path::Path) -> Result<bool> {
    let Some(created) = image_created_at(tag).await? else {
        return Ok(false);
    };
    let latest = latest_source_mtime(root);
    Ok(latest > created)
}

/// Build the image if it doesn't exist locally OR if the source tree has been
/// modified since the image was built. The build context is the project root
/// (where Dockerfile lives). Without this check, `docker run` tries to pull
/// from a registry and fails with "pull access denied".
async fn ensure_image(tag: &str, root: &std::path::Path) -> Result<()> {
    let exists = image_exists(tag).await?;
    let stale = exists && image_is_stale(tag, root).await?;
    if exists && !stale {
        return Ok(());
    }

    let dockerfile = root.join("Dockerfile");
    if !dockerfile.exists() {
        if !exists {
            anyhow::bail!(
                "image '{tag}' not found locally and no Dockerfile at {} — \
                 either build the image manually or place a Dockerfile alongside catalog.json",
                dockerfile.display()
            );
        }
        return Ok(()); // image exists, no Dockerfile to rebuild from
    }
    if stale {
        println!(
            "Image '{tag}' is older than source — rebuilding from {} ...",
            dockerfile.display()
        );
    } else {
        println!(
            "Image '{tag}' not found — building from {} ...",
            dockerfile.display()
        );
    }
    let status = Command::new("docker")
        .args(["build", "-t", tag, "."])
        .current_dir(root)
        .status()
        .await?;
    if !status.success() {
        anyhow::bail!("docker build exited with {status}");
    }
    Ok(())
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

async fn start(
    container: &str,
    env: &EnvFile,
    image: &str,
    root: &std::path::Path,
    extra_args: Vec<String>,
) -> Result<()> {
    // Docker on Windows accepts `C:/path` mount syntax but chokes on `C:\path`
    // because the `\` ends up adjacent to the bind-mount `:` separator.
    // Normalize unconditionally — POSIX paths are unaffected.
    let project_dir = env.get("PROJECT_DIR").replace('\\', "/");
    let claude_dir = env.get("CLAUDE_DIR").replace('\\', "/");

    if project_dir.is_empty() {
        anyhow::bail!("PROJECT_DIR is empty in .env — run `setup` first");
    }

    let mut args = vec![
        "run".to_string(),
        "--rm".to_string(),
        "-it".to_string(),
        "--name".to_string(),
        container.to_string(),
        // Hostname inside the container shows up in the shell prompt; matching
        // the container name makes multi-container workflows readable.
        "--hostname".to_string(),
        container.to_string(),
        // The container runs as the `dev` user (entrypoint shim drops via
        // gosu). Mount the home volume at /home/dev — mounting at /root left
        // the actual home untouched and installs invisible across restarts.
        "-v".to_string(),
        format!("{container}_ct_home:/home/dev"),
        "-v".to_string(),
        format!("{project_dir}:/workspace"),
    ];

    // Bind-mount catalog.json + wizard.json so changes the user makes via
    // setup/reconfigure take effect on the next `run` without rebuilding the
    // image. Falls back to baked-in copies if the host paths are missing.
    let catalog_host = root.join("catalog.json");
    let wizard_host = root.join("wizard.json");
    let catalog_str = catalog_host.to_string_lossy().replace('\\', "/");
    let wizard_str = wizard_host.to_string_lossy().replace('\\', "/");
    if catalog_host.exists() {
        args.push("-v".into());
        args.push(format!("{catalog_str}:/etc/codetainyrrr/catalog.json:ro"));
    }
    if wizard_host.exists() {
        args.push("-v".into());
        args.push(format!("{wizard_str}:/etc/codetainyrrr/wizard.json:ro"));
    }

    if !claude_dir.is_empty() {
        args.push("-v".to_string());
        args.push(format!("{claude_dir}:/home/dev/.claude:ro"));
    }

    // BYO overrides (optional, set in .env via the wizard). Each is bind-
    // mounted RO to a staging path; entrypoint.sh copies them into the
    // container's home volume on first start (one-shot, marker-gated) so the
    // user gets an editable in-container copy seeded from their host file.
    // After that one-shot copy, the bind mount is dead weight — no in-container
    // process reads from /etc/codetainyrrr/user-*.{json,toml,zsh}. Container
    // edits live in the volume only; the host file is never modified.
    let byo_mounts: &[(&str, &str)] = &[
        (
            "CCSTATUSLINE_CONFIG",
            "/etc/codetainyrrr/user-ccstatusline.json",
        ),
        ("ZSH_EXTRA_CONFIG", "/etc/codetainyrrr/user-zshrc-extra.zsh"),
        ("STARSHIP_CONFIG", "/etc/codetainyrrr/user-starship.toml"),
    ];
    for (var, target) in byo_mounts {
        let host = env.get(var).replace('\\', "/");
        if !host.is_empty() && std::path::Path::new(&host).exists() {
            args.push("-v".to_string());
            args.push(format!("{host}:{target}:ro"));
        }
    }

    for key in &[
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "OPENROUTER_API_KEY",
        "GEMINI_API_KEY",
    ] {
        let val = env.get(key);
        if !val.is_empty() {
            args.push("-e".to_string());
            args.push(format!("{key}={val}"));
        }
    }

    for key in &[
        "CODING_CLI",
        "INSTALL_TOOLS",
        "INSTALL_PLUGINS",
        "GIT_AUTHOR_NAME",
        "GIT_AUTHOR_EMAIL",
    ] {
        let val = env.get(key);
        args.push("-e".to_string());
        args.push(format!("{key}={val}"));
    }

    args.extend(extra_args);
    args.push(image.to_string());

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
        anyhow::bail!(".env not found or CODING_CLI unset — run `setup` first");
    }
    Ok(env)
}

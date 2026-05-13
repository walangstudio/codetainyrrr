/// Container entrypoint: reads INSTALL_TOOLS / INSTALL_PLUGINS / CODING_CLI from env
/// and routes everything through the orchestrator so dependencies and
/// post_install hooks declared in catalog.json run automatically.
use anyhow::Result;
use std::time::Duration;

use crate::config::loader;
use crate::installer::orchestrator;

pub async fn run(_reconcile: bool, daemon: bool) -> Result<()> {
    let root = crate::config::locate_root();
    let cfg = loader::load(&root)?;

    // Tools install into well-known directories under $HOME, but the entrypoint
    // process doesn't source ~/.zshrc, so freshly-installed binaries aren't on
    // PATH for the next handler in the same run. Prepend the known dirs once.
    prepend_known_paths();

    let coding_cli      = std::env::var("CODING_CLI").unwrap_or_else(|_| cfg.catalog.project.default_cli.clone());
    let install_tools   = std::env::var("INSTALL_TOOLS").unwrap_or_default();
    let install_plugins = std::env::var("INSTALL_PLUGINS").unwrap_or_default();

    // Build a single ordered list: CLI, then tools, then plugins. The
    // orchestrator handles dependencies declared on each entry, so user-facing
    // order only needs to express priority for sibling entries.
    let mut keys: Vec<String> = Vec::new();
    if cfg.catalog.clis.iter().any(|c| c.key == coding_cli) {
        keys.push(coding_cli.clone());
    }
    keys.extend(install_tools.split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from));
    keys.extend(install_plugins.split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from));

    let summary = orchestrator::install_many(&cfg.catalog, &keys).await;
    print_summary_banner(&summary);

    if daemon {
        // Write ready file and sleep forever
        let _ = std::fs::write(&cfg.catalog.project.ready_file, "1");
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

/// Add common installer destination directories to PATH so subsequent handlers
/// in the same orchestrator run can invoke just-installed binaries (claude,
/// node via nvm, sdkman tools, deno, bun, dotnet, cargo, etc.).
fn prepend_known_paths() {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/dev".to_string());
    let nvm_node_bin = glob_first_dir(&format!("{home}/.nvm/versions/node/*/bin"));

    let extras: Vec<String> = [
        Some(format!("{home}/.local/bin")),
        Some(format!("{home}/.cargo/bin")),
        Some(format!("{home}/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin")),
        Some(format!("{home}/.deno/bin")),
        Some(format!("{home}/.bun/bin")),
        Some(format!("{home}/.dotnet")),
        Some(format!("{home}/go/sdk/bin")),
        Some(format!("{home}/.sdkman/candidates/java/current/bin")),
        nvm_node_bin,
    ].into_iter().flatten().collect();

    let current = std::env::var("PATH").unwrap_or_default();
    let new_path = format!("{}:{current}", extras.join(":"));
    // SAFETY: single-threaded at this point, before any handler spawns.
    unsafe { std::env::set_var("PATH", new_path); }
}

/// End-of-run banner. Always prints completed count; if anything failed,
/// surfaces each failure with the first line of its error and a one-line
/// retry hint. Going silent here would leave users wondering why `doctor`
/// shows half their picks missing.
fn print_summary_banner(summary: &crate::installer::orchestrator::InstallSummary) {
    use console::style;

    let n_ok   = summary.completed.len();
    let n_fail = summary.failed.len();

    println!();
    println!("  {}", style(format!("── Install summary: {n_ok} ok, {n_fail} failed ──")).bold());

    if !summary.failed.is_empty() {
        println!();
        println!("  {}", style("FAILED:").red().bold());
        for (key, err) in &summary.failed {
            // First line of the error chain — usually the root cause.
            let first = err.lines().next().unwrap_or("(no error message)");
            println!("    {} {}", style("✗").red(), style(key).red().bold());
            println!("      {}", style(first).dim());
        }
        println!();
        println!(
            "  {} Edit `.env` to drop these from INSTALL_TOOLS / INSTALL_PLUGINS,",
            style("→").yellow()
        );
        println!(
            "    or run `codetainyrrr reconfigure` to retry / pick different ones."
        );
        println!();
    }
}

fn glob_first_dir(pattern: &str) -> Option<String> {
    glob::glob(pattern).ok()?
        .filter_map(|e| e.ok())
        .find(|p| p.is_dir())
        .map(|p| p.to_string_lossy().into_owned())
}

// Spinner support kept here in case future installer paths want it; the
// orchestrator currently logs through cliclack.
#[allow(dead_code)]
async fn _install_one_with_spinner(kind_label: &str, key: &str, spec: &str, kind: crate::installer::registry::Kind) -> Result<()> {
    use crate::installer::registry;
    use crate::installer::sentinel;
    use indicatif::{ProgressBar, ProgressStyle};
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


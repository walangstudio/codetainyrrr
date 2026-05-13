mod cmd;
use codetainyrrr::*;

use anyhow::Result;
use clap::{Parser, Subcommand};

/// Brand at compile time. Defaults preserve the codetainyrrr identity but a
/// downstream project can rebuild with these env vars set to rebrand without
/// touching code. The runtime catalog.json's `project` block still drives all
/// behavior — these only theme `--help`.
const BIN_NAME:  &str = match option_env!("CT_BIN_NAME")  { Some(s) => s, None => "codetainyrrr" };
const BIN_ABOUT: &str = match option_env!("CT_BIN_ABOUT") { Some(s) => s, None => "AI coding container — setup, run, manage" };

#[derive(Parser)]
#[command(name = BIN_NAME, about = BIN_ABOUT, version)]
struct Cli {
    /// Directory containing catalog.json + wizard.json. Overrides
    /// CODETAINYRRR_CONFIG_ROOT and the default search path.
    #[arg(long, global = true, value_name = "DIR")]
    config_root: Option<std::path::PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the interactive setup wizard and write .env
    #[command(alias = "config")]
    Setup,
    /// Re-run wizard; reconcile installed vs new selections
    Reconfigure,
    /// Build image (if needed) and start the container
    Run {
        /// Force a fresh image build even if the tag already exists.
        /// Use after upgrading the codetainyrrr binary; not needed for
        /// catalog/wizard changes (those bind-mount live).
        #[arg(long)]
        rebuild: bool,
        #[arg(trailing_var_arg = true)]
        args: Vec<String>,
    },
    /// Stop the container
    Stop,
    /// Attach a new shell to a running container
    Connect,
    /// Switch to a different AI coding CLI
    Switch { cli: String },
    /// Add, remove, or list plugins
    Plugins {
        #[command(subcommand)]
        action: PluginAction,
    },
    /// Wipe container home volume (or just plugin sentinels with --plugins)
    Reset {
        #[arg(long)]
        plugins: bool,
    },
    /// Show installation status for every catalog entry
    Doctor,
    /// Run as container entrypoint (install tools, then exec shell)
    Entrypoint {
        #[arg(long)]
        reconcile: bool,
        #[arg(long)]
        daemon: bool,
    },
}

#[derive(Subcommand)]
enum PluginAction {
    /// Install a plugin by catalog key
    Add { key: String },
    /// Uninstall a plugin by catalog key
    Remove { key: String },
    /// List available plugins and their status
    List,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    if let Some(dir) = &cli.config_root {
        // Set the env var so locate_root() picks it up everywhere without
        // needing to thread an explicit path through every subcommand.
        // SAFETY: single-threaded at this point; no other code reads env yet.
        unsafe { std::env::set_var("CODETAINYRRR_CONFIG_ROOT", dir) };
    }

    // Bind sentinel directory to the project's data_dir_name (best-effort —
    // tolerate missing config so --help still works without catalog.json).
    let root = config::locate_root();
    if let Ok(cfg) = config::loader::load(&root) {
        installer::sentinel::set_dir_name(&cfg.catalog.project.data_dir_name);
    }

    match cli.command {
        Command::Setup               => cmd::setup::run(false).await,
        Command::Reconfigure         => cmd::setup::run(true).await,
        Command::Run { rebuild, args } => cmd::run::run(rebuild, args).await,
        Command::Stop                => cmd::run::stop().await,
        Command::Connect             => cmd::run::connect().await,
        Command::Switch { cli }      => cmd::switch::run(cli).await,
        Command::Plugins { action }  => match action {
            PluginAction::Add    { key } => cmd::plugins::add(key).await,
            PluginAction::Remove { key } => cmd::plugins::remove(key).await,
            PluginAction::List           => cmd::plugins::list().await,
        },
        Command::Reset { plugins }   => cmd::reset::run(plugins).await,
        Command::Doctor              => cmd::doctor::run().await,
        Command::Entrypoint { reconcile, daemon } => cmd::entrypoint::run(reconcile, daemon).await,
    }
}

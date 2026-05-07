mod cmd;
use codetainyrrr::*;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "codetainyrrr",
    about = "AI coding container — setup, run, manage",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the interactive setup wizard and write .env
    Setup,
    /// Re-run wizard; reconcile installed vs new selections
    Reconfigure,
    /// Build image (if needed) and start the container
    Run {
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
    match cli.command {
        Command::Setup               => cmd::setup::run(false).await,
        Command::Reconfigure         => cmd::setup::run(true).await,
        Command::Run { args }        => cmd::run::run(args).await,
        Command::Stop                => cmd::run::stop().await,
        Command::Connect             => cmd::run::connect().await,
        Command::Switch { cli }      => cmd::switch::run(cli).await,
        Command::Plugins { action }  => match action {
            PluginAction::Add    { key } => cmd::plugins::add(key).await,
            PluginAction::Remove { key } => cmd::plugins::remove(key).await,
            PluginAction::List          => cmd::plugins::list().await,
        },
        Command::Reset { plugins }   => cmd::reset::run(plugins).await,
        Command::Doctor              => cmd::doctor::run().await,
        Command::Entrypoint { reconcile, daemon } => cmd::entrypoint::run(reconcile, daemon).await,
    }
}

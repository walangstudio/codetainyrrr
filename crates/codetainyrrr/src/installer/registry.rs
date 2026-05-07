/// Dispatch an install spec string to the correct handler.
///
/// Spec formats:
///   npm:<packages>                      → NpmHandler
///   uv:<package>                        → UvHandler
///   nvm:<version>                       → NvmHandler
///   go:latest                           → GoHandler
///   sdkman:<package>                    → SdkmanHandler
///   corepack:<package>                  → CorepackHandler
///   gh:<owner/repo>:<asset_pattern>     → GithubReleaseHandler
///   git:<url>:<install_to>              → GitCloneHandler
///   apt:<packages>                      → AptHandler
///   python:tools                        → PythonHandler
///   merge-json:<path>:<cmd>             → MergeJsonHandler
///   marketplace:<repo>:<plugin>[:<mkt>] → MarketplaceHandler
///   curl -fsSL <url> | bash             → ShellPipeHandler
use anyhow::{bail, Result};

use super::handlers::{
    apt::AptHandler,
    corepack::CorepackHandler,
    git_clone::GitCloneHandler,
    github_release::GithubReleaseHandler,
    go_lang::GoHandler,
    marketplace::MarketplaceHandler,
    merge_json::MergeJsonHandler,
    npm::NpmHandler,
    nvm::NvmHandler,
    python::PythonHandler,
    sdkman::SdkmanHandler,
    shell::ShellPipeHandler,
    uv::UvHandler,
};
use super::{InstallStatus, Installer};
use crate::installer::sentinel;

pub enum Kind {
    Cli,
    Tool,
    Plugin,
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Cli    => "cli",
            Self::Tool   => "tools",
            Self::Plugin => "plugins",
        }
    }
}

pub async fn install(kind: Kind, key: &str, spec: &str) -> Result<()> {
    if sentinel::is_installed(kind.as_str(), key) {
        return Ok(());
    }
    let handler = handler_for(spec)?;
    handler.install(key, spec).await?;
    sentinel::mark(kind.as_str(), key, spec, None)?;
    Ok(())
}

pub async fn uninstall(kind: Kind, key: &str, spec: &str) -> Result<()> {
    let handler = handler_for(spec)?;
    handler.uninstall(key, spec).await?;
    sentinel::remove(kind.as_str(), key)?;
    Ok(())
}

pub async fn status(kind: Kind, key: &str) -> Result<InstallStatus> {
    if sentinel::is_installed(kind.as_str(), key) {
        let v = sentinel::read(kind.as_str(), key).and_then(|s| s.version);
        Ok(InstallStatus::Installed { version: v })
    } else {
        Ok(InstallStatus::Missing)
    }
}

fn handler_for(spec: &str) -> Result<Box<dyn Installer>> {
    if spec.starts_with("npm:")               { return Ok(Box::new(NpmHandler)); }
    if spec.starts_with("uv:")                { return Ok(Box::new(UvHandler)); }
    if spec.starts_with("nvm:")               { return Ok(Box::new(NvmHandler)); }
    if spec.starts_with("go:")                { return Ok(Box::new(GoHandler)); }
    if spec.starts_with("sdkman:")            { return Ok(Box::new(SdkmanHandler)); }
    if spec.starts_with("corepack:")          { return Ok(Box::new(CorepackHandler)); }
    if spec.starts_with("gh:")                { return Ok(Box::new(GithubReleaseHandler)); }
    if spec.starts_with("git:")               { return Ok(Box::new(GitCloneHandler)); }
    if spec.starts_with("apt:")               { return Ok(Box::new(AptHandler)); }
    if spec.starts_with("python:")            { return Ok(Box::new(PythonHandler)); }
    if spec.starts_with("merge-json:")          { return Ok(Box::new(MergeJsonHandler)); }
    if spec.starts_with("marketplace:")       { return Ok(Box::new(MarketplaceHandler)); }
    if spec.contains("| bash") || spec.contains("| sh") || spec.starts_with("curl") {
        return Ok(Box::new(ShellPipeHandler));
    }
    bail!("No handler for install spec: {spec}")
}

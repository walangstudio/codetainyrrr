/// Handler for `git:<url>:<install_to>` specs.
use anyhow::{bail, Result};
use async_trait::async_trait;

use super::{expand_home, run_sh};
use crate::installer::{InstallStatus, Installer};

pub struct GitCloneHandler;

#[async_trait]
impl Installer for GitCloneHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let (url, raw_dest) = split_url_dest(spec)?;
        let dest = expand_home(raw_dest)?;

        // Skip if dest already a populated git checkout — covers the case where
        // a previous run cloned but the sentinel was missing (mid-install crash,
        // wiped state dir, etc.). The orchestrator sentinel handles the happy
        // path; this is the recovery path.
        run_sh(&format!(
            r#"
            if [ -d {dest:?}/.git ]; then
                echo "git-clone: {dest} already a git checkout, skipping" >&2
                exit 0
            fi
            git clone --depth=1 {url} {dest:?}
            "#
        )).await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let (_url, raw_dest) = split_url_dest(spec)?;
        let dest = expand_home(raw_dest)?;
        run_sh(&format!("rm -rf {dest:?}")).await?;
        Ok(())
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

/// Split a `git:<url>:<dest>` spec from the *right*, since `<url>` itself
/// contains colons (e.g. `https://...` or `git@github.com:user/repo`). Dest
/// is always the final segment, which catalog convention requires to start
/// with `~/`, `/`, or `$` (a path or env-var). Without that anchor we'd
/// happily mis-split a colon inside the URL — e.g. `git:https://example.com`
/// would silently give url=`https` dest=`//example.com`.
fn split_url_dest(spec: &str) -> Result<(&str, &str)> {
    let rest = spec.strip_prefix("git:").unwrap_or(spec);
    let mut it = rest.rsplitn(2, ':');
    let dest = it.next().unwrap_or("");
    let url  = it.next().unwrap_or("");
    let dest_looks_like_path = !dest.starts_with("//")  // "//foo.com/..." = URL remnant
        && (dest.starts_with('/')
            || dest.starts_with('~')
            || dest.starts_with('$'));
    if url.is_empty() || dest.is_empty() || !dest_looks_like_path {
        bail!("git: spec must be git:<url>:<install_to> where install_to starts with /, ~, or $; got: {spec}");
    }
    Ok((url, dest))
}

#[cfg(test)]
mod tests {
    use super::split_url_dest;

    #[test]
    fn https_url_with_colon_splits_at_last_colon() {
        let (url, dest) = split_url_dest("git:https://github.com/flutter/flutter.git:$HOME/.flutter").unwrap();
        assert_eq!(url,  "https://github.com/flutter/flutter.git");
        assert_eq!(dest, "$HOME/.flutter");
    }

    #[test]
    fn ssh_url_splits_correctly() {
        let (url, dest) = split_url_dest("git:git@github.com:user/repo.git:~/repo").unwrap();
        assert_eq!(url,  "git@github.com:user/repo.git");
        assert_eq!(dest, "~/repo");
    }

    #[test]
    fn no_colon_at_all_errors() {
        assert!(split_url_dest("git:malformed-no-colons").is_err());
    }

    #[test]
    fn dest_not_anchored_as_path_errors() {
        // Without ~/$/ prefix on dest we'd mis-split inside the URL. Bail.
        assert!(split_url_dest("git:https://example.com/repo.git").is_err());
    }
}

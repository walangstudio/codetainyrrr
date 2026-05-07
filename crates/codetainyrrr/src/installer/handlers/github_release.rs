/// Handler for `gh:<owner/repo>:<asset_glob>` specs.
/// Downloads the latest GitHub release asset matching the glob, extracts it,
/// and places any executables in ~/.local/bin.
use anyhow::{bail, Context, Result};
use async_trait::async_trait;

use super::run_sh;
use crate::installer::{InstallStatus, Installer};

pub struct GithubReleaseHandler;

#[async_trait]
impl Installer for GithubReleaseHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        // spec: gh:<owner/repo>:<asset_pattern>
        let rest = spec.strip_prefix("gh:").unwrap_or(spec);
        let parts: Vec<&str> = rest.splitn(2, ':').collect();
        if parts.len() != 2 {
            bail!("gh: spec must be gh:<owner/repo>:<asset_pattern>, got: {spec}");
        }
        let repo = parts[0];
        let pattern = parts[1];

        run_sh(&format!(
            r#"
            set -euo pipefail
            REPO="{repo}"
            PATTERN="{pattern}"
            DEST="$HOME/.local/bin"
            mkdir -p "$DEST"

            API_URL="https://api.github.com/repos/${{REPO}}/releases/latest"
            ASSET_URL=$(curl -fsSL "$API_URL" \
                | grep '"browser_download_url"' \
                | grep -o 'https://[^"]*' \
                | grep -E "${{PATTERN//\*/.*}}" \
                | head -1)

            [ -z "$ASSET_URL" ] && echo "No asset matching $PATTERN in $REPO" && exit 1

            TMPDIR=$(mktemp -d)
            FILENAME=$(basename "$ASSET_URL")
            curl -fsSL "$ASSET_URL" -o "$TMPDIR/$FILENAME"

            case "$FILENAME" in
                *.tar.gz|*.tgz) tar -C "$TMPDIR" -xzf "$TMPDIR/$FILENAME" ;;
                *.tar.bz2)      tar -C "$TMPDIR" -xjf "$TMPDIR/$FILENAME" ;;
                *.zip)          unzip -q "$TMPDIR/$FILENAME" -d "$TMPDIR" ;;
                *)              chmod +x "$TMPDIR/$FILENAME" ;;
            esac

            find "$TMPDIR" -maxdepth 2 -type f -executable ! -name "*.sh" \
                | while read -r bin; do
                    cp "$bin" "$DEST/$(basename $bin)"
                    chmod +x "$DEST/$(basename $bin)"
                done

            rm -rf "$TMPDIR"
            "#
        ))
        .await
        .with_context(|| format!("github-release install failed for {spec}"))
    }

    async fn uninstall(&self, key: &str, _spec: &str) -> Result<()> {
        run_sh(&format!("rm -f \"$HOME/.local/bin/{key}\"")).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

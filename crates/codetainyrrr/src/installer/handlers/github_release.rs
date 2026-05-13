/// Handler for `gh:<owner/repo>:<asset_glob>` specs.
/// Downloads the latest GitHub release asset matching the glob, extracts it,
/// and places any executables in ~/.local/bin.
use anyhow::{Context, Result, bail};
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

        // Glob → ERE: `*foo*.tar.gz` → `.*foo.*\.tar\.gz`. Quote dots so they
        // don't match arbitrary chars — important for picking the right file
        // when assets share substrings.
        let regex = pattern.replace('.', r"\.").replace('*', ".*");

        run_sh(&format!(
            r#"
            set -uo pipefail
            REPO="{repo}"
            PATTERN_RE="{regex}"
            DEST="$HOME/.local/bin"
            mkdir -p "$DEST"

            API_URL="https://api.github.com/repos/${{REPO}}/releases/latest"

            # Auth header if a token's available (raises rate limit 60→5000/hr).
            AUTH_ARGS=()
            if [ -n "${{GITHUB_TOKEN:-}}" ]; then
                AUTH_ARGS=(-H "Authorization: Bearer $GITHUB_TOKEN")
            fi

            RESP=$(curl -fsSL "${{AUTH_ARGS[@]}}" "$API_URL" 2>&1) || {{
                echo "github-release: failed to fetch $API_URL" >&2
                echo "$RESP" | head -5 >&2
                exit 1
            }}

            # Detect rate-limit / error responses up front so the user sees a clear cause.
            if echo "$RESP" | jq -e '.message' >/dev/null 2>&1; then
                MSG=$(echo "$RESP" | jq -r '.message')
                echo "github-release: API returned error: $MSG" >&2
                exit 1
            fi

            # -i so 'Linux' / 'linux' both work — case is a frequent source of
            # silent miss when copy-pasting glob patterns.
            ASSET_URL=$(echo "$RESP" \
                | jq -r '.assets[].browser_download_url' \
                | grep -iE "$PATTERN_RE" \
                | head -1)

            if [ -z "$ASSET_URL" ]; then
                echo "github-release: no asset matching '/$PATTERN_RE/' (case-insensitive) in $REPO. Available:" >&2
                echo "$RESP" | jq -r '.assets[].name' | head -20 >&2
                exit 1
            fi

            echo "github-release: downloading $ASSET_URL" >&2
            TMPDIR=$(mktemp -d)
            FILENAME=$(basename "$ASSET_URL")
            curl -fsSL "${{AUTH_ARGS[@]}}" "$ASSET_URL" -o "$TMPDIR/$FILENAME"

            case "$FILENAME" in
                *.tar.gz|*.tgz) tar -C "$TMPDIR" -xzf "$TMPDIR/$FILENAME" ;;
                *.tar.bz2)      tar -C "$TMPDIR" -xjf "$TMPDIR/$FILENAME" ;;
                *.zip)          unzip -q "$TMPDIR/$FILENAME" -d "$TMPDIR" ;;
                *)              chmod +x "$TMPDIR/$FILENAME" ;;
            esac

            # Some tarballs ship binaries without the executable bit set (e.g.,
            # lazygit). Mark anything that's a known binary by name pattern.
            find "$TMPDIR" -maxdepth 2 -type f \
                ! -name "*.tar*" ! -name "*.zip" ! -name "*.md" ! -name "*.txt" \
                ! -name "LICENSE*" ! -name "*.json" ! -name "*.sh" \
                | while read -r bin; do
                    chmod +x "$bin" 2>/dev/null || true
                    cp "$bin" "$DEST/$(basename "$bin")"
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

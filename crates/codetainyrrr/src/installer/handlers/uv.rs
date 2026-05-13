use super::run_cmd;
use crate::installer::{async_trait, InstallStatus, Installer};
use anyhow::Result;

/// Spec formats:
///   uv:<package>                            simple uv tool install
///   uv:<package>@<git-or-url>               translates to: uv tool install <package> --from <git-or-url>
///                                           (the @-suffix is detected when it contains "://" or starts with "git+")
///
/// Example: `uv:specify-cli@git+https://github.com/github/spec-kit.git`
pub struct UvHandler;

fn parse(spec: &str) -> (&str, Option<&str>) {
    let body = spec.strip_prefix("uv:").unwrap_or(spec);
    if let Some((pkg, src)) = body.split_once('@') {
        if src.contains("://") || src.starts_with("git+") {
            return (pkg, Some(src));
        }
    }
    (body, None)
}

#[async_trait]
impl Installer for UvHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let (package, from) = parse(spec);
        let mut args = vec!["tool", "install", package];
        if let Some(src) = from {
            args.extend_from_slice(&["--from", src]);
        }
        run_cmd("uv", &args).await
    }

    async fn uninstall(&self, _key: &str, spec: &str) -> Result<()> {
        let (package, _) = parse(spec);
        run_cmd("uv", &["tool", "uninstall", package]).await
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn plain_package() {
        assert_eq!(parse("uv:aider-chat"), ("aider-chat", None));
        assert_eq!(parse("uv:black"),      ("black", None));
    }

    #[test]
    fn versioned_pep440_is_not_treated_as_from() {
        // poetry@1.7 isn't a from-URL — gets passed verbatim to `uv tool install`.
        assert_eq!(parse("uv:poetry@1.7"), ("poetry@1.7", None));
    }

    #[test]
    fn git_from_url() {
        let (pkg, from) = parse("uv:specify-cli@git+https://github.com/github/spec-kit.git");
        assert_eq!(pkg, "specify-cli");
        assert_eq!(from, Some("git+https://github.com/github/spec-kit.git"));
    }

    #[test]
    fn https_from_url() {
        let (pkg, from) = parse("uv:foo@https://example.com/foo.tar.gz");
        assert_eq!(pkg, "foo");
        assert_eq!(from, Some("https://example.com/foo.tar.gz"));
    }
}

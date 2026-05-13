/// Handler for `merge-json:<target-path>:<cmd>` specs.
/// Runs `cmd`, captures its JSON stdout, and deep-merges into `target-path`.
/// Completely generic — driven entirely by the catalog spec.
use anyhow::{Context, Result, bail};
use async_trait::async_trait;

use super::expand_home;
use crate::installer::{InstallStatus, Installer};

pub struct MergeJsonHandler;

#[async_trait]
impl Installer for MergeJsonHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let rest = spec.strip_prefix("merge-json:").unwrap_or(spec);
        // Split on first ':' only — the path may contain other chars but no ':'
        let (raw_path, cmd) = rest.split_once(':').with_context(|| {
            format!("merge-json: spec must be merge-json:<path>:<cmd>, got: {spec}")
        })?;

        let target = expand_home(raw_path)?;

        let output = tokio::process::Command::new("bash")
            .args(["-c", cmd])
            .env("PATH", super::enriched_path())
            .output()
            .await
            .with_context(|| format!("failed to run: {cmd}"))?;

        if !output.status.success() {
            bail!(
                "command '{}' failed ({}): {}",
                cmd,
                output.status,
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let patch: serde_json::Value = serde_json::from_slice(&output.stdout)
            .with_context(|| "command stdout is not valid JSON")?;

        let mut existing: serde_json::Value = if std::path::Path::new(&target).exists() {
            let raw = std::fs::read_to_string(&target)?;
            serde_json::from_str(&raw).unwrap_or(serde_json::Value::Object(Default::default()))
        } else {
            serde_json::Value::Object(Default::default())
        };

        merge_json(&mut existing, patch);

        if let Some(parent) = std::path::Path::new(&target).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&target, serde_json::to_string_pretty(&existing)?)?;
        Ok(())
    }

    async fn uninstall(&self, _key: &str, _spec: &str) -> Result<()> {
        Ok(())
    }

    async fn status(&self, _key: &str) -> Result<InstallStatus> {
        Ok(InstallStatus::Missing)
    }
}

fn merge_json(base: &mut serde_json::Value, overlay: serde_json::Value) {
    if let (Some(base_obj), Some(over_obj)) = (base.as_object_mut(), overlay.as_object()) {
        for (k, v) in over_obj {
            let entry = base_obj.entry(k.clone()).or_insert(serde_json::Value::Null);
            if entry.is_object() && v.is_object() {
                merge_json(entry, v.clone());
            } else {
                *entry = v.clone();
            }
        }
    }
}

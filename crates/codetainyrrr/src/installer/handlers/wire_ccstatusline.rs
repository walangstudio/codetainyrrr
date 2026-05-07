/// Handler for `wire-ccstatusline:<cmd>` — runs ccstatusline and merges its
/// JSON output into ~/.claude/settings.json.
use anyhow::{Context, Result};
use async_trait::async_trait;

use crate::installer::{InstallStatus, Installer};

pub struct WireCcstatuslineHandler;

#[async_trait]
impl Installer for WireCcstatuslineHandler {
    async fn install(&self, _key: &str, spec: &str) -> Result<()> {
        let cmd = spec.strip_prefix("wire-ccstatusline:").unwrap_or(spec);

        let output = tokio::process::Command::new("bash")
            .args(["-c", cmd])
            .output()
            .await
            .context("failed to run ccstatusline")?;

        if !output.status.success() {
            anyhow::bail!(
                "ccstatusline exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let produced: serde_json::Value =
            serde_json::from_slice(&output.stdout).context("ccstatusline output is not valid JSON")?;

        let settings_path = dirs::home_dir()
            .context("no home dir")?
            .join(".claude")
            .join("settings.json");

        let mut existing: serde_json::Value = if settings_path.exists() {
            let raw = std::fs::read_to_string(&settings_path)?;
            serde_json::from_str(&raw).unwrap_or(serde_json::Value::Object(Default::default()))
        } else {
            serde_json::Value::Object(Default::default())
        };

        merge_json(&mut existing, produced);

        std::fs::create_dir_all(settings_path.parent().unwrap())?;
        std::fs::write(&settings_path, serde_json::to_string_pretty(&existing)?)?;
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

/// Sentinel files track what's been installed inside the container.
/// Path: ~/.local/share/<project.data_dir_name>/<kind>/<key>.installed
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::OnceLock;

#[derive(Debug, Serialize, Deserialize)]
pub struct SentinelData {
    pub version: Option<String>,
    pub installed_at: String,
    pub spec: String,
}

static SENTINEL_DIR_NAME: OnceLock<String> = OnceLock::new();

pub fn set_dir_name(name: &str) {
    let _ = SENTINEL_DIR_NAME.set(name.to_string());
}

fn dir_name() -> &'static str {
    SENTINEL_DIR_NAME.get().map(String::as_str).unwrap_or("codetainyrrr")
}

fn sentinel_path(kind: &str, key: &str) -> PathBuf {
    let base = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(dir_name())
        .join(kind);
    base.join(format!("{key}.installed"))
}

pub fn is_installed(kind: &str, key: &str) -> bool {
    sentinel_path(kind, key).exists()
}

/// Path of the post-install marker — separate file so we can tell first-install
/// from re-runs. `<key>.installed` says the install handler succeeded;
/// `<key>.post` says post_install hooks ran for this install.
fn post_sentinel_path(kind: &str, key: &str) -> PathBuf {
    let base = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(dir_name())
        .join(kind);
    base.join(format!("{key}.post"))
}

pub fn post_install_done(kind: &str, key: &str) -> bool {
    post_sentinel_path(kind, key).exists()
}

pub fn mark_post_install(kind: &str, key: &str) -> Result<()> {
    let p = post_sentinel_path(kind, key);
    let dir = p.parent().ok_or_else(|| anyhow::anyhow!("post-sentinel path has no parent: {}", p.display()))?;
    std::fs::create_dir_all(dir)?;
    std::fs::write(&p, chrono::Utc::now().to_rfc3339())?;
    Ok(())
}

pub fn remove_post(kind: &str, key: &str) -> Result<()> {
    let p = post_sentinel_path(kind, key);
    if p.exists() {
        std::fs::remove_file(p)?;
    }
    Ok(())
}

pub fn read(kind: &str, key: &str) -> Option<SentinelData> {
    let p = sentinel_path(kind, key);
    let raw = std::fs::read_to_string(p).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn mark(kind: &str, key: &str, spec: &str, version: Option<String>) -> Result<()> {
    let p = sentinel_path(kind, key);
    let dir = p.parent().ok_or_else(|| anyhow::anyhow!("sentinel path has no parent: {}", p.display()))?;
    std::fs::create_dir_all(dir)?;
    let data = SentinelData {
        version,
        installed_at: chrono::Utc::now().to_rfc3339(),
        spec: spec.to_string(),
    };
    std::fs::write(&p, serde_json::to_string_pretty(&data)?)?;
    Ok(())
}

pub fn remove(kind: &str, key: &str) -> Result<()> {
    let p = sentinel_path(kind, key);
    if p.exists() {
        std::fs::remove_file(p)?;
    }
    Ok(())
}

pub fn list_kind(kind: &str) -> Vec<String> {
    let dir = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(dir_name())
        .join(kind);
    if !dir.exists() {
        return vec![];
    }
    walkdir::WalkDir::new(&dir)
        .max_depth(1)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|x| x == "installed").unwrap_or(false))
        .filter_map(|e| {
            e.path()
                .file_stem()
                .and_then(|s| s.to_str())
                .map(|s| s.to_string())
        })
        .collect()
}

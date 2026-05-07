/// Sentinel files track what's been installed inside the container.
/// Path: ~/.local/share/codetainyrrr/<kind>/<key>.installed
/// Content: JSON with version and timestamp.
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize)]
pub struct SentinelData {
    pub version: Option<String>,
    pub installed_at: String,
    pub spec: String,
}

fn sentinel_path(kind: &str, key: &str) -> PathBuf {
    let base = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("codetainyrrr")
        .join(kind);
    base.join(format!("{key}.installed"))
}

pub fn is_installed(kind: &str, key: &str) -> bool {
    sentinel_path(kind, key).exists()
}

pub fn read(kind: &str, key: &str) -> Option<SentinelData> {
    let p = sentinel_path(kind, key);
    let raw = std::fs::read_to_string(p).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn mark(kind: &str, key: &str, spec: &str, version: Option<String>) -> Result<()> {
    let p = sentinel_path(kind, key);
    std::fs::create_dir_all(p.parent().unwrap())?;
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
        .join("codetainyrrr")
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

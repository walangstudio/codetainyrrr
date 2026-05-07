use anyhow::{Context, Result};
use indexmap::IndexMap;
use std::path::Path;

/// Parsed .env: preserves insertion order and blank/comment lines.
#[derive(Debug, Default, Clone)]
pub struct EnvFile {
    values: IndexMap<String, String>,
}

impl EnvFile {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("reading {}", path.display()))?;
        Ok(Self::parse(&raw))
    }

    pub fn parse(raw: &str) -> Self {
        let mut values = IndexMap::new();
        for line in raw.lines() {
            let line = line.trim_start_matches('\u{feff}'); // strip BOM
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                let k = k.trim().to_string();
                let v = v.trim();
                // Strip inline comments and surrounding double-quotes
                let v = v.splitn(2, " #").next().unwrap_or(v).trim();
                let v = v.trim_matches('"').to_string();
                values.insert(k, v);
            }
        }
        Self { values }
    }

    pub fn get(&self, key: &str) -> &str {
        self.values.get(key).map(|s| s.as_str()).unwrap_or("")
    }

    pub fn get_opt(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(|s| s.as_str())
    }

    pub fn set(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.values.insert(key.into(), value.into());
    }

    pub fn keys_csv(&self, key: &str) -> Vec<String> {
        let v = self.get(key);
        if v.is_empty() {
            vec![]
        } else {
            v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
        }
    }

    pub fn write(&self, path: &Path, header: &str) -> Result<()> {
        let mut out = String::new();
        out.push_str(header);
        out.push('\n');
        for (k, v) in &self.values {
            if v.is_empty() {
                out.push_str(&format!("{k}=\n"));
            } else if v.contains(' ') || v.contains('"') || v.contains('\\') {
                let escaped = v.replace('\\', r"\\").replace('"', r#"\""#);
                out.push_str(&format!("{k}=\"{escaped}\"\n"));
            } else {
                out.push_str(&format!("{k}={v}\n"));
            }
        }
        std::fs::write(path, out).with_context(|| format!("writing {}", path.display()))
    }
}

/// Diff two EnvFiles: returns keys added, removed, or changed in `new` vs `old`.
pub struct EnvDiff {
    pub added: Vec<String>,
    pub removed: Vec<String>,
    pub changed: Vec<String>,
}

impl EnvDiff {
    pub fn compute(old: &EnvFile, new: &EnvFile) -> Self {
        let old_keys: std::collections::HashSet<_> = old.values.keys().collect();
        let new_keys: std::collections::HashSet<_> = new.values.keys().collect();

        let added = new_keys.difference(&old_keys).map(|k| (*k).clone()).collect();
        let removed = old_keys.difference(&new_keys).map(|k| (*k).clone()).collect();
        let changed = old_keys
            .intersection(&new_keys)
            .filter(|k| old.values.get(k.as_str()) != new.values.get(k.as_str()))
            .map(|k| (*k).clone())
            .collect();

        Self { added, removed, changed }
    }
}

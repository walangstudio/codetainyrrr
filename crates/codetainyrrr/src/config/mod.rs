pub mod loader;
pub mod schema;

pub use schema::{Catalog, FieldType, ProjectMeta, WizardDef};

/// Find the directory containing catalog.json.
///
/// Resolution order:
///   1. `CODETAINYRRR_CONFIG_ROOT` env var (set by `--config-root` flag too)
///   2. `/etc/codetainyrrr` and `/` (typical container layouts)
///   3. current working directory (host dev)
pub fn locate_root() -> std::path::PathBuf {
    if let Ok(v) = std::env::var("CODETAINYRRR_CONFIG_ROOT") {
        let p = std::path::PathBuf::from(v);
        if p.join("catalog.json").exists() {
            return p;
        }
    }
    for candidate in ["/etc/codetainyrrr", "/"] {
        let p = std::path::Path::new(candidate);
        if p.join("catalog.json").exists() {
            return p.to_path_buf();
        }
    }
    std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
}

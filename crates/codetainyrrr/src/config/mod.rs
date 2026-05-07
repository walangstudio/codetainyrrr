pub mod loader;
pub mod schema;

pub use schema::{Catalog, FieldType, WizardDef};

/// Find the directory containing catalog.json.
/// Checks: /etc/codetainyrrr (container), / (container root), then cwd (host dev).
pub fn locate_root() -> std::path::PathBuf {
    for candidate in ["/etc/codetainyrrr", "/"] {
        let p = std::path::Path::new(candidate);
        if p.join("catalog.json").exists() {
            return p.to_path_buf();
        }
    }
    std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
}

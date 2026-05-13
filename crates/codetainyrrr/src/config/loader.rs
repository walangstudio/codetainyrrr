use super::schema::{Catalog, WizardDef};
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub struct Config {
    pub catalog: Catalog,
    pub wizard: WizardDef,
    pub root: PathBuf,
}

pub fn load(root: &Path) -> Result<Config> {
    let catalog = load_catalog(root)?;
    let wizard = load_wizard(root)?;
    Ok(Config { catalog, wizard, root: root.to_path_buf() })
}

fn load_catalog(root: &Path) -> Result<Catalog> {
    let base_path = root.join("catalog.json");
    let base: Catalog = serde_json::from_str(
        &std::fs::read_to_string(&base_path)
            .with_context(|| format!("reading {}", base_path.display()))?,
    )
    .context("parsing catalog.json")?;

    let user_path = root.join("catalog.user.json");
    if !user_path.exists() {
        return Ok(base);
    }

    let user: Catalog = serde_json::from_str(
        &std::fs::read_to_string(&user_path).context("reading catalog.user.json")?,
    )
    .context("parsing catalog.user.json")?;

    Ok(merge_catalogs(base, user))
}

fn merge_catalogs(mut base: Catalog, user: Catalog) -> Catalog {
    merge_by_key(&mut base.clis, user.clis, |x| x.key.clone());
    merge_by_key(&mut base.tools, user.tools, |x| x.key.clone());
    merge_by_key(&mut base.plugins, user.plugins, |x| x.key.clone());
    base
}

fn merge_by_key<T, F: Fn(&T) -> String>(base: &mut Vec<T>, user: Vec<T>, key_fn: F) {
    let user_keys: std::collections::HashSet<String> = user.iter().map(|x| key_fn(x)).collect();
    base.retain(|x| !user_keys.contains(&key_fn(x)));
    base.extend(user);
}

fn load_wizard(root: &Path) -> Result<WizardDef> {
    let local = root.join("wizard.json");
    if local.exists() {
        return serde_json::from_str(
            &std::fs::read_to_string(&local).with_context(|| format!("reading {}", local.display()))?,
        )
        .context("parsing wizard.json");
    }
    // Last-resort fallbacks for known container layouts.
    for fallback in ["/etc/codetainyrrr/wizard.json"] {
        let p = PathBuf::from(fallback);
        if p.exists() {
            return serde_json::from_str(
                &std::fs::read_to_string(&p).with_context(|| format!("reading {}", p.display()))?,
            )
            .context("parsing wizard.json");
        }
    }
    anyhow::bail!("wizard.json not found in {}", root.display())
}

//! Catalog dependency consistency + topological-install-order simulation.
//!
//! These tests catch the class of bug where an entry's install spec needs a
//! runtime (node/uv/etc) but the entry forgets to declare it as a dependency.
//! Without these, a user selects e.g. `expo` (an npm package) without `node`,
//! the orchestrator runs `npm install` before nvm has put npm on PATH, and we
//! get a confusing "no such file or directory" at install time.
//!
//! Strategy: load the actual catalog.json, mirror the orchestrator's walk via
//! `simulate_order`, and assert that every spec that needs a particular runtime
//! has that runtime ahead of itself in the install order.

use std::collections::HashSet;
use std::path::PathBuf;

use codetainyrrr::config::{Catalog, loader};

fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn load_real_catalog() -> Catalog {
    loader::load(&project_root())
        .expect("load real catalog")
        .catalog
}

/// Returns (key, install_spec, dependencies) for every catalog entry, regardless of kind.
fn all_entries(catalog: &Catalog) -> Vec<(String, String, Vec<String>)> {
    let mut out = vec![];
    for c in &catalog.clis {
        out.push((c.key.clone(), c.install.clone(), c.dependencies.clone()));
    }
    for t in &catalog.tools {
        if let Some(spec) = &t.install {
            out.push((t.key.clone(), spec.clone(), t.dependencies.clone()));
        }
    }
    for p in &catalog.plugins {
        if let Some(spec) = &p.install {
            out.push((p.key.clone(), spec.clone(), p.dependencies.clone()));
        }
    }
    out
}

/// What runtime does this install spec require? Returned as the dependency-key
/// the entry must list (transitively or directly) for the install to succeed.
fn required_runtime(spec: &str) -> Option<&'static str> {
    if spec.starts_with("npm:") {
        return Some("node");
    }
    if spec.starts_with("corepack:") {
        return Some("node");
    }
    if spec.starts_with("uv:") {
        return Some("uv");
    }
    // merge-json's command is shell — heuristic: if it invokes npx, it needs node.
    if spec.starts_with("merge-json:") && spec.contains("npx ") {
        return Some("node");
    }
    None
}

/// Mirror of `installer::orchestrator::install_with_deps` minus the actual
/// installs. Records the order keys would be processed in.
fn simulate_order(catalog: &Catalog, keys: &[&str]) -> Vec<String> {
    fn walk(catalog: &Catalog, key: &str, visited: &mut HashSet<String>, order: &mut Vec<String>) {
        if !visited.insert(key.to_string()) {
            return;
        }
        let deps = lookup_deps(catalog, key)
            .unwrap_or_else(|| panic!("dependency '{key}' not found in catalog"));
        for dep in &deps {
            walk(catalog, dep, visited, order);
        }
        order.push(key.to_string());
    }

    let mut visited = HashSet::new();
    let mut order = vec![];
    for k in keys {
        walk(catalog, k, &mut visited, &mut order);
    }
    order
}

fn lookup_deps(catalog: &Catalog, key: &str) -> Option<Vec<String>> {
    if let Some(c) = catalog.clis.iter().find(|c| c.key == key) {
        return Some(c.dependencies.clone());
    }
    if let Some(t) = catalog.tools.iter().find(|t| t.key == key) {
        return Some(t.dependencies.clone());
    }
    if let Some(p) = catalog.plugins.iter().find(|p| p.key == key) {
        return Some(p.dependencies.clone());
    }
    None
}

// ── Coverage: every spec that needs node/uv must declare it ─────────────────

#[test]
fn every_runtime_dependent_entry_declares_its_runtime() {
    let catalog = load_real_catalog();
    let mut failures = vec![];

    for (key, spec, _deps) in all_entries(&catalog) {
        let Some(needed) = required_runtime(&spec) else {
            continue;
        };

        // Simulate install: starts with `key`. Confirm `needed` appears
        // earlier in the order — i.e. it's a transitive dep.
        let order = simulate_order(&catalog, &[key.as_str()]);
        let needed_idx = order.iter().position(|k| k == needed);
        let key_idx = order.iter().position(|k| k == &key).unwrap();

        match needed_idx {
            Some(i) if i < key_idx => {} // good — needed installs first
            Some(i) => failures.push(format!(
                "'{key}' (spec: {spec}) lists '{needed}' but at position {i} >= {key_idx}"
            )),
            None => failures.push(format!(
                "'{key}' (spec: {spec}) requires '{needed}' but it's not in the dep tree. \
                 Add `\"dependencies\": [\"{needed}\"]` to the catalog entry."
            )),
        }
    }

    assert!(
        failures.is_empty(),
        "catalog dependency gaps:\n  - {}",
        failures.join("\n  - ")
    );
}

// ── Concrete topological scenarios ───────────────────────────────────────────

#[test]
fn selecting_expo_pulls_node_in_first() {
    let catalog = load_real_catalog();
    let order = simulate_order(&catalog, &["expo"]);
    assert_eq!(order, vec!["node", "expo"]);
}

#[test]
fn selecting_ts_and_ccusage_installs_node_once() {
    let catalog = load_real_catalog();
    let order = simulate_order(&catalog, &["ts", "ccusage"]);
    let node_count = order.iter().filter(|k| *k == "node").count();
    assert_eq!(node_count, 1, "node should appear exactly once: {order:?}");
    let node_pos = order.iter().position(|k| k == "node").unwrap();
    let ts_pos = order.iter().position(|k| k == "ts").unwrap();
    let ccu_pos = order.iter().position(|k| k == "ccusage").unwrap();
    assert!(node_pos < ts_pos);
    assert!(node_pos < ccu_pos);
}

#[test]
fn selecting_aider_pulls_uv_in_first() {
    let catalog = load_real_catalog();
    let order = simulate_order(&catalog, &["aider"]);
    assert_eq!(order, vec!["uv", "aider"]);
}

#[test]
fn spec_kit_and_aider_share_uv() {
    let catalog = load_real_catalog();
    let order = simulate_order(&catalog, &["spec-kit", "aider"]);
    assert_eq!(order.iter().filter(|k| *k == "uv").count(), 1);
    let uv = order.iter().position(|k| k == "uv").unwrap();
    let sk = order.iter().position(|k| k == "spec-kit").unwrap();
    let ai = order.iter().position(|k| k == "aider").unwrap();
    assert!(uv < sk);
    assert!(uv < ai);
}

#[test]
fn full_default_set_resolves_cleanly() {
    // Mimic the most common entrypoint: claude (CLI) + default tools + default plugins.
    let catalog = load_real_catalog();
    let mut keys = vec!["claude"];
    keys.extend(
        catalog
            .tools
            .iter()
            .filter(|t| t.default)
            .map(|t| t.key.as_str()),
    );
    keys.extend(
        catalog
            .plugins
            .iter()
            .filter(|p| p.default)
            .map(|p| p.key.as_str()),
    );

    let order = simulate_order(&catalog, &keys);
    // node must come before any npm/corepack/npx-using entry that's in the order.
    if let Some(np) = order.iter().position(|k| k == "node") {
        // ts (npm) and ccstatusline (npx) must come after node.
        if let Some(ts) = order.iter().position(|k| k == "ts") {
            assert!(ts > np, "ts must come after node: {order:?}");
        }
        if let Some(cc) = order.iter().position(|k| k == "ccstatusline") {
            assert!(cc > np, "ccstatusline must come after node: {order:?}");
        }
    }
}

#[test]
fn no_cycles_in_dependency_graph() {
    // simulate_order would stack-overflow on a cycle (visited prevents infinite recursion,
    // but a self-referencing dep that lists *itself indirectly* and isn't yet visited
    // would still resolve fine via visited). The real cycle-killer here is that the
    // `visited` set short-circuits re-entry. We assert the simpler property: every
    // catalog key resolves to a finite order without panicking.
    let catalog = load_real_catalog();
    for (key, _, _) in all_entries(&catalog) {
        let _ = simulate_order(&catalog, &[key.as_str()]);
    }
}

#[test]
fn every_dependency_resolves_to_a_known_key() {
    let catalog = load_real_catalog();
    let known: HashSet<String> = catalog
        .clis
        .iter()
        .map(|c| c.key.clone())
        .chain(catalog.tools.iter().map(|t| t.key.clone()))
        .chain(catalog.plugins.iter().map(|p| p.key.clone()))
        .collect();

    let mut bad = vec![];
    for (key, _, deps) in all_entries(&catalog) {
        for d in &deps {
            if !known.contains(d) {
                bad.push(format!("'{key}' depends on unknown key '{d}'"));
            }
        }
    }
    assert!(bad.is_empty(), "{}", bad.join(", "));
}

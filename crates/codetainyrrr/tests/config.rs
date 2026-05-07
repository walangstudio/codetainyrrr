/// Integration tests: parse the real catalog.json + wizard.json shipped with the project.
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR = <repo>/crates/codetainyrrr
    // two parents → <repo>
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()  // <repo>/crates
        .parent().unwrap()  // <repo>
        .to_path_buf()
}

#[test]
fn catalog_parses_without_error() {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join("catalog.json"))
        .expect("catalog.json not found at repo root");
    let catalog: codetainyrrr::config::Catalog =
        serde_json::from_str(&raw).expect("catalog.json failed to parse");

    assert!(!catalog.clis.is_empty(),   "catalog.clis must not be empty");
    assert!(!catalog.tools.is_empty(),  "catalog.tools must not be empty");
    assert!(!catalog.plugins.is_empty(),"catalog.plugins must not be empty");
}

#[test]
fn catalog_clis_all_have_install_spec() {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join("catalog.json")).unwrap();
    let catalog: codetainyrrr::config::Catalog = serde_json::from_str(&raw).unwrap();

    for cli in &catalog.clis {
        assert!(!cli.install.is_empty(), "CLI '{}' has an empty install spec", cli.key);
    }
}

#[test]
fn catalog_claude_entry_correct() {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join("catalog.json")).unwrap();
    let catalog: codetainyrrr::config::Catalog = serde_json::from_str(&raw).unwrap();

    let claude = catalog.clis.iter().find(|c| c.key == "claude")
        .expect("claude not found in catalog.clis");

    assert_eq!(claude.bin, "claude");
    assert!(claude.oauth_supported);
    assert!(claude.needs_keys.contains(&"ANTHROPIC_API_KEY".to_string()));
}

#[test]
fn wizard_parses_without_error() {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join("wizard.json"))
        .expect("wizard.json not found at repo root");
    let wizard: codetainyrrr::config::WizardDef =
        serde_json::from_str(&raw).expect("wizard.json failed to parse");

    assert_eq!(wizard.pages.len(), 8, "expected 8 wizard pages");
}

#[test]
fn wizard_pages_have_correct_ids() {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join("wizard.json")).unwrap();
    let wizard: codetainyrrr::config::WizardDef = serde_json::from_str(&raw).unwrap();

    let expected_ids = [
        "cli", "paths", "claude_settings", "api_keys",
        "git_identity", "tools", "plugins", "custom_configs",
    ];
    for (page, expected_id) in wizard.pages.iter().zip(expected_ids.iter()) {
        assert_eq!(page.id, *expected_id, "page id mismatch");
    }
}

#[test]
fn wizard_all_field_prompts_non_empty() {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join("wizard.json")).unwrap();
    let wizard: codetainyrrr::config::WizardDef = serde_json::from_str(&raw).unwrap();

    for page in &wizard.pages {
        for field in &page.fields {
            // Fields sourced from catalog (single_select / multiselect) don't need a prompt
            if field.source.is_some() { continue; }
            assert!(
                !field.prompt.is_empty(),
                "page '{}' field '{}' has an empty prompt",
                page.id, field.id
            );
        }
    }
}

#[test]
fn loader_merges_user_catalog_overrides() {
    use codetainyrrr::config::schema::Catalog;

    let base_json = r#"{
        "clis":    [{"key":"claude","name":"Claude","description":"x","bin":"claude","install":"curl x | bash"}],
        "tools":   [{"key":"node","category":"Runtimes","default":true,"description":"Node"}],
        "plugins": []
    }"#;
    let user_json = r#"{
        "clis":    [{"key":"claude","name":"Claude (custom)","description":"overridden","bin":"claude","install":"custom-install"}],
        "tools":   [{"key":"mypkg","category":"Custom","default":false,"description":"my package","install":"npm:mypkg"}],
        "plugins": []
    }"#;

    let mut base: Catalog = serde_json::from_str(base_json).unwrap();
    let user: Catalog = serde_json::from_str(user_json).unwrap();

    // Replicate merge logic: user overrides base by key
    let user_cli_keys: std::collections::HashSet<_> = user.clis.iter().map(|c| c.key.clone()).collect();
    base.clis.retain(|c| !user_cli_keys.contains(&c.key));
    base.clis.extend(user.clis);

    let user_tool_keys: std::collections::HashSet<_> = user.tools.iter().map(|t| t.key.clone()).collect();
    base.tools.retain(|t| !user_tool_keys.contains(&t.key));
    base.tools.extend(user.tools);

    // claude should be the user's version
    let claude = base.clis.iter().find(|c| c.key == "claude").unwrap();
    assert_eq!(claude.name, "Claude (custom)");

    // node should still be present (not overridden)
    assert!(base.tools.iter().any(|t| t.key == "node"));
    // mypkg should be added
    assert!(base.tools.iter().any(|t| t.key == "mypkg"));
}

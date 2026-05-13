/// E2E: wizard config layer.
///
/// We deliberately do NOT script the cliclack TUI here — that requires a real
/// PTY and is brittle cross-platform. Instead we verify the data-driven layer
/// the wizard depends on:
///   1. wizard.json parses against an alt project's config-root
///   2. every wizard page declared in JSON is reachable to the runtime
///   3. project meta defaults round-trip (catalog with no `project` block
///      still loads with sensible defaults)
use codetainyrrr::config::{ProjectMeta, loader};
use std::path::PathBuf;

fn tmp(name: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("ct-wiz-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn loads_alt_wizard_and_catalog() {
    let dir = tmp("alt-load");
    std::fs::write(
        dir.join("catalog.json"),
        r#"{
        "project": { "name": "alt", "binary_name": "alt" },
        "clis": [{ "key": "x", "name": "X", "description": "x", "bin": "x", "install": "npm:x" }],
        "tools": [],
        "plugins": []
    }"#,
    )
    .unwrap();
    std::fs::write(
        dir.join("wizard.json"),
        r#"{
        "pages": [
            { "id": "cli", "title": "Pick", "fields": [
                { "id": "CODING_CLI", "type": "single_select", "default": "x" }
            ]}
        ]
    }"#,
    )
    .unwrap();

    let cfg = loader::load(&dir).expect("alt config should load");
    assert_eq!(cfg.catalog.project.name, "alt");
    assert_eq!(cfg.catalog.project.binary_name, "alt");
    assert_eq!(cfg.catalog.clis.len(), 1);
    assert_eq!(cfg.wizard.pages.len(), 1);
    assert_eq!(cfg.wizard.pages[0].id, "cli");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn project_meta_defaults_when_omitted() {
    let dir = tmp("defaults");
    std::fs::write(
        dir.join("catalog.json"),
        r#"{
        "clis": [], "tools": [], "plugins": []
    }"#,
    )
    .unwrap();
    std::fs::write(dir.join("wizard.json"), r#"{ "pages": [] }"#).unwrap();

    let cfg = loader::load(&dir).unwrap();
    let defaults = ProjectMeta::default();
    assert_eq!(cfg.catalog.project.name, defaults.name);
    assert_eq!(cfg.catalog.project.binary_name, defaults.binary_name);
    assert_eq!(cfg.catalog.project.default_cli, "claude");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn outro_template_substitutes_binary_name() {
    let p = ProjectMeta {
        binary_name: "ferris".into(),
        ..Default::default()
    };
    let rendered = p.outro_template.replace("{binary}", &p.binary_name);
    assert!(
        rendered.contains("ferris"),
        "binary substitution failed: {rendered}"
    );
    assert!(
        !rendered.contains("{binary}"),
        "placeholder leaked: {rendered}"
    );
}

#[test]
fn project_meta_round_trips_through_json() {
    let original = ProjectMeta {
        name: "roundtrip".into(),
        binary_name: "rt".into(),
        about: "a test".into(),
        container_name_default: "rt".into(),
        image_tag: "rt:latest".into(),
        data_dir_name: "rt-data".into(),
        ready_file: "/tmp/rt.ready".into(),
        etc_dir: "/etc/rt".into(),
        env_header: "# rt".into(),
        intro_template: "rt setup".into(),
        outro_template: "done {binary}".into(),
        default_cli: "rtcli".into(),
        category_order: vec!["A".into(), "B".into()],
    };
    let json = serde_json::to_string(&original).unwrap();
    let back: ProjectMeta = serde_json::from_str(&json).unwrap();
    assert_eq!(back.name, "roundtrip");
    assert_eq!(back.default_cli, "rtcli");
}

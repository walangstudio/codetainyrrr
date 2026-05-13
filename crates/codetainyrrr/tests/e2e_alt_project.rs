/// E2E: prove the binary is reusable for any project by pointing it at a
/// completely different catalog.json + wizard.json via --config-root.
///
/// We build a fake project ("widgetron") whose catalog has nothing in common
/// with codetainyrrr — different CLIs, different tools, different plugins —
/// then run `doctor` and `plugins list` and assert that the output reflects
/// the alt project, not the built-in codetainyrrr catalog.
use std::path::PathBuf;
use std::process::Command;

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_codetainyrrr"))
}

fn write_alt_project(dir: &std::path::Path) {
    let catalog = r##"{
      "project": {
        "name": "widgetron",
        "binary_name": "widgetron",
        "about": "Widgetron — totally different project",
        "container_name_default": "widgetron",
        "image_tag": "widgetron:latest",
        "data_dir_name": "widgetron-test",
        "ready_file": "/tmp/widgetron.ready",
        "etc_dir": "/etc/widgetron",
        "env_header": "# widgetron configuration",
        "intro_template": "  widgetron  ·  setup  ",
        "outro_template": "All set. Run '{binary} run'.",
        "default_cli": "wcli"
      },
      "clis": [
        { "key": "wcli", "name": "WidgetCLI", "description": "Widget orchestrator", "bin": "wcli", "install": "npm:@widgetron/cli" }
      ],
      "tools": [
        { "key": "widget-fmt", "category": "Formatters", "description": "Widget formatter", "install": "npm:widget-fmt" }
      ],
      "plugins": [
        { "key": "widget-stats", "category": "Observability", "description": "Widget stats overlay", "supported_clis": ["wcli"], "install": "npm:widget-stats" }
      ]
    }"##;
    let wizard = r##"{
      "pages": [
        { "id": "cli", "title": "Pick CLI", "description": "", "fields": [
          { "id": "CODING_CLI", "type": "single_select", "source": "catalog.clis", "default": "wcli" },
          { "id": "CONTAINER_NAME", "type": "text", "prompt": "Container:", "default": "widgetron" }
        ]}
      ]
    }"##;
    std::fs::write(dir.join("catalog.json"), catalog).unwrap();
    std::fs::write(dir.join("wizard.json"), wizard).unwrap();
}

fn run_with_config_env(
    args: &[&str],
    config_root: &std::path::Path,
    extra_env: &[(&str, &str)],
) -> (bool, String, String) {
    let mut cmd = Command::new(bin());
    cmd.arg("--config-root")
        .arg(config_root)
        .args(args)
        .env_remove("CODETAINYRRR_CONFIG_ROOT");
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("running binary");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn run_with_config(args: &[&str], config_root: &std::path::Path) -> (bool, String, String) {
    run_with_config_env(args, config_root, &[])
}

fn tmp_dir(name: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("ct-e2e-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn doctor_reads_alt_catalog() {
    let dir = tmp_dir("alt-doctor");
    write_alt_project(&dir);

    let (ok, stdout, stderr) = run_with_config(&["doctor"], &dir);
    assert!(ok, "doctor failed: stderr={stderr} stdout={stdout}");

    // Should list widgetron's items, not codetainyrrr's.
    assert!(
        stdout.contains("wcli"),
        "expected 'wcli' in doctor output:\n{stdout}"
    );
    assert!(
        stdout.contains("widget-fmt"),
        "expected 'widget-fmt' in doctor output:\n{stdout}"
    );
    assert!(
        !stdout.contains("claude"),
        "alt-project doctor leaked codetainyrrr catalog:\n{stdout}"
    );
    assert!(
        !stdout.contains("ccstatusline"),
        "alt-project doctor leaked codetainyrrr plugins:\n{stdout}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn plugins_list_reads_alt_catalog() {
    let dir = tmp_dir("alt-plugins");
    write_alt_project(&dir);

    let (ok, stdout, stderr) =
        run_with_config_env(&["plugins", "list"], &dir, &[("CODING_CLI", "wcli")]);
    assert!(ok, "plugins list failed: stderr={stderr} stdout={stdout}");

    // Default CLI from alt project's project.default_cli is "wcli", so widget-stats
    // (supported_clis=["wcli"]) should appear; codetainyrrr plugins must not.
    assert!(
        stdout.contains("widget-stats"),
        "expected 'widget-stats':\n{stdout}"
    );
    assert!(
        !stdout.contains("ccusage"),
        "alt-project plugins list leaked codetainyrrr:\n{stdout}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn missing_catalog_yields_clear_error() {
    let dir = tmp_dir("missing");
    let (ok, _stdout, stderr) = run_with_config(&["doctor"], &dir);
    assert!(!ok, "doctor should fail when catalog.json is missing");
    assert!(
        stderr.contains("catalog.json") || stderr.contains("reading"),
        "expected clear error mentioning catalog.json, got:\n{stderr}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

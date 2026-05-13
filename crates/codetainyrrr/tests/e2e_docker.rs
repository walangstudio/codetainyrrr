/// E2E: Docker smoke tests. Gated behind CT_E2E_DOCKER=1 because they require
/// a built image (`codetainyrrr:test`) and a running Docker daemon.
///
/// To run locally:
///   docker build -t codetainyrrr:test .
///   CT_E2E_DOCKER=1 cargo test --test e2e_docker
use std::process::Command;

fn skip_unless_enabled() -> bool {
    std::env::var("CT_E2E_DOCKER").ok().as_deref() != Some("1")
}

fn image() -> String {
    std::env::var("CT_E2E_IMAGE").unwrap_or_else(|_| "codetainyrrr:test".into())
}

fn docker(args: &[&str]) -> (bool, String, String) {
    let out = Command::new("docker").args(args).output().expect("docker not on PATH");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn version_inside_image() {
    if skip_unless_enabled() { return; }
    let (ok, stdout, stderr) = docker(&[
        "run", "--rm",
        "--entrypoint", "/usr/local/bin/codetainyrrr",
        &image(), "--version",
    ]);
    assert!(ok, "docker run --version failed: {stderr}");
    assert!(stdout.contains("codetainyrrr"), "version output: {stdout}");
}

#[test]
fn doctor_inside_image() {
    if skip_unless_enabled() { return; }
    let (ok, stdout, stderr) = docker(&[
        "run", "--rm",
        "--entrypoint", "/usr/local/bin/codetainyrrr",
        &image(), "doctor",
    ]);
    assert!(ok, "doctor failed: {stderr}");
    assert!(stdout.contains("AI CLIs"), "doctor missing header: {stdout}");
}

#[test]
fn plugins_list_inside_image() {
    if skip_unless_enabled() { return; }
    let (ok, stdout, stderr) = docker(&[
        "run", "--rm",
        "-e", "CODING_CLI=claude",
        "--entrypoint", "/usr/local/bin/codetainyrrr",
        &image(), "plugins", "list",
    ]);
    assert!(ok, "plugins list failed: {stderr}");
    assert!(stdout.contains("Plugins"), "plugins list missing header: {stdout}");
}

#[test]
fn entrypoint_daemon_writes_ready_file() {
    if skip_unless_enabled() { return; }
    let name = format!("ct_e2e_daemon_{}", std::process::id());
    let img  = image();

    let (ok, _, stderr) = docker(&[
        "run", "-d", "--name", &name,
        "-e", "CODING_CLI=none",
        "-e", "INSTALL_TOOLS=",
        "-e", "INSTALL_PLUGINS=",
        "--entrypoint", "/usr/local/bin/codetainyrrr",
        &img, "entrypoint", "--daemon",
    ]);
    assert!(ok, "docker run -d failed: {stderr}");

    // Give entrypoint a moment to write the ready file.
    std::thread::sleep(std::time::Duration::from_secs(2));

    let (cat_ok, cat_out, cat_err) = docker(&["exec", &name, "cat", "/tmp/codetainyrrr.ready"]);
    let _ = docker(&["rm", "-f", &name]);

    assert!(cat_ok, "cat ready file failed: {cat_err}");
    assert_eq!(cat_out.trim(), "1", "ready file contents wrong: {cat_out}");
}

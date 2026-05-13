/// E2E: every subcommand exposes --help with non-empty output.
/// Proves the CLI is fully wired through clap and discoverable.
use std::path::PathBuf;
use std::process::Command;

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_codetainyrrr"))
}

fn assert_help(args: &[&str]) {
    let out = Command::new(bin())
        .args(args)
        .arg("--help")
        .output()
        .unwrap_or_else(|e| panic!("running `{}`: {e}", args.join(" ")));

    assert!(
        out.status.success(),
        "{} --help failed (status={}): {}",
        args.join(" "),
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("Usage") || stdout.contains("USAGE"),
        "{} --help missing usage block:\n{stdout}",
        args.join(" ")
    );
}

#[test]
fn root_help_works() {
    assert_help(&[]);
}

#[test]
fn version_flag_works() {
    let out = Command::new(bin()).arg("--version").output().unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(!stdout.trim().is_empty(), "--version produced no output");
}

#[test]
fn every_subcommand_has_help() {
    for sub in [
        "setup", "reconfigure", "run", "stop", "connect",
        "switch", "plugins", "reset", "doctor", "entrypoint",
    ] {
        assert_help(&[sub]);
    }
}

#[test]
fn nested_plugins_subcommands_have_help() {
    for sub in ["add", "remove", "list"] {
        assert_help(&["plugins", sub]);
    }
}

#[test]
fn config_root_flag_is_global() {
    // Should appear under --help
    let out = Command::new(bin()).arg("--help").output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("--config-root"),
        "--config-root not advertised in root help:\n{stdout}"
    );
}

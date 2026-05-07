/// Tests for the EnvFile parser/writer.
use codetainyrrr::envfile::EnvFile;
use tempfile::NamedTempFile;

#[test]
fn parses_simple_key_value() {
    let env = EnvFile::parse("FOO=bar\nBAZ=qux\n");
    assert_eq!(env.get("FOO"), "bar");
    assert_eq!(env.get("BAZ"), "qux");
    assert_eq!(env.get("MISSING"), "");
}

#[test]
fn strips_double_quotes() {
    let env = EnvFile::parse(r#"KEY="hello world""#);
    assert_eq!(env.get("KEY"), "hello world");
}

#[test]
fn strips_inline_comments() {
    let env = EnvFile::parse("KEY=value # this is a comment\n");
    assert_eq!(env.get("KEY"), "value");
}

#[test]
fn skips_comment_lines() {
    let env = EnvFile::parse("# comment\nKEY=val\n");
    assert_eq!(env.get("KEY"), "val");
}

#[test]
fn skips_blank_lines() {
    let env = EnvFile::parse("\n\nKEY=val\n\n");
    assert_eq!(env.get("KEY"), "val");
}

#[test]
fn strips_utf8_bom() {
    let raw = "\u{feff}KEY=val\n";
    let env = EnvFile::parse(raw);
    assert_eq!(env.get("KEY"), "val");
}

#[test]
fn keys_csv_splits_correctly() {
    let env = EnvFile::parse("TOOLS=node,ts,rtk\n");
    let tools = env.keys_csv("TOOLS");
    assert_eq!(tools, vec!["node", "ts", "rtk"]);
}

#[test]
fn keys_csv_empty_returns_empty_vec() {
    let env = EnvFile::parse("TOOLS=\n");
    assert!(env.keys_csv("TOOLS").is_empty());
}

#[test]
fn set_and_get_roundtrip() {
    let mut env = EnvFile::default();
    env.set("FOO", "bar");
    assert_eq!(env.get("FOO"), "bar");
}

#[test]
fn write_and_load_roundtrip() {
    let mut env = EnvFile::default();
    env.set("CODING_CLI", "claude");
    env.set("PROJECT_DIR", "/tmp/my project");
    env.set("EMPTY_KEY", "");

    let tmp = NamedTempFile::new().unwrap();
    env.write(tmp.path(), "# test header").unwrap();

    let loaded = EnvFile::load(tmp.path()).unwrap();
    assert_eq!(loaded.get("CODING_CLI"), "claude");
    assert_eq!(loaded.get("PROJECT_DIR"), "/tmp/my project");
    assert_eq!(loaded.get("EMPTY_KEY"), "");
}

#[test]
fn write_quotes_values_with_spaces() {
    let mut env = EnvFile::default();
    env.set("NAME", "John Doe");

    let tmp = NamedTempFile::new().unwrap();
    env.write(tmp.path(), "").unwrap();

    let content = std::fs::read_to_string(tmp.path()).unwrap();
    assert!(content.contains(r#"NAME="John Doe""#), "expected quoted value, got: {content}");
}

#[test]
fn missing_file_returns_empty_envfile() {
    let env = EnvFile::load(std::path::Path::new("/nonexistent/.env.xyz")).unwrap();
    assert_eq!(env.get("ANYTHING"), "");
}

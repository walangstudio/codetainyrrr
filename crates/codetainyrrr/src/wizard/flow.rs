/// Page-driven wizard with Esc → Back navigation.
///
/// Each page is a function returning `Nav::Forward` (advance), `Nav::Back`
/// (rewind), or `Nav::Skip` (page condition failed, continue in last direction).
/// Esc at any cliclack prompt surfaces as `io::ErrorKind::Interrupted`; the
/// `ask!` macro turns that into `Nav::Back` so every prompt type — input,
/// password, select, multiselect, confirm — supports going back uniformly.
use anyhow::Result;
use cliclack::{confirm, input, intro, multiselect, outro, password, select};

use crate::config::{Catalog, FieldType, WizardDef, schema::WizardPage};
use crate::envfile::EnvFile;

#[derive(Debug, Clone, Copy)]
enum Nav {
    Forward,
    Back,
    Skip,
}

/// Wrap a cliclack `interact()` call: surface Esc as `Nav::Back`, errors propagate.
macro_rules! ask {
    ($e:expr) => {
        match $e {
            Ok(v) => v,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => return Ok(Nav::Back),
            Err(e) => return Err(e.into()),
        }
    };
}

fn eval_condition(expr: &str, env: &EnvFile) -> bool {
    let s = expr.trim();
    let extract = |op: &str| -> Option<(String, String)> {
        let (lhs, rhs) = s.split_once(op)?;
        let var = lhs.trim().trim_start_matches("${").trim_end_matches('}').trim().to_string();
        let lit = rhs.trim().trim_matches('\'').trim_matches('"').to_string();
        Some((var, lit))
    };
    if let Some((v, lit)) = extract("==") { return env.get(&v) == lit; }
    if let Some((v, lit)) = extract("!=") { return env.get(&v) != lit; }
    if let Some((v, lit)) = s.split_once(" in ").and_then(|(l, r)| {
        let var = l.trim().trim_start_matches("${").trim_end_matches('}').trim().to_string();
        let lit = r.trim().trim_matches('\'').trim_matches('"').to_string();
        Some((var, lit))
    }) {
        return lit.split(',').map(|x| x.trim()).any(|x| x == env.get(&v));
    }
    true
}

fn page_by_id<'a>(wizard: &'a WizardDef, id: &str) -> &'a WizardPage {
    wizard.pages.iter().find(|p| p.id == id)
        .unwrap_or_else(|| panic!("wizard.json missing required page id '{id}'"))
}

fn page_should_run(page: &WizardPage, env: &EnvFile) -> bool {
    page.condition.as_deref().map(|c| eval_condition(c, env)).unwrap_or(true)
}

// ── Pages ────────────────────────────────────────────────────────────────────

fn page_cli(wizard: &WizardDef, catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "cli");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    let current_cli = env.get("CODING_CLI").to_string();
    let default_cli = if current_cli.is_empty() { catalog.project.default_cli.as_str() } else { &current_cli };

    let mut sel = select(format!("{}  {}", page.title, page.description));
    for c in &catalog.clis {
        sel = sel.item(c.key.as_str(), c.name.as_str(), c.description.as_str());
    }
    let cli_val: &str = ask!(sel.initial_value(default_cli).interact());
    env.set("CODING_CLI", cli_val);

    let container_field = page.fields.iter().find(|f| f.id == "CONTAINER_NAME").unwrap();
    let default_container = {
        let current = env.get("CONTAINER_NAME").to_string();
        if current.is_empty() { container_field.default.clone() } else { current }
    };
    let container_val: String = ask!(input(&container_field.prompt)
        .default_input(&default_container)
        .interact());
    env.set("CONTAINER_NAME", if container_val.is_empty() { &default_container } else { &container_val });

    Ok(Nav::Forward)
}

fn page_paths(wizard: &WizardDef, _catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "paths");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    let proj_field = page.fields.iter().find(|f| f.id == "PROJECT_DIR").unwrap();
    let current = env.get("PROJECT_DIR").to_string();

    let project_dir: String = ask!(input(&proj_field.prompt)
        .default_input(&current)
        .validate(|v: &String| {
            if v.is_empty() { Err("Project directory is required") } else { Ok(()) }
        })
        .interact());
    env.set("PROJECT_DIR", &project_dir);

    let extra_ws: String = ask!(input("Extra workspaces (semicolon-separated, or blank):")
        .default_input(env.get("EXTRA_WORKSPACES"))
        .required(false)
        .interact());
    env.set("EXTRA_WORKSPACES", &extra_ws);

    Ok(Nav::Forward)
}

fn page_claude(wizard: &WizardDef, _catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "claude_settings");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    let share: bool = ask!(confirm(format!("{} — {}", page.title, page.hint))
        .initial_value(!env.get("CLAUDE_DIR").is_empty())
        .interact());

    if share {
        let dir_field  = page.fields.iter().find(|f| f.id == "CLAUDE_DIR").unwrap();
        let json_field = page.fields.iter().find(|f| f.id == "CLAUDE_JSON").unwrap();

        let claude_dir: String = ask!(input(&dir_field.prompt)
            .default_input(env.get("CLAUDE_DIR"))
            .required(dir_field.required)
            .interact());
        env.set("CLAUDE_DIR", &claude_dir);

        let claude_json: String = ask!(input(&json_field.prompt)
            .default_input(env.get("CLAUDE_JSON"))
            .required(json_field.required)
            .interact());
        env.set("CLAUDE_JSON", &claude_json);
    } else {
        env.set("CLAUDE_DIR", "");
        env.set("CLAUDE_JSON", "");
    }

    Ok(Nav::Forward)
}

fn page_keys(wizard: &WizardDef, catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "api_keys");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    let cli_key = env.get("CODING_CLI").to_string();
    let needed: Vec<String> = if page.auto_keys {
        catalog.clis.iter()
            .find(|c| c.key == cli_key)
            .map(|c| c.needs_keys.clone())
            .unwrap_or_default()
    } else {
        page.fields.iter()
            .filter(|f| f.field_type == FieldType::Secret)
            .map(|f| f.id.clone())
            .collect()
    };

    if needed.is_empty() {
        cliclack::log::info(format!(
            "{} requires no API keys (OAuth or no auth). Skipping.", cli_key
        ))?;
        return Ok(Nav::Forward);
    }

    for key_id in &needed {
        let field = page.fields.iter().find(|f| &f.id == key_id);
        let required = field.map(|f| f.required).unwrap_or(true);
        let prompt_text = field
            .map(|f| f.prompt.clone())
            .unwrap_or_else(|| format!("{key_id}:"));
        let hint = field
            .map(|f| f.hint.clone())
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| {
                if required { "required".into() } else { "blank = keep existing or skip".into() }
            });

        let current = env.get(key_id).to_string();
        let mut prompt = password(format!("{prompt_text} — {hint}"));
        if !required {
            prompt = prompt.allow_empty();
        }
        let new_val: String = ask!(prompt.interact());
        if !new_val.is_empty() {
            env.set(key_id, &new_val);
        } else if current.is_empty() && required {
            cliclack::log::warning(format!(
                "{key_id} is empty — {cli_key} may not work without it."
            ))?;
        }
    }

    Ok(Nav::Forward)
}

fn page_git(wizard: &WizardDef, _catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "git_identity");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    for field in &page.fields {
        let current = env.get(&field.id).to_string();
        let val: String = ask!(input(&field.prompt)
            .default_input(&current)
            .required(field.required)
            .interact());
        env.set(&field.id, &val);
    }

    Ok(Nav::Forward)
}

/// Sort a list of (category, key) by (category_order index, key). Categories
/// not in the explicit order list go to the bottom alphabetically.
fn category_rank(category: &str, order: &[String]) -> (usize, String) {
    match order.iter().position(|c| c == category) {
        Some(i) => (i, String::new()),
        None    => (order.len(), category.to_string()),
    }
}

fn format_item_label(key: &str, description: &str, key_pad: usize) -> String {
    if description.is_empty() {
        key.to_string()
    } else {
        format!("{:<width$}  {}", key, description, width = key_pad)
    }
}

/// Render a multi-category multiselect by emitting one independent multiselect
/// per category. cliclack 0.3 has no separator API, so this is the only way to
/// get "header text, then list of checkboxes" rather than headers tangled into
/// item rows. Esc on any category bubbles up as Nav::Back to the prior page.
trait Selectable {
    fn key(&self) -> &str;
    fn category(&self) -> &str;
    fn description(&self) -> &str;
    fn default_picked(&self) -> bool;
}

impl Selectable for &crate::config::schema::CatalogTool {
    fn key(&self) -> &str { &self.key }
    fn category(&self) -> &str { &self.category }
    fn description(&self) -> &str { &self.description }
    fn default_picked(&self) -> bool { self.default }
}

impl Selectable for &crate::config::schema::CatalogPlugin {
    fn key(&self) -> &str { &self.key }
    fn category(&self) -> &str { &self.category }
    fn description(&self) -> &str { &self.description }
    fn default_picked(&self) -> bool { self.default }
}

fn run_grouped_multiselect<T: Selectable>(
    items: &[T],
    category_order: &[String],
    current_csv_keys: &[String],
) -> std::result::Result<Vec<String>, std::io::Error> {
    use std::collections::BTreeMap;

    let mut groups: BTreeMap<(usize, String), Vec<&T>> = BTreeMap::new();
    for it in items {
        let rank = category_rank(it.category(), category_order);
        groups.entry(rank).or_default().push(it);
    }
    for v in groups.values_mut() {
        v.sort_by(|a, b| a.key().cmp(b.key()));
    }

    let mut chosen: Vec<String> = Vec::new();
    for ((_, _), members) in &groups {
        let category = members[0].category();
        let key_pad = members.iter().map(|m| m.key().len()).max().unwrap_or(0).max(8);

        let initial: Vec<&str> = members.iter()
            .filter(|m| {
                if current_csv_keys.is_empty() { m.default_picked() }
                else { current_csv_keys.iter().any(|k| k == m.key()) }
            })
            .map(|m| m.key())
            .collect();

        let labels: Vec<String> = members.iter()
            .map(|m| format_item_label(m.key(), m.description(), key_pad))
            .collect();

        let mut ms = multiselect(category).required(false);
        for (m, lbl) in members.iter().zip(labels.iter()) {
            ms = ms.item(m.key(), lbl.as_str(), "");
        }
        let picked: Vec<&str> = ms.initial_values(initial).interact()?;
        chosen.extend(picked.iter().map(|s| s.to_string()));
    }
    Ok(chosen)
}

fn page_tools(wizard: &WizardDef, catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "tools");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    let cli = env.get("CODING_CLI").to_string();
    let current_tools = env.keys_csv("INSTALL_TOOLS");
    let order = &catalog.project.category_order;

    let filtered: Vec<&crate::config::schema::CatalogTool> =
        catalog.tools.iter().filter(|t| t.supports_cli(&cli)).collect();

    cliclack::log::info(format!("{}  {}", page.title, page.description))?;
    let chosen: Vec<String> = ask!(run_grouped_multiselect(&filtered, order, &current_tools));
    env.set("INSTALL_TOOLS", &chosen.join(","));

    Ok(Nav::Forward)
}

fn page_plugins(wizard: &WizardDef, catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "plugins");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    let cli = env.get("CODING_CLI").to_string();
    let current_plugins = env.keys_csv("INSTALL_PLUGINS");
    let order = &catalog.project.category_order;

    let filtered: Vec<&crate::config::schema::CatalogPlugin> =
        catalog.plugins.iter().filter(|p| p.supports_cli(&cli)).collect();

    cliclack::log::info(format!("{}  {}", page.title, page.description))?;
    let chosen: Vec<String> = ask!(run_grouped_multiselect(&filtered, order, &current_plugins));
    env.set("INSTALL_PLUGINS", &chosen.join(","));

    Ok(Nav::Forward)
}

fn page_custom(wizard: &WizardDef, _catalog: &Catalog, env: &mut EnvFile) -> Result<Nav> {
    let page = page_by_id(wizard, "custom_configs");
    if !page_should_run(page, env) { return Ok(Nav::Skip); }

    for field in &page.fields {
        if field.field_type == FieldType::Path {
            let current = env.get(&field.id).to_string();
            let placeholder = if current.is_empty() { "blank = built-in default" } else { &current };
            let val: String = ask!(input(&field.prompt)
                .placeholder(placeholder)
                .default_input(&current)
                .required(field.required)
                .interact());
            env.set(&field.id, &val);
        }
    }

    Ok(Nav::Forward)
}

// ── Driver ───────────────────────────────────────────────────────────────────

type PageFn = fn(&WizardDef, &Catalog, &mut EnvFile) -> Result<Nav>;

const PAGES: &[PageFn] = &[
    page_cli, page_paths, page_claude, page_keys,
    page_git, page_tools, page_plugins, page_custom,
];

pub async fn run_wizard(
    wizard: &WizardDef,
    catalog: &Catalog,
    existing: EnvFile,
) -> Result<EnvFile> {
    super::theme::apply("neon");
    intro(catalog.project.intro_template.as_str())?;
    cliclack::log::info("Press Esc at any prompt to go back. Ctrl-C to quit.")?;

    let mut env = existing.clone();
    let mut i: i32 = 0;
    let mut direction: i32 = 1; // remembered direction so condition-failed pages skip in the right way

    while (i as usize) < PAGES.len() {
        if i < 0 { i = 0; direction = 1; continue; }

        match PAGES[i as usize](wizard, catalog, &mut env)? {
            Nav::Forward => { i += 1; direction = 1; }
            Nav::Back    => { i -= 1; direction = -1; }
            Nav::Skip    => { i += direction; }
        }
    }

    outro(catalog.project.outro_template.replace("{binary}", &catalog.project.binary_name))?;
    Ok(env)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_with(k: &str, v: &str) -> EnvFile {
        let mut e = EnvFile::default();
        e.set(k, v);
        e
    }

    #[test]
    fn eq_matches() {
        let env = env_with("CODING_CLI", "claude");
        assert!(eval_condition("${CODING_CLI} == 'claude'", &env));
        assert!(!eval_condition("${CODING_CLI} == 'codex'", &env));
    }

    #[test]
    fn ne_matches() {
        let env = env_with("CODING_CLI", "claude");
        assert!(eval_condition("${CODING_CLI} != 'codex'", &env));
        assert!(!eval_condition("${CODING_CLI} != 'claude'", &env));
    }

    #[test]
    fn in_list_matches() {
        let env = env_with("CODING_CLI", "aider");
        assert!(eval_condition("${CODING_CLI} in 'aider,codex,gemini'", &env));
        assert!(!eval_condition("${CODING_CLI} in 'claude,opencode'", &env));
    }

    #[test]
    fn empty_var_treated_as_empty_string() {
        let env = EnvFile::default();
        assert!(eval_condition("${MISSING} == ''", &env));
        assert!(eval_condition("${MISSING} != 'x'", &env));
    }

    #[test]
    fn malformed_expression_fails_open() {
        let env = env_with("CODING_CLI", "claude");
        assert!(eval_condition("garbage expression", &env));
        assert!(eval_condition("", &env));
    }
}

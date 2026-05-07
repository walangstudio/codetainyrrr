/// Generic page-driver wizard using cliclack 0.3.x.
use anyhow::Result;
use cliclack::{confirm, input, intro, multiselect, outro, password, select};

use crate::config::{Catalog, FieldType, WizardDef};
use crate::envfile::EnvFile;

pub async fn run_wizard(
    wizard: &WizardDef,
    catalog: &Catalog,
    existing: EnvFile,
) -> Result<EnvFile> {
    super::theme::apply("neon");
    intro("  codetainyrrr  ·  setup  ")?;

    let mut env = existing.clone();

    // ── Page 1: CLI + container name ─────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "cli").unwrap();
        let current_cli = env.get("CODING_CLI").to_string();
        let default_cli = if current_cli.is_empty() { "claude" } else { &current_cli };

        let mut sel = select(format!("{}  {}", page.title, page.description));
        for c in &catalog.clis {
            sel = sel.item(c.key.as_str(), c.name.as_str(), c.description.as_str());
        }
        let cli_val: &str = sel.initial_value(default_cli).interact()?;
        env.set("CODING_CLI", cli_val);

        let container_field = page.fields.iter().find(|f| f.id == "CONTAINER_NAME").unwrap();
        let default_container = {
            let current = env.get("CONTAINER_NAME").to_string();
            if current.is_empty() { container_field.default.clone() } else { current }
        };
        let container_val: String = input(&container_field.prompt)
            .default_input(&default_container)
            .interact()?;
        env.set("CONTAINER_NAME", if container_val.is_empty() { &default_container } else { &container_val });
    }

    // ── Page 2: Project directory ─────────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "paths").unwrap();
        let proj_field = page.fields.iter().find(|f| f.id == "PROJECT_DIR").unwrap();
        let current = env.get("PROJECT_DIR").to_string();

        let project_dir: String = input(&proj_field.prompt)
            .default_input(&current)
            .validate(|v: &String| {
                if v.is_empty() { Err("Project directory is required") } else { Ok(()) }
            })
            .interact()?;
        env.set("PROJECT_DIR", &project_dir);

        let extra_ws: String = input("Extra workspaces (semicolon-separated, or blank):")
            .default_input(env.get("EXTRA_WORKSPACES"))
            .interact()?;
        env.set("EXTRA_WORKSPACES", &extra_ws);
    }

    // ── Page 3: Claude settings ───────────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "claude_settings").unwrap();
        let share: bool = confirm(format!("{} — {}", page.title, page.hint))
            .initial_value(!env.get("CLAUDE_DIR").is_empty())
            .interact()?;

        if share {
            let dir_field  = page.fields.iter().find(|f| f.id == "CLAUDE_DIR").unwrap();
            let json_field = page.fields.iter().find(|f| f.id == "CLAUDE_JSON").unwrap();

            let claude_dir: String = input(&dir_field.prompt)
                .default_input(env.get("CLAUDE_DIR"))
                .interact()?;
            env.set("CLAUDE_DIR", &claude_dir);

            let claude_json: String = input(&json_field.prompt)
                .default_input(env.get("CLAUDE_JSON"))
                .interact()?;
            env.set("CLAUDE_JSON", &claude_json);
        } else {
            env.set("CLAUDE_DIR", "");
            env.set("CLAUDE_JSON", "");
        }
    }

    // ── Page 4: API keys ──────────────────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "api_keys").unwrap();
        let anth_field  = page.fields.iter().find(|f| f.id == "ANTHROPIC_API_KEY").unwrap();
        let current_key = env.get("ANTHROPIC_API_KEY").to_string();
        let hint = if current_key.is_empty() { anth_field.hint.as_str() } else { "(blank = keep existing)" };

        let new_key: String = password(format!("{} — {hint}", anth_field.prompt))
            .interact()?;
        if !new_key.is_empty() {
            env.set("ANTHROPIC_API_KEY", &new_key);
        }

        let set_extra: bool = confirm("Set additional provider keys? (OpenAI, OpenRouter, Gemini)")
            .initial_value(false)
            .interact()?;

        if set_extra {
            for field_id in &["OPENAI_API_KEY", "OPENROUTER_API_KEY", "GEMINI_API_KEY"] {
                if let Some(field) = page.fields.iter().find(|f| f.id.as_str() == *field_id) {
                    let current = env.get(field_id).to_string();
                    let val: String = password(format!("{} (blank = keep)", field.prompt))
                        .interact()?;
                    if !val.is_empty() {
                        env.set(*field_id, &val);
                    } else if !current.is_empty() {
                        env.set(*field_id, &current);
                    }
                }
            }
        }
    }

    // ── Page 5: Git identity ──────────────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "git_identity").unwrap();
        for field in &page.fields {
            let current = env.get(&field.id).to_string();
            let val: String = input(&field.prompt)
                .default_input(&current)
                .interact()?;
            env.set(&field.id, &val);
        }
    }

    // ── Page 6: Dev tools ─────────────────────────────────────────────────────
    {
        let page  = wizard.pages.iter().find(|p| p.id == "tools").unwrap();
        let cli   = env.get("CODING_CLI").to_string();
        let current_tools = env.keys_csv("INSTALL_TOOLS");

        let filtered: Vec<_> = catalog.tools.iter().filter(|t| t.supports_cli(&cli)).collect();
        let initial: Vec<&str> = filtered
            .iter()
            .filter(|t| {
                if current_tools.is_empty() { t.default } else { current_tools.contains(&t.key) }
            })
            .map(|t| t.key.as_str())
            .collect();

        let mut ms = multiselect(format!("{}  {}", page.title, page.description)).filter_mode();
        for t in &filtered {
            ms = ms.item(t.key.as_str(), t.description.as_str(), t.category.as_str());
        }
        let tools: Vec<&str> = ms.initial_values(initial).interact()?;
        env.set("INSTALL_TOOLS", &tools.join(","));
    }

    // ── Page 7: Plugins ───────────────────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "plugins").unwrap();
        let cli  = env.get("CODING_CLI").to_string();
        let current_plugins = env.keys_csv("INSTALL_PLUGINS");

        let filtered: Vec<_> = catalog.plugins.iter().filter(|p| p.supports_cli(&cli)).collect();
        let initial: Vec<&str> = filtered
            .iter()
            .filter(|p| {
                if current_plugins.is_empty() { p.default } else { current_plugins.contains(&p.key) }
            })
            .map(|p| p.key.as_str())
            .collect();

        let mut ms = multiselect(format!("{}  {}", page.title, page.description)).filter_mode();
        for p in &filtered {
            ms = ms.item(p.key.as_str(), p.description.as_str(), p.category.as_str());
        }
        let plugins: Vec<&str> = ms.initial_values(initial).interact()?;
        env.set("INSTALL_PLUGINS", &plugins.join(","));
    }

    // ── Page 8: Custom configs ────────────────────────────────────────────────
    {
        let page = wizard.pages.iter().find(|p| p.id == "custom_configs").unwrap();
        for field in &page.fields {
            if field.field_type == FieldType::Path {
                let current = env.get(&field.id).to_string();
                let placeholder = if current.is_empty() { "blank = use built-in" } else { &current };
                let val: String = input(&field.prompt)
                    .placeholder(placeholder)
                    .default_input(&current)
                    .interact()?;
                env.set(&field.id, &val);
            }
        }
    }

    outro("Configuration complete. Run 'codetainyrrr run' to start your container.")?;
    Ok(env)
}

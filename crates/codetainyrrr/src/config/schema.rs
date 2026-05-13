use serde::{Deserialize, Serialize};

// ── catalog.json ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Catalog {
    #[serde(default)]
    pub project: ProjectMeta,
    #[serde(default)]
    pub clis: Vec<CatalogCli>,
    #[serde(default)]
    pub tools: Vec<CatalogTool>,
    #[serde(default)]
    pub plugins: Vec<CatalogPlugin>,
}

/// Project-level metadata. All fields optional in the JSON; defaults preserve
/// the original `codetainyrrr` behavior so existing catalog.json keeps working.
/// Drop a different ProjectMeta into a sibling catalog.json and the same binary
/// rebrands itself for a new project.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ProjectMeta {
    #[serde(default = "default_name")]
    pub name: String,
    #[serde(default = "default_name")]
    pub binary_name: String,
    #[serde(default = "default_about")]
    pub about: String,
    #[serde(default = "default_name")]
    pub container_name_default: String,
    #[serde(default = "default_image_tag")]
    pub image_tag: String,
    #[serde(default = "default_name")]
    pub data_dir_name: String,
    #[serde(default = "default_ready_file")]
    pub ready_file: String,
    #[serde(default = "default_etc_dir")]
    pub etc_dir: String,
    #[serde(default = "default_env_header")]
    pub env_header: String,
    #[serde(default = "default_intro")]
    pub intro_template: String,
    #[serde(default = "default_outro")]
    pub outro_template: String,
    #[serde(default = "default_default_cli")]
    pub default_cli: String,
    /// Display order for catalog categories in the wizard's tools/plugins
    /// multiselects. Categories not listed here fall through to the bottom in
    /// alphabetical order. Empty => alphabetical for all.
    #[serde(default)]
    pub category_order: Vec<String>,
}

impl Default for ProjectMeta {
    fn default() -> Self {
        Self {
            name: default_name(),
            binary_name: default_name(),
            about: default_about(),
            container_name_default: default_name(),
            image_tag: default_image_tag(),
            data_dir_name: default_name(),
            ready_file: default_ready_file(),
            etc_dir: default_etc_dir(),
            env_header: default_env_header(),
            intro_template: default_intro(),
            outro_template: default_outro(),
            default_cli: default_default_cli(),
            category_order: vec![],
        }
    }
}

fn default_name()        -> String { "codetainyrrr".into() }
fn default_about()       -> String { "AI coding container — setup, run, manage".into() }
fn default_image_tag()   -> String { "codetainyrrr:latest".into() }
fn default_ready_file()  -> String { "/tmp/codetainyrrr.ready".into() }
fn default_etc_dir()     -> String { "/etc/codetainyrrr".into() }
fn default_env_header()  -> String { "# codetainyrrr configuration".into() }
fn default_intro()       -> String { "  codetainyrrr  ·  setup  ".into() }
fn default_outro()       -> String { "Configuration complete. Run '{binary} run' to start your container.".into() }
fn default_default_cli() -> String { "claude".into() }

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CatalogCli {
    pub key: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub needs_keys: Vec<String>,
    #[serde(default)]
    pub oauth_supported: bool,
    pub bin: String,
    pub install: String,
    /// Other catalog keys this entry requires before it can install.
    #[serde(default)]
    pub dependencies: Vec<String>,
    /// Shell commands to run after the install handler succeeds.
    /// Each runs via `bash -c`. Use this for tools that need a per-project
    /// initialization step (e.g. `npx ruvflo init`) so the user never has to
    /// run anything by hand.
    #[serde(default)]
    pub post_install: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CatalogTool {
    pub key: String,
    pub name: Option<String>,
    pub category: String,
    #[serde(default)]
    pub default: bool,
    #[serde(default = "default_supported_clis")]
    pub supported_clis: Vec<String>,
    #[serde(default)]
    pub description: String,
    pub install: Option<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    #[serde(default)]
    pub post_install: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CatalogPlugin {
    pub key: String,
    pub name: Option<String>,
    pub category: String,
    #[serde(default)]
    pub default: bool,
    #[serde(default = "default_supported_clis")]
    pub supported_clis: Vec<String>,
    #[serde(default)]
    pub description: String,
    pub install: Option<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    #[serde(default)]
    pub post_install: Vec<String>,
}

fn default_supported_clis() -> Vec<String> {
    vec!["*".to_string()]
}

impl CatalogTool {
    pub fn supports_cli(&self, cli: &str) -> bool {
        self.supported_clis.iter().any(|c| c == "*" || c == cli)
    }
}

impl CatalogPlugin {
    pub fn supports_cli(&self, cli: &str) -> bool {
        self.supported_clis.iter().any(|c| c == "*" || c == cli)
    }
}

// ── wizard.json ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WizardDef {
    pub pages: Vec<WizardPage>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WizardPage {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub hint: String,
    #[serde(default)]
    pub fields: Vec<WizardField>,
    /// Skip this page if the condition evaluates false.
    /// Syntax: `${VAR} == 'literal'`, `${VAR} != 'literal'`, `${VAR} in 'a,b,c'`.
    #[serde(default)]
    pub condition: Option<String>,
    /// When true, the page emits one secret prompt per `needs_keys` entry of
    /// the currently selected CLI in catalog.json. Hardcoded field list is ignored.
    #[serde(default)]
    pub auto_keys: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WizardField {
    pub id: String,
    #[serde(rename = "type")]
    pub field_type: FieldType,
    #[serde(default)]
    pub prompt: String,
    #[serde(default)]
    pub default: String,
    #[serde(default)]
    pub hint: String,
    pub source: Option<String>,
    /// If false, blank input is accepted; if true (the default), the field
    /// re-prompts on empty. Both wizard pages and config files can override.
    #[serde(default = "default_required")]
    pub required: bool,
    /// Skip this individual field if the condition evaluates false.
    /// Same syntax as WizardPage.condition.
    #[serde(default)]
    pub condition: Option<String>,
}

fn default_required() -> bool { true }

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum FieldType {
    Text,
    Secret,
    Path,
    PathList,
    Toggle,
    SingleSelect,
    Multiselect,
}

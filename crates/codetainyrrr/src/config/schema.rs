use serde::{Deserialize, Serialize};

// ── catalog.json ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Catalog {
    #[serde(default)]
    pub clis: Vec<CatalogCli>,
    #[serde(default)]
    pub tools: Vec<CatalogTool>,
    #[serde(default)]
    pub plugins: Vec<CatalogPlugin>,
}

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
}

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

/// Theme application. cliclack 0.3.x uses a different Theme API than 0.5.x.
/// Full custom themes are Phase 5 polish; for now we just apply the default.
pub fn apply(_preset: &str) {
    // cliclack 0.3.x has set_theme() but the ThemeState / Theme trait signatures
    // changed significantly across minor versions. Custom themes are deferred to
    // Phase 5 once we pin to a stable cliclack release.
}

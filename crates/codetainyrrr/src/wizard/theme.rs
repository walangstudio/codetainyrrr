use cliclack::{set_theme, Theme, ThemeState};
use console::Style;

pub struct NeonTheme;

impl Theme for NeonTheme {
    fn bar_color(&self, state: &ThemeState) -> Style {
        match state {
            ThemeState::Active  => Style::new().color256(141), // violet
            ThemeState::Cancel  => Style::new().red(),
            ThemeState::Submit  => Style::new().color256(61),  // muted indigo
            ThemeState::Error(_)=> Style::new().color256(214), // amber
        }
    }

    fn state_symbol_color(&self, state: &ThemeState) -> Style {
        match state {
            ThemeState::Submit  => Style::new().color256(78),  // neon green
            ThemeState::Active  => Style::new().color256(141), // violet
            _ => self.bar_color(state),
        }
    }

    fn radio_symbol(&self, state: &ThemeState, selected: bool) -> String {
        use console::style;
        use cliclack::ThemeState::*;
        match state {
            Active if  selected => style("●").color256(141).to_string(),
            Active if !selected => style("○").dim().to_string(),
            _ => String::new(),
        }
    }

    fn checkbox_symbol(&self, state: &ThemeState, selected: bool, active: bool) -> String {
        use console::style;
        use cliclack::ThemeState::*;
        match state {
            Active | Error(_) => {
                if selected {
                    style("◼").color256(78).to_string()
                } else if active {
                    style("◻").color256(141).to_string()
                } else {
                    style("◻").dim().to_string()
                }
            }
            _ => String::new(),
        }
    }
}

pub fn apply(preset: &str) {
    match preset {
        "neon" | _ => set_theme(NeonTheme),
    }
}

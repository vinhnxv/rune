use crossterm::event::{KeyCode, KeyEvent, KeyEventKind};

use crate::app::{Action, App, AppView};

/// Handle a key event and return the corresponding action.
/// Only processes Press events to avoid double-firing on key release.
pub fn handle_key(app: &App, key: KeyEvent) -> Action {
    if key.kind != KeyEventKind::Press {
        return Action::None;
    }

    match app.view {
        AppView::Selection => handle_selection_key(app, key),
        AppView::Running => handle_running_key(key),
    }
}

fn handle_selection_key(app: &App, key: KeyEvent) -> Action {
    match key.code {
        KeyCode::Char('q') => Action::Quit,
        KeyCode::Char('r') => {
            // Only allow run when config is selected and at least 1 plan toggled
            if !app.config_dirs.is_empty() && !app.selected_plans.is_empty() {
                Action::RunSelected
            } else {
                Action::None
            }
        }
        KeyCode::Char('a') => Action::ToggleAll,
        KeyCode::Tab => Action::SwitchPanel,
        KeyCode::Enter => Action::SelectConfig,
        KeyCode::Char(' ') => Action::TogglePlan,
        KeyCode::Up => Action::MoveUp,
        KeyCode::Down => Action::MoveDown,
        _ => Action::None,
    }
}

fn handle_running_key(key: KeyEvent) -> Action {
    match key.code {
        KeyCode::Char('q') => Action::Quit,
        KeyCode::Char('a') => Action::AttachTmux,
        KeyCode::Char('s') => Action::SkipPlan,
        KeyCode::Char('k') => Action::KillSession,
        KeyCode::Up => Action::MoveUp,
        KeyCode::Down => Action::MoveDown,
        _ => Action::None,
    }
}

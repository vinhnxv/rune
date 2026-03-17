use crossterm::event::{KeyCode, KeyEvent, KeyEventKind};

use crate::app::{Action, App, AppView};

/// Handle a key event and return the corresponding action.
/// Only processes Press events to avoid double-firing on key release.
pub fn handle_key(app: &App, key: KeyEvent) -> Action {
    if key.kind != KeyEventKind::Press {
        return Action::None;
    }

    match app.view {
        AppView::ActiveArcs => handle_active_arcs_key(app, key),
        AppView::Selection if app.queue_editing => handle_queue_edit_key(app, key),
        AppView::Selection => handle_selection_key(app, key),
        AppView::Running => handle_running_key(key),
    }
}

fn handle_active_arcs_key(app: &App, key: KeyEvent) -> Action {
    match key.code {
        KeyCode::Char('q') => Action::Quit,
        KeyCode::Char('a') => Action::AttachActiveArc,
        KeyCode::Char('m') | KeyCode::Enter => Action::MonitorActiveArc,
        KeyCode::Char('n') | KeyCode::Esc => Action::DismissActiveArcs,
        KeyCode::Up => Action::MoveUp,
        KeyCode::Down => Action::MoveDown,
        _ => {
            // If no active arcs have tmux sessions, allow dismiss on any key
            if app.active_arcs.is_empty() {
                Action::DismissActiveArcs
            } else {
                Action::None
            }
        }
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
        KeyCode::Char('p') => Action::PickPlans,
        KeyCode::Char('d') => Action::RemoveFromQueue,
        KeyCode::Up => Action::MoveUp,
        KeyCode::Down => Action::MoveDown,
        _ => Action::None,
    }
}

/// Queue-edit mode: Selection view while arc is running.
/// Different keybindings: Enter/r = append, Esc/q = cancel.
fn handle_queue_edit_key(app: &App, key: KeyEvent) -> Action {
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') => Action::CancelQueueEdit,
        KeyCode::Char('r') | KeyCode::Enter if !app.selected_plans.is_empty() => {
            Action::AppendToQueue
        }
        KeyCode::Char('a') => Action::ToggleAll,
        KeyCode::Tab => Action::SwitchPanel,
        KeyCode::Char(' ') => Action::TogglePlan,
        KeyCode::Up => Action::MoveUp,
        KeyCode::Down => Action::MoveDown,
        _ => Action::None,
    }
}

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
        AppView::Running => handle_running_key(app, key),
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

fn handle_running_key(app: &App, key: KeyEvent) -> Action {
    // Contextual 's' dispatch: during grace period → SkipGrace; otherwise → SkipPlan.
    // This resolves the key conflict where 's' was previously always SkipPlan.
    let grace_active = app.current_run
        .as_ref()
        .and_then(|r| r.merge_detected_at)
        .is_some();

    match key.code {
        KeyCode::Char('q') => Action::Quit,
        KeyCode::Char('a') => Action::AttachTmux,
        KeyCode::Char('s') if grace_active => Action::SkipGrace,
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
/// Tab to switch panels, Enter = select config (Config panel) or append (Plan panel).
fn handle_queue_edit_key(app: &App, key: KeyEvent) -> Action {
    use crate::app::Panel;
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') => Action::CancelQueueEdit,
        KeyCode::Char('r') if !app.selected_plans.is_empty() => Action::AppendToQueue,
        KeyCode::Enter => {
            match app.active_panel {
                Panel::ConfigList => Action::SelectConfig,
                Panel::PlanList if !app.selected_plans.is_empty() => Action::AppendToQueue,
                _ => Action::None,
            }
        }
        KeyCode::Char('a') => Action::ToggleAll,
        KeyCode::Tab => Action::SwitchPanel,
        KeyCode::Char(' ') => {
            match app.active_panel {
                Panel::PlanList => Action::TogglePlan,
                Panel::ConfigList => Action::SelectConfig,
            }
        }
        KeyCode::Up => Action::MoveUp,
        KeyCode::Down => Action::MoveDown,
        _ => Action::None,
    }
}

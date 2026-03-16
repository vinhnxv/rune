use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};

use crate::app::{App, AppView, ArcCompletion, Panel};

/// Main draw dispatcher — routes to the appropriate view renderer.
pub fn draw(frame: &mut Frame, app: &App) {
    match app.view {
        AppView::Selection => render_selection_view(frame, app),
        AppView::Running => render_running_view(frame, app),
    }
}

/// Render the selection view: two-panel layout (config dirs + plan files) with help bar.
fn render_selection_view(frame: &mut Frame, app: &App) {
    let area = frame.area();

    // Outer vertical layout: header (1), body (fill), footer (3)
    let [header_area, body_area, footer_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(5),
        Constraint::Length(3),
    ])
    .areas(area);

    // Header
    let header = Paragraph::new("  Torrent — Arc Orchestrator")
        .style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    frame.render_widget(header, header_area);

    // Body: two-panel horizontal split (30% config / 70% plans)
    let [left_area, right_area] = Layout::horizontal([
        Constraint::Percentage(30),
        Constraint::Percentage(70),
    ])
    .areas(body_area);

    // Left panel: config directories
    render_config_panel(frame, app, left_area);

    // Right panel: plan files
    render_plan_panel(frame, app, right_area);

    // Footer: keybinding help bar
    let selected_count = app.selected_plans.len();
    let help_text = if selected_count > 0 {
        format!(
            " [Tab] Switch panel │ [Enter] Select config │ [Space] Toggle plan │ [a] Select all │ [r] Run {} plan{} │ [q] Quit",
            selected_count,
            if selected_count == 1 { "" } else { "s" }
        )
    } else {
        " [Tab] Switch panel │ [Enter] Select config │ [Space] Toggle plan │ [a] Select all │ [q] Quit".into()
    };
    let footer = Paragraph::new(help_text)
        .block(Block::default().borders(Borders::TOP))
        .style(Style::default().fg(Color::DarkGray));
    frame.render_widget(footer, footer_area);
}

/// Render the config directory list panel (left side).
fn render_config_panel(frame: &mut Frame, app: &App, area: Rect) {
    let is_active = app.active_panel == Panel::ConfigList;
    let border_style = if is_active {
        Style::default().fg(Color::Cyan)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    let items: Vec<ListItem> = app
        .config_dirs
        .iter()
        .enumerate()
        .map(|(i, dir)| {
            let marker = if i == app.selected_config { "> " } else { "  " };
            let content = format!("{}{}", marker, dir.label);
            let style = if i == app.selected_config {
                Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            ListItem::new(content).style(style)
        })
        .collect();

    let list = List::new(items)
        .block(
            Block::default()
                .title(" Config Dirs ")
                .borders(Borders::ALL)
                .border_style(border_style),
        )
        .highlight_style(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        );

    let mut state = ListState::default();
    state.select(Some(app.config_cursor));
    frame.render_stateful_widget(list, area, &mut state);
}

/// Render the plan files panel (right side) with ordered multi-select.
fn render_plan_panel(frame: &mut Frame, app: &App, area: Rect) {
    let is_active = app.active_panel == Panel::PlanList;
    let border_style = if is_active {
        Style::default().fg(Color::Cyan)
    } else {
        Style::default().fg(Color::DarkGray)
    };

    let items: Vec<ListItem> = app
        .plans
        .iter()
        .enumerate()
        .map(|(i, plan)| {
            let order = app.selected_plans.iter().position(|&idx| idx == i);
            let marker = match order {
                Some(pos) => format!("[{}]", pos + 1),
                None => "[ ]".into(),
            };
            let content = format!("{} {}", marker, plan.title);
            let style = if order.is_some() {
                Style::default().fg(Color::Yellow)
            } else {
                Style::default()
            };
            ListItem::new(content).style(style)
        })
        .collect();

    let list = List::new(items)
        .block(
            Block::default()
                .title(" Plan Files ")
                .borders(Borders::ALL)
                .border_style(border_style),
        )
        .highlight_style(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        );

    let mut state = ListState::default();
    state.select(Some(app.plan_cursor));
    frame.render_stateful_widget(list, area, &mut state);
}

/// Render the running view: header, checkpoint, heartbeat, queue, and help bar.
fn render_running_view(frame: &mut Frame, app: &App) {
    let area = frame.area();

    // Vertical layout: header (3), checkpoint (9), heartbeat (6), queue (fill), footer (3)
    let [header_area, checkpoint_area, heartbeat_area, queue_area, footer_area] =
        Layout::vertical([
            Constraint::Length(3),
            Constraint::Length(9),
            Constraint::Length(6),
            Constraint::Min(5),
            Constraint::Length(3),
        ])
        .areas(area);

    // Header bar
    render_running_header(frame, app, header_area);

    // Checkpoint panel
    render_checkpoint_panel(frame, app, checkpoint_area);

    // Heartbeat panel
    render_heartbeat_panel(frame, app, heartbeat_area);

    // Queue panel
    render_queue_panel(frame, app, queue_area);

    // Footer: keybindings
    let footer = Paragraph::new(
        " [a] Attach tmux  [s] Skip plan  [k] Kill arc  [q] Quit (bg)",
    )
    .block(Block::default().borders(Borders::TOP))
    .style(Style::default().fg(Color::DarkGray));
    frame.render_widget(footer, footer_area);
}

/// Render the running view header with config + plan counter.
fn render_running_header(frame: &mut Frame, app: &App, area: Rect) {
    let config_label = app
        .config_dirs
        .get(app.selected_config)
        .map(|c| c.label.as_str())
        .unwrap_or("unknown");

    let plan_info = if let Some(run) = &app.current_run {
        format!("Plan {}/{}", run.plan_index, run.total_plans)
    } else {
        format!(
            "Done — {}/{} completed",
            app.completed_runs.len(),
            app.completed_runs.len() + app.queue.len()
        )
    };

    let header_text = format!("  Torrent  ⟫  {}  ⟫  {}", config_label, plan_info);
    let header = Paragraph::new(header_text)
        .block(Block::default().borders(Borders::BOTTOM))
        .style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    frame.render_widget(header, area);
}

/// Render the checkpoint panel showing arc identity and phase progress.
fn render_checkpoint_panel(frame: &mut Frame, app: &App, area: Rect) {
    let content = if let Some(run) = &app.current_run {
        if let Some(status) = &run.last_status {
            let summary = &status.phase_summary;
            let pr_line = status
                .pr_url
                .as_deref()
                .map(|u| format!("  PR:         {}\n", u))
                .unwrap_or_default();

            format!(
                "  Arc ID:     {}\n  Phase:      {}  ({}/{} done, {} skipped)\n{}\
                 \n  Started:    {}",
                status.arc_id,
                summary.current_phase_name,
                summary.completed,
                summary.total,
                summary.skipped,
                pr_line,
                // show launched_at as relative time would need chrono; show raw for now
                run.plan.name,
            )
        } else if run.arc.is_some() {
            "  Polling arc status...".into()
        } else {
            format!(
                "  ▶ {}\n  {}\n\n  discovering arc checkpoint...",
                run.plan.title,
                run.plan.path.display()
            )
        }
    } else {
        "  No arc running".into()
    };

    let block = Block::bordered()
        .title(" Checkpoint ")
        .border_style(Style::default().fg(Color::Blue));
    let paragraph = Paragraph::new(content).block(block);
    frame.render_widget(paragraph, area);
}

/// Render the heartbeat panel showing liveness signal.
fn render_heartbeat_panel(frame: &mut Frame, app: &App, area: Rect) {
    let lines: Vec<Line> = if let Some(run) = &app.current_run {
        if let Some(status) = &run.last_status {
            let (indicator, color) = if status.is_stale {
                ("● stale", Color::Red)
            } else if status.last_activity.is_empty() {
                ("● unknown", Color::DarkGray)
            } else {
                ("● live", Color::Green)
            };

            vec![
                Line::from(vec![
                    Span::raw(format!("  Last Activity:  {}  ", status.last_activity)),
                    Span::styled(indicator, Style::default().fg(color)),
                ]),
                Line::from(format!("  Last Tool:      {}", status.last_tool)),
                Line::from(format!("  Phase:          {}", status.current_phase)),
            ]
        } else {
            vec![Line::from("  Waiting for heartbeat...")]
        }
    } else {
        vec![Line::from("  No active heartbeat")]
    };

    let block = Block::bordered()
        .title(" Heartbeat ")
        .border_style(Style::default().fg(Color::Magenta));
    let paragraph = Paragraph::new(Text::from(lines)).block(block);
    frame.render_widget(paragraph, area);
}

/// Render the queue panel showing plan execution progress.
fn render_queue_panel(frame: &mut Frame, app: &App, area: Rect) {
    let mut items: Vec<ListItem> = Vec::new();

    // Completed runs
    for run in &app.completed_runs {
        let result_str = match &run.result {
            ArcCompletion::Merged { pr_url } => {
                let pr = pr_url.as_deref().unwrap_or("");
                format!("merged  {}  ({:.0}m)", pr, run.duration.as_secs_f64() / 60.0)
            }
            ArcCompletion::Shipped { pr_url } => {
                let pr = pr_url.as_deref().unwrap_or("");
                format!("shipped  {}  ({:.0}m)", pr, run.duration.as_secs_f64() / 60.0)
            }
            ArcCompletion::Cancelled { reason } => {
                format!("cancelled  {}", reason.as_deref().unwrap_or(""))
            }
            ArcCompletion::Failed { reason } => format!("failed  {}", reason),
        };
        let line = format!("  ✓ {}     {}", run.plan.title, result_str);
        items.push(ListItem::new(line).style(Style::default().fg(Color::Green)));
    }

    // Current run
    if let Some(run) = &app.current_run {
        let phase = run
            .last_status
            .as_ref()
            .map(|s| s.current_phase.as_str())
            .unwrap_or("discovering...");

        let grace_note = if run.merge_detected_at.is_some() {
            " ⏳ grace period..."
        } else {
            ""
        };
        let line = format!("  ▶ {}     {}{}", run.plan.title, phase, grace_note);
        items.push(ListItem::new(line).style(Style::default().fg(Color::Yellow)));
    }

    // Pending plans in queue
    for &plan_idx in &app.queue {
        if let Some(plan) = app.plans.get(plan_idx) {
            let line = format!("  ○ {}     pending", plan.title);
            items.push(ListItem::new(line).style(Style::default().fg(Color::DarkGray)));
        }
    }

    let block = Block::bordered()
        .title(" Queue ")
        .border_style(Style::default().fg(Color::Yellow));
    let list = List::new(items).block(block);
    frame.render_widget(list, area);
}

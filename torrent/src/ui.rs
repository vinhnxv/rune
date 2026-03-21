use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{
    Block, Borders, List, ListItem, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState,
};
use ratatui::Frame;

use std::time::Instant;
use crate::app::{App, AppView, ArcCompletion, Panel};
use crate::diagnostic::Severity;
use crate::monitor::ActivityState;
use crate::resource::ProcessHealth;

const VERSION: &str = env!("CARGO_PKG_VERSION");

// Solarized Dark palette
mod sol {
    use ratatui::style::Color;
    pub const BASE03: Color = Color::Rgb(0, 43, 54);
    pub const BASE01: Color = Color::Rgb(88, 110, 117);
    pub const BASE0: Color = Color::Rgb(131, 148, 150);
    pub const BASE1: Color = Color::Rgb(147, 161, 161);
    pub const YELLOW: Color = Color::Rgb(181, 137, 0);
    pub const ORANGE: Color = Color::Rgb(203, 75, 22);
    pub const RED: Color = Color::Rgb(220, 50, 47);
    pub const BLUE: Color = Color::Rgb(38, 139, 210);
    pub const CYAN: Color = Color::Rgb(42, 161, 152);
    pub const GREEN: Color = Color::Rgb(133, 153, 0);
}

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    if area.width < 60 || area.height < 15 {
        let msg = Paragraph::new(format!(
            "Terminal too small ({}x{}). Need 60x15+",
            area.width, area.height
        ))
        .style(Style::default().fg(sol::RED));
        frame.render_widget(msg, area);
        return;
    }

    match app.view {
        AppView::ActiveArcs => render_active_arcs(frame, app, area),
        AppView::Selection => render_selection(frame, app, area),
        AppView::Running => render_running(frame, app, area),
    }
}

/// Render a List with stateful scrolling and an optional vertical scrollbar.
/// The scrollbar only appears when items exceed the visible area.
fn render_scrollable_list(
    frame: &mut Frame,
    items: Vec<ListItem>,
    block: Block,
    area: Rect,
    selected: usize,
    list_state: &mut ratatui::widgets::ListState,
) {
    let total = items.len();
    list_state.select(Some(selected));
    let list = List::new(items).block(block);
    frame.render_stateful_widget(list, area, list_state);

    // Show scrollbar only when content overflows the visible area.
    // Subtract 2 for top/bottom borders.
    let visible_height = area.height.saturating_sub(2) as usize;
    if total > visible_height {
        let mut scrollbar_state = ScrollbarState::new(total).position(selected);
        let scrollbar = Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .begin_symbol(Some("↑"))
            .end_symbol(Some("↓"))
            .track_symbol(Some("│"))
            .thumb_style(Style::default().fg(sol::CYAN));
        frame.render_stateful_widget(scrollbar, area, &mut scrollbar_state);
    }
}

// ── Active Arcs View ───────────────────────────────────────

fn render_active_arcs(frame: &mut Frame, app: &mut App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(1),
        ])
        .split(area);

    // Header
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(format!(" torrent v{VERSION} "), Style::default().fg(sol::BASE03).bg(sol::ORANGE).add_modifier(Modifier::BOLD)),
            Span::styled(format!(" — {} active arc(s) detected", app.active_arcs.len()), Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
        ])),
        chunks[0],
    );

    // Info box
    frame.render_widget(
        Paragraph::new(Text::from(vec![
            Line::from(Span::styled(
                "  Active Rune Arc sessions found. You can monitor or attach to them.",
                Style::default().fg(sol::BASE0),
            )),
        ])).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(sol::ORANGE))
                .title(Span::styled(" Info ", Style::default().fg(sol::BASE1)))
        ),
        chunks[1],
    );

    // Active arcs list with details
    let items: Vec<ListItem> = app.active_arcs.iter().enumerate().map(|(i, arc)| {
        let is_cursor = i == app.active_arc_cursor;
        let style = if is_cursor {
            Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(sol::BASE0)
        };

        // Status indicators
        let pid_icon = if arc.pid_alive { "●" } else { "○" };
        let pid_color = if arc.pid_alive { sol::GREEN } else { sol::RED };
        let tmux_label = arc.tmux_session.as_deref().unwrap_or("no tmux");
        let tmux_color = if arc.tmux_session.is_some() { sol::CYAN } else { sol::BASE01 };

        // Phase progress
        let phase_info = match (&arc.current_phase, arc.phase_progress) {
            (Some(phase), Some((done, total))) => format!("{} ({}/{})", phase, done, total),
            (Some(phase), None) => phase.clone(),
            (None, Some((done, total))) => format!("{}/{} phases", done, total),
            (None, None) => "unknown".into(),
        };

        // Plan name (extract from path)
        let plan_name = if let Some(idx) = arc.loop_state.plan_file.rfind('/') {
            &arc.loop_state.plan_file[idx + 1..]
        } else {
            &arc.loop_state.plan_file
        };

        let cursor_marker = if is_cursor { "▶" } else { " " };

        // Build multi-span line
        let line = Line::from(vec![
            Span::styled(format!(" {} ", cursor_marker), Style::default().fg(sol::YELLOW)),
            Span::styled(pid_icon, Style::default().fg(pid_color).add_modifier(Modifier::BOLD)),
            Span::styled(format!(" {:<35}", plan_name), style),
            Span::styled(format!(" {:<20}", phase_info), Style::default().fg(sol::CYAN)),
            Span::styled(format!(" {}", tmux_label), Style::default().fg(tmux_color)),
        ]);

        // Second line: config, PID, started, uptime
        let mut detail_spans = vec![
            Span::styled("     ", Style::default()),
            Span::styled(format!("config: {}", arc.config_dir.label), Style::default().fg(sol::BASE01)),
            Span::styled(format!("  PID: {}", arc.loop_state.owner_pid), Style::default().fg(sol::BASE01)),
        ];
        if let Some(ref si) = arc.session_info {
            if si.start_time > 0 {
                let started = format_epoch(si.start_time);
                let uptime = format_uptime(si.start_time);
                detail_spans.push(Span::styled(format!("  {started}"), Style::default().fg(sol::BASE0)));
                detail_spans.push(Span::styled(format!("  {uptime}"), Style::default().fg(sol::CYAN)));
            }
        }
        let detail = Line::from(detail_spans);

        // Third line: CWD, MCP count, teammate count
        let mut info_spans = vec![Span::styled("     ", Style::default())];
        if let Some(ref si) = arc.session_info {
            if !si.cwd.is_empty() {
                // Shorten CWD: ~/Desktop/repos/rune → rune
                let short_cwd = si.cwd.rsplit('/').next().unwrap_or(&si.cwd);
                info_spans.push(Span::styled(short_cwd.to_string(), Style::default().fg(sol::BASE0)));
            }
            info_spans.push(Span::styled(
                format!("  {} MCP, {} mates", si.mcp_count, si.teammate_count),
                Style::default().fg(sol::GREEN),
            ));
        }
        if let Some(ref pr) = arc.pr_url {
            info_spans.push(Span::styled(format!("  PR: {}", pr), Style::default().fg(sol::BLUE)));
        }
        let info_line = Line::from(info_spans);

        ListItem::new(Text::from(vec![line, detail, info_line]))
    }).collect();

    render_scrollable_list(
        frame,
        items,
        Block::default().borders(Borders::ALL)
            .border_style(Style::default().fg(sol::YELLOW))
            .title(Span::styled(" Active Sessions ", Style::default().fg(sol::BASE1))),
        chunks[2],
        app.active_arc_cursor,
        &mut app.active_arcs_list_state,
    );

    // Status bar
    frame.render_widget(
        Paragraph::new(" [m/Enter] monitor  [a] attach tmux  [n/Esc] new run  [q] quit")
            .style(Style::default().fg(sol::BASE01)),
        chunks[3],
    );
}

// ── Selection View ──────────────────────────────────────────

fn render_selection(frame: &mut Frame, app: &mut App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(5),
            Constraint::Length(1),
        ])
        .split(area);

    // Header — different in queue-edit mode
    let header = if app.queue_editing {
        Line::from(vec![
            Span::styled(format!(" torrent v{VERSION} "), Style::default().fg(sol::BASE03).bg(sol::ORANGE).add_modifier(Modifier::BOLD)),
            Span::styled(" — Add Plans to Queue", Style::default().fg(sol::ORANGE)),
            Span::styled(format!("  ({} in queue)", app.queue.len()), Style::default().fg(sol::CYAN)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
        ])
    } else {
        Line::from(vec![
            Span::styled(format!(" torrent v{VERSION} "), Style::default().fg(sol::BASE03).bg(sol::BLUE).add_modifier(Modifier::BOLD)),
            Span::styled(" — Arc Orchestrator", Style::default().fg(sol::BASE0)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
        ])
    };
    frame.render_widget(Paragraph::new(header), chunks[0]);

    // Body: config (compact) + plans (wider)
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(30), Constraint::Min(40)])
        .split(chunks[1]);
    render_config_panel(frame, app, body[0]);
    render_plan_panel(frame, app, body[1]);

    // Status bar
    let status = if app.queue_editing {
        let cfg = app.config_dirs.get(app.selected_config).map(|c| c.label.as_str()).unwrap_or("?");
        if !app.selected_plans.is_empty() {
            format!(
                " {} plan(s) · {} · [r/Enter] add to queue  [Tab] switch  [Esc] cancel",
                app.selected_plans.len(), cfg
            )
        } else {
            format!(" {} · [Tab] switch panel · [Space] toggle · [a] all · [Esc] cancel", cfg)
        }
    } else if let Some(ref msg) = app.status_message {
        msg.clone()
    } else if !app.selected_plans.is_empty() {
        let cfg = app.config_dirs.get(app.selected_config).map(|c| c.label.as_str()).unwrap_or("?");
        format!(" {} plan(s) · {} · [r] run  [q] quit", app.selected_plans.len(), cfg)
    } else {
        " [Space] toggle plan · [Enter] config · [Tab] panel · [q] quit".into()
    };
    frame.render_widget(
        Paragraph::new(status).style(Style::default().fg(sol::BASE01)),
        chunks[2],
    );
}

fn render_config_panel(frame: &mut Frame, app: &mut App, area: Rect) {
    let items: Vec<ListItem> = app.config_dirs.iter().enumerate().map(|(i, cfg)| {
        let marker = if i == app.selected_config { "▶" } else { " " };
        let is_cursor = i == app.config_cursor && app.active_panel == Panel::ConfigList;
        let style = if is_cursor {
            Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)
        } else if i == app.selected_config {
            Style::default().fg(sol::CYAN)
        } else {
            Style::default().fg(sol::BASE0)
        };
        ListItem::new(Line::from(vec![
            Span::styled(format!(" {marker} "), Style::default().fg(sol::GREEN)),
            Span::styled(&cfg.label, style),
        ]))
    }).collect();

    let border = if app.active_panel == Panel::ConfigList { sol::CYAN } else { sol::BASE01 };
    let title = Line::from(vec![
        Span::styled(" Config ", Style::default().fg(sol::BASE1)),
        Span::styled(
            format!("v{} ", app.claude_version),
            Style::default().fg(sol::BASE01),
        ),
    ]);
    render_scrollable_list(
        frame,
        items,
        Block::default().borders(Borders::ALL)
            .border_style(Style::default().fg(border))
            .title(title),
        area,
        app.config_cursor,
        &mut app.config_list_state,
    );
}

fn render_plan_panel(frame: &mut Frame, app: &mut App, area: Rect) {
    let items: Vec<ListItem> = app.plans.iter().enumerate().map(|(i, plan)| {
        let in_flight = app.queue_editing && app.is_plan_in_flight(i);
        let selected_entry = app.selected_plans.iter()
            .enumerate()
            .find(|(_, e)| e.plan_idx == i);
        let order = selected_entry.map(|(pos, _)| pos);
        let entry_config = selected_entry.map(|(_, e)| e.config_idx);

        let marker = if in_flight {
            if app.current_run.as_ref().map(|r| {
                let fa = r.plan.name.rsplit('/').next().unwrap_or(&r.plan.name);
                let fb = plan.name.rsplit('/').next().unwrap_or(&plan.name);
                fa == fb
            }).unwrap_or(false) {
                " ▶ ".to_string()
            } else if app.queue.iter().any(|e| e.plan_idx == i) {
                " ◆ ".to_string()
            } else {
                " ✓ ".to_string()
            }
        } else {
            match order { Some(n) => format!("[{}]", n + 1), None => "[ ]".into() }
        };

        let is_cursor = i == app.plan_cursor && app.active_panel == Panel::PlanList;
        let style = if in_flight {
            Style::default().fg(sol::BASE01)
        } else if is_cursor {
            Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)
        } else if order.is_some() {
            Style::default().fg(sol::CYAN)
        } else {
            Style::default().fg(sol::BASE0)
        };
        let mstyle = if in_flight {
            Style::default().fg(sol::BASE01)
        } else if order.is_some() {
            Style::default().fg(sol::GREEN)
        } else {
            Style::default().fg(sol::BASE01)
        };

        // Show date, title, filename, and config label
        let mut spans = vec![
            Span::styled(format!(" {marker} "), mstyle),
        ];
        // Date prefix (dimmed)
        if let Some(ref date) = plan.date {
            spans.push(Span::styled(
                format!("{date}  "),
                Style::default().fg(sol::BASE01),
            ));
        }
        // Title
        spans.push(Span::styled(&plan.title, style));
        // Config label for selected plans (before filename)
        if let Some(cfg_idx) = entry_config {
            let cfg = app.config_dirs.get(cfg_idx)
                .map(|c| c.label.as_str())
                .unwrap_or("?");
            spans.push(Span::styled(
                format!("  [{cfg}]"),
                Style::default().fg(sol::BASE01),
            ));
        }
        // Filename (dimmed, only if title differs from filename)
        if plan.title != plan.name {
            spans.push(Span::styled(
                format!("  ({})", plan.name),
                Style::default().fg(sol::BASE01),
            ));
        }
        ListItem::new(Line::from(spans))
    }).collect();

    let border = if app.active_panel == Panel::PlanList { sol::CYAN } else { sol::BASE01 };
    render_scrollable_list(
        frame,
        items,
        Block::default().borders(Borders::ALL)
            .border_style(Style::default().fg(border))
            .title(Span::styled(" Plans ", Style::default().fg(sol::BASE1))),
        area,
        app.plan_cursor,
        &mut app.plan_list_state,
    );
}

// ── Running View ────────────────────────────────────────────

fn render_running(frame: &mut Frame, app: &mut App, area: Rect) {
    // Check if grace period is active for conditional layout
    let grace_active = app.current_run
        .as_ref()
        .and_then(|r| r.merge_detected_at.map(|_| r.grace_duration.is_some()))
        .unwrap_or(false);

    // Check if a diagnostic banner should be shown (non-Healthy state).
    let diag_banner = app.last_diagnostic.as_ref().and_then(|d| {
        d.state.display_message().map(|msg| (msg, d.state.severity()))
    });
    let has_banner = diag_banner.is_some();

    let chunks = if grace_active {
        let mut constraints = vec![
            Constraint::Length(1),  // header
        ];
        if has_banner {
            constraints.push(Constraint::Length(1)); // diagnostic banner
        }
        let has_claude_msg = app.last_claude_msg.is_some();
        constraints.extend_from_slice(&[
            Constraint::Length(13), // phases + session info + loop state
            Constraint::Length(6),  // heartbeat + resources (no phase)
        ]);
        if has_claude_msg {
            constraints.push(Constraint::Length(3)); // claude message section
        }
        constraints.extend_from_slice(&[
            Constraint::Length(3),  // grace countdown (F4)
            Constraint::Min(3),
            Constraint::Length(1),
        ]);
        Layout::default()
            .direction(Direction::Vertical)
            .constraints(constraints)
            .split(area)
    } else {
        let mut constraints = vec![
            Constraint::Length(1),  // header
        ];
        if has_banner {
            constraints.push(Constraint::Length(1)); // diagnostic banner
        }
        let has_claude_msg = app.last_claude_msg.is_some();
        constraints.extend_from_slice(&[
            Constraint::Length(13), // phases + session info + loop state
            Constraint::Length(6),  // heartbeat + resources (no phase)
        ]);
        if has_claude_msg {
            constraints.push(Constraint::Length(3)); // claude message section
        }
        constraints.extend_from_slice(&[
            Constraint::Min(3),
            Constraint::Length(1),
        ]);
        Layout::default()
            .direction(Direction::Vertical)
            .constraints(constraints)
            .split(area)
    };

    // Track chunk index — banner shifts all subsequent indices by 1.
    let mut ci = 0;

    // Header — use current run's config, not the selection cursor
    let run_config_idx = app.current_run.as_ref().map(|r| r.config_idx).unwrap_or(app.selected_config);
    let cfg = app.config_dirs.get(run_config_idx).map(|c| c.label.as_str()).unwrap_or("?");
    // Compute plan position dynamically so the header stays in sync
    // when plans are added/removed from the queue at runtime.
    let plan_info = if app.current_run.is_some() {
        let position = app.completed_runs.len() + 1;
        let total = app.completed_runs.len()
            + 1
            + app.queue.len();
        format!("Plan {position}/{total}")
    } else {
        format!("Done — {}", app.completed_runs.len())
    };
    // Channel status indicator: [ch] when healthy, [ch?] when enabled but unhealthy, [file] when disabled
    let channel_active = app.current_run.as_ref()
        .and_then(|r| r.channel_state.as_ref())
        .map(|cs| cs.is_active())
        .unwrap_or(false);
    // Channel status + last message transport indicator
    let transport_suffix = match app.last_msg_transport {
        Some(crate::app::MsgTransport::Bridge) => " ✉→bridge",
        Some(crate::app::MsgTransport::Inbox) => " ✉→inbox",
        Some(crate::app::MsgTransport::Tmux) => " ✉→tmux",
        None => "",
    };
    let channel_indicator = if app.channels_enabled && channel_active {
        Span::styled(format!("  [ch]{transport_suffix}"), Style::default().fg(sol::CYAN))
    } else if app.channels_enabled {
        Span::styled(format!("  [ch?]{transport_suffix}"), Style::default().fg(sol::YELLOW))
    } else if transport_suffix.is_empty() {
        Span::styled("  [file]", Style::default().fg(sol::BASE01))
    } else {
        Span::styled(format!("  [file]{transport_suffix}"), Style::default().fg(sol::BASE01))
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(format!(" torrent v{VERSION} "), Style::default().fg(sol::BASE03).bg(sol::BLUE).add_modifier(Modifier::BOLD)),
            Span::styled(format!(" ⟫ {cfg} ⟫ {plan_info}"), Style::default().fg(sol::BASE0)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
            channel_indicator,
        ])),
        chunks[ci],
    );
    ci += 1;

    // Diagnostic banner (F6) — shown only when non-Healthy state detected.
    if let Some((msg, severity)) = diag_banner {
        let color = severity_color(&severity);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(" ⚠ ", Style::default().fg(color).add_modifier(Modifier::BOLD)),
                Span::styled(msg, Style::default().fg(color)),
            ])),
            chunks[ci],
        );
        ci += 1;
    }

    render_checkpoint(frame, app, chunks[ci]);
    ci += 1;
    render_heartbeat(frame, app, chunks[ci]);
    ci += 1;

    // Claude message section (from channel events)
    if app.last_claude_msg.is_some() {
        render_claude_msg(frame, app, chunks[ci]);
        ci += 1;
    }

    if grace_active {
        render_grace_countdown(frame, app, chunks[ci]);
        ci += 1;
        render_queue(frame, app, chunks[ci]);
        ci += 1;

        // Status bar with grace-specific hint
        let grace_status = if app.current_run.as_ref().map(|r| r.grace_skip_at.is_some()).unwrap_or(false) {
            " Grace skip requested… [a] attach  [k] kill  [q] quit"
        } else {
            " [s] skip grace (min 5s)  [a] attach  [k] kill  [q] quit"
        };
        let status = app.status_message.as_deref().unwrap_or(grace_status);
        frame.render_widget(
            Paragraph::new(status).style(Style::default().fg(sol::BASE01)),
            chunks[ci],
        );
    } else {
        render_queue(frame, app, chunks[ci]);
        ci += 1;

        // Status bar — message input mode or context-sensitive help
        if app.message_input_active {
            let input_line = Line::from(vec![
                Span::styled(" ✉ msg> ", Style::default().fg(sol::CYAN).add_modifier(Modifier::BOLD)),
                Span::styled(&app.message_input_buf, Style::default().fg(sol::BASE1)),
                Span::styled("█", Style::default().fg(sol::CYAN)),  // cursor
                Span::styled("  [Enter] send  [Esc] cancel", Style::default().fg(sol::BASE01)),
            ]);
            frame.render_widget(
                Paragraph::new(input_line),
                chunks[ci],
            );
        } else {
            let all_done = app.current_run.is_none() && app.queue.is_empty() && !app.completed_runs.is_empty();
            let msg_hint = if app.tmux_session_id.is_some() { "  [m] msg" } else { "" };
            let default_status = if all_done {
                format!(" All done! [p] add plans{msg_hint}  [q] quit")
            } else if !app.queue.is_empty() {
                format!(" [a] attach  [s] skip  [k] kill  [p] add  [d] remove{msg_hint}  [q] quit")
            } else {
                format!(" [a] attach  [s] skip  [k] kill  [p] add plans{msg_hint}  [q] quit")
            };
            let status = app.status_message.as_deref().unwrap_or(&default_status);
            frame.render_widget(
                Paragraph::new(status.to_string()).style(Style::default().fg(sol::BASE01)),
                chunks[ci],
            );
        }
    }
}

/// Map diagnostic severity to a Solarized color for the UI banner.
fn severity_color(severity: &Severity) -> Color {
    match severity {
        Severity::Critical => sol::RED,
        Severity::High => sol::ORANGE,
        Severity::Medium => sol::YELLOW,
        Severity::Low => sol::GREEN,
    }
}

/// Render the grace period countdown with progress bar (F4).
fn render_grace_countdown(frame: &mut Frame, app: &App, area: Rect) {
    let (elapsed_secs, total_secs, child_count, skip_requested) = if let Some(ref run) = app.current_run {
        let elapsed = run.merge_detected_at
            .map(|t| t.elapsed().as_secs())
            .unwrap_or(0);
        let total = run.grace_duration
            .map(|d| d.as_secs())
            .unwrap_or(30);
        let children = run.last_status
            .as_ref()
            .and_then(|s| s.resource.as_ref())
            .map(|r| r.child_count)
            .unwrap_or(0);
        (elapsed, total, children, run.grace_skip_at.is_some())
    } else {
        return;
    };

    let remaining = total_secs.saturating_sub(elapsed_secs);
    let ratio = if total_secs > 0 { elapsed_secs as f64 / total_secs as f64 } else { 1.0 };
    let ratio = ratio.clamp(0.0, 1.0);

    // Color-coded: green (>50% remaining), yellow (20-50%), red (<20%)
    let remaining_ratio = 1.0 - ratio;
    let bar_color = if remaining_ratio > 0.5 { sol::GREEN }
        else if remaining_ratio > 0.2 { sol::YELLOW }
        else { sol::RED };

    // Build progress bar: [████████░░░░]
    let bar_width = (area.width as usize).saturating_sub(4).min(40);
    let filled = (ratio * bar_width as f64) as usize;
    let empty = bar_width.saturating_sub(filled);
    let bar = format!("[{}{}]", "█".repeat(filled), "░".repeat(empty));

    let context = if child_count > 0 {
        format!("Waiting for {} child process{}", child_count, if child_count == 1 { "" } else { "es" })
    } else {
        "Grace period (cleanup)".to_string()
    };

    let skip_hint = if skip_requested { " (skip requested)" } else { "  Press 's' to skip" };

    let lines = vec![
        Line::from(vec![
            Span::styled("  Grace: ", Style::default().fg(sol::BASE01)),
            Span::styled(&bar, Style::default().fg(bar_color)),
            Span::styled(format!(" {}s / {}s", remaining, total_secs), Style::default().fg(bar_color).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("         ", Style::default()),
            Span::styled(&context, Style::default().fg(sol::BASE0)),
            Span::styled(skip_hint, Style::default().fg(sol::BASE01)),
        ]),
    ];

    let block = Block::default().borders(Borders::NONE);
    let paragraph = Paragraph::new(lines).block(block);
    frame.render_widget(paragraph, area);
}

fn render_checkpoint(frame: &mut Frame, app: &App, area: Rect) {
    let lines = if let Some(run) = &app.current_run {
        if let Some(st) = &run.last_status {
            let s = &st.phase_summary;
            let mut l = vec![
                Line::from(vec![
                    Span::styled("  Arc:   ", Style::default().fg(sol::BASE01)),
                    Span::styled(&st.arc_id, Style::default().fg(sol::CYAN)),
                    Span::styled(
                        format!("  ({}/{}, {} skip)", s.completed, s.total, s.skipped),
                        Style::default().fg(sol::BASE0),
                    ),
                ]),
            ];
            // Phase navigation: prev → current → next with timing
            if let Some(ref nav) = st.phase_nav {
                // Previous phase (completed, with duration)
                if let Some(ref prev) = nav.prev {
                    l.push(Line::from(vec![
                        Span::styled("  Prev:  ", Style::default().fg(sol::BASE01)),
                        Span::styled(&prev.name, Style::default().fg(sol::BASE0)),
                        Span::styled(
                            format!("  {}", format_duration(prev.duration_secs)),
                            Style::default().fg(sol::BASE01),
                        ),
                    ]));
                }
                // Current phase (in progress, with elapsed + timeout remaining)
                if let Some(ref curr) = nav.current {
                    let mut now_spans = vec![
                        Span::styled("  ▶ Now: ", Style::default().fg(sol::YELLOW)),
                        Span::styled(&curr.name, Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
                        Span::styled(
                            format!("  {}", format_duration(curr.duration_secs)),
                            Style::default().fg(sol::ORANGE),
                        ),
                    ];
                    // Show timeout remaining: "45m23s / 90m0s ⏱"
                    let timeout = app.phase_timeout_config.timeout_for(&curr.name);
                    let timeout_secs = timeout.as_secs() as i64;
                    if let Some(elapsed) = curr.duration_secs {
                        let ratio = elapsed as f64 / timeout_secs as f64;
                        let timeout_color = if ratio > 0.8 {
                            sol::RED
                        } else if ratio > 0.5 {
                            sol::YELLOW
                        } else {
                            sol::GREEN
                        };
                        now_spans.push(Span::styled(
                            format!(" / {}", format_duration(Some(timeout_secs))),
                            Style::default().fg(timeout_color),
                        ));
                        now_spans.push(Span::styled(
                            " ⏱",
                            Style::default().fg(timeout_color),
                        ));
                    }
                    l.push(Line::from(now_spans));
                } else {
                    // Between phases — show transitioning indicator
                    l.push(Line::from(vec![
                        Span::styled("  ◇ ", Style::default().fg(sol::CYAN)),
                        Span::styled("transitioning…", Style::default().fg(sol::CYAN).add_modifier(Modifier::DIM)),
                    ]));
                }
                // Next phase (pending)
                if let Some(ref next) = nav.next {
                    l.push(Line::from(vec![
                        Span::styled("  Next:  ", Style::default().fg(sol::BASE01)),
                        Span::styled(next, Style::default().fg(sol::BLUE)),
                    ]));
                }
            } else {
                // Fallback: single line (e.g. no checkpoint phases yet)
                l.push(Line::from(vec![
                    Span::styled("  Phase: ", Style::default().fg(sol::BASE01)),
                    Span::styled(&s.current_phase_name, Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
                ]));
            }
            l.push(make_kv("  Plan:  ", &run.plan.name, sol::BASE0));
            // Identity info — TMUX session, CCPID, CCID
            if let Some(ref arc) = run.arc {
                let ccpid_label = run.claude_pid
                    .map(|p| p.to_string())
                    .unwrap_or_else(|| {
                        if arc.owner_pid.is_empty() { "—".into() } else { arc.owner_pid.clone() }
                    });
                let ccid_label = if arc.session_id.is_empty() {
                    "—".to_string()
                } else {
                    arc.session_id.chars().take(8).collect::<String>()
                };
                l.push(Line::from(vec![
                    Span::styled("  TMUX:  ", Style::default().fg(sol::BASE01)),
                    Span::styled(run.tmux_session.clone(), Style::default().fg(sol::GREEN)),
                    Span::styled("  CCPID: ", Style::default().fg(sol::BASE01)),
                    Span::styled(ccpid_label, Style::default().fg(sol::CYAN)),
                    Span::styled("  CCID: ", Style::default().fg(sol::BASE01)),
                    Span::styled(ccid_label, Style::default().fg(sol::BLUE)),
                ]));
            }
            // Session enrichment: started, uptime, CWD, MCP, mates
            if let Some(ref si) = run.session_info {
                let mut spans = vec![Span::styled("  ", Style::default())];
                if si.start_time > 0 {
                    spans.push(Span::styled(format_epoch(si.start_time), Style::default().fg(sol::BASE0)));
                    spans.push(Span::styled(format!("  {}", format_uptime(si.start_time)), Style::default().fg(sol::CYAN)));
                }
                if !si.cwd.is_empty() {
                    let short_cwd = si.cwd.rsplit('/').next().unwrap_or(&si.cwd);
                    spans.push(Span::styled(format!("  {short_cwd}"), Style::default().fg(sol::BASE0)));
                }
                spans.push(Span::styled(
                    format!("  {} MCP, {} mates", si.mcp_count, si.teammate_count),
                    Style::default().fg(sol::GREEN),
                ));
                l.push(Line::from(spans));
            }
            // Loop state info: branch + iteration from arc-phase-loop.local.md
            if let Some(ref ls) = run.loop_state {
                l.push(Line::from(vec![
                    Span::styled("  Branch:", Style::default().fg(sol::BASE01)),
                    Span::styled(format!(" {}", ls.branch), Style::default().fg(sol::GREEN)),
                    Span::styled("  Iter: ", Style::default().fg(sol::BASE01)),
                    Span::styled(
                        format!("{}/{}", ls.iteration, ls.max_iterations),
                        Style::default().fg(sol::CYAN),
                    ),
                ]));
            }
            if let Some(ref pr) = st.pr_url {
                l.push(make_kv("  PR:    ", pr, sol::BLUE));
            }
            l
        } else if run.arc.is_some() {
            vec![Line::from(Span::styled("  Polling status...", Style::default().fg(sol::BASE01)))]
        } else {
            vec![
                Line::from(vec![
                    Span::styled("  ▶ ", Style::default().fg(sol::GREEN)),
                    Span::styled(&run.plan.title, Style::default().fg(sol::CYAN)),
                ]),
                Line::from(Span::styled("    Discovering checkpoint...", Style::default().fg(sol::YELLOW))),
            ]
        }
    } else if app.inter_plan_cooldown_until.is_some() || !app.queue.is_empty() {
        // Between plans — cooldown active or queue has pending items
        let done = app.completed_runs.len();
        let remaining = app.queue.len();
        let mut l = vec![
            Line::from(vec![
                Span::styled("  ⏳ Waiting for next plan", Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
            ]),
            Line::from(vec![
                Span::styled(format!("  Done: {done}"), Style::default().fg(sol::GREEN)),
                Span::styled(format!("  Queued: {remaining}"), Style::default().fg(sol::CYAN)),
            ]),
        ];
        if let Some(deadline) = app.inter_plan_cooldown_until {
            let now = Instant::now();
            if deadline > now {
                let secs = deadline.duration_since(now).as_secs();
                l.push(Line::from(vec![
                    Span::styled(format!("  Next in {}m{}s", secs / 60, secs % 60), Style::default().fg(sol::YELLOW)),
                    Span::styled("  [s] skip cooldown", Style::default().fg(sol::BASE01)),
                ]));
            }
        }
        // Show last PR URL if available
        if let Some(last_pr) = app.completed_runs.iter().rev()
            .find_map(|r| match &r.result {
                ArcCompletion::Merged { pr_url } | ArcCompletion::Shipped { pr_url } => pr_url.clone(),
                _ => None,
            })
        {
            l.push(make_kv("  Last PR: ", &last_pr, sol::BLUE));
        }
        l
    } else {
        // All plans truly done — show summary
        let total = app.completed_runs.len();
        let merged = app.completed_runs.iter()
            .filter(|r| matches!(r.result, ArcCompletion::Merged { .. } | ArcCompletion::Shipped { .. }))
            .count();
        let failed = app.completed_runs.iter()
            .filter(|r| matches!(r.result, ArcCompletion::Failed { .. }))
            .count();
        let cancelled = app.completed_runs.iter()
            .filter(|r| matches!(r.result, ArcCompletion::Cancelled { .. }))
            .count();
        let total_duration: u64 = app.completed_runs.iter()
            .map(|r| r.duration.as_secs())
            .sum();

        let mut l = vec![
            Line::from(vec![
                Span::styled("  ✓ All plans completed", Style::default().fg(sol::GREEN).add_modifier(Modifier::BOLD)),
            ]),
            Line::from(vec![
                Span::styled(format!("  Total: {total}"), Style::default().fg(sol::BASE0)),
                Span::styled(format!("  Merged: {merged}"), Style::default().fg(sol::GREEN)),
                if failed > 0 {
                    Span::styled(format!("  Failed: {failed}"), Style::default().fg(sol::RED))
                } else {
                    Span::styled("", Style::default())
                },
                if cancelled > 0 {
                    Span::styled(format!("  Cancelled: {cancelled}"), Style::default().fg(sol::ORANGE))
                } else {
                    Span::styled("", Style::default())
                },
            ]),
            Line::from(vec![
                Span::styled("  Duration: ", Style::default().fg(sol::BASE01)),
                Span::styled(
                    format_duration(Some(total_duration as i64)),
                    Style::default().fg(sol::CYAN),
                ),
            ]),
        ];

        // Show last PR URL if available
        if let Some(last_pr) = app.completed_runs.iter().rev()
            .find_map(|r| match &r.result {
                ArcCompletion::Merged { pr_url } | ArcCompletion::Shipped { pr_url } => pr_url.clone(),
                _ => None,
            })
        {
            l.push(make_kv("  Last PR: ", &last_pr, sol::BLUE));
        }

        l
    };

    frame.render_widget(
        Paragraph::new(Text::from(lines)).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(sol::BLUE))
                .title(Span::styled(" Checkpoint ", Style::default().fg(sol::BASE1)))
        ),
        area,
    );
}

fn render_heartbeat(frame: &mut Frame, app: &App, area: Rect) {
    let lines = if let Some(run) = &app.current_run {
        if let Some(st) = &run.last_status {
            // Determine liveness status based on last_activity timestamp + process health
            let (icon, color) = if st.is_stale { ("● stale", sol::RED) }
                else if st.last_activity.is_empty() { ("● unknown", sol::BASE01) }
                else { ("● live", sol::GREEN) };

            let mut l = Vec::new();

            // Timeout warning banner (when kill sequence is active)
            if run.timeout_triggered_at.is_some() {
                l.push(Line::from(Span::styled(
                    "  ⚠ TIMEOUT — killing session, waiting for cleanup...",
                    Style::default().fg(sol::RED).add_modifier(Modifier::BOLD),
                )));
            }

            l.extend(vec![
                Line::from(vec![
                    Span::styled("  Activity: ", Style::default().fg(sol::BASE01)),
                    Span::styled(&st.last_activity, Style::default().fg(sol::BASE0)),
                    Span::raw("  "),
                    Span::styled(icon, Style::default().fg(color).add_modifier(Modifier::BOLD)),
                ]),
                make_kv("  Tool:     ", &st.last_tool, sol::BASE0),
            ]);

            // Resource monitoring line
            if let Some(ref res) = st.resource {
                let cpu_color = if res.cpu_percent > 80.0 { sol::RED }
                    else if res.cpu_percent > 30.0 { sol::YELLOW }
                    else { sol::GREEN };
                let mem_mb = res.memory_mb();
                let mem_color = if mem_mb > 4096.0 { sol::RED }
                    else if mem_mb > 2048.0 { sol::YELLOW }
                    else { sol::GREEN };
                let health_color = match st.process_health {
                    ProcessHealth::Active => sol::GREEN,
                    ProcessHealth::LowCpu => sol::ORANGE,
                    ProcessHealth::Idle => sol::YELLOW,
                    ProcessHealth::NotFound => sol::RED,
                };

                l.push(Line::from(vec![
                    Span::styled("  CPU: ", Style::default().fg(sol::BASE01)),
                    Span::styled(format!("{:.1}%", res.cpu_percent), Style::default().fg(cpu_color).add_modifier(Modifier::BOLD)),
                    Span::styled("  MEM: ", Style::default().fg(sol::BASE01)),
                    Span::styled(format!("{:.0}MB", mem_mb), Style::default().fg(mem_color).add_modifier(Modifier::BOLD)),
                    Span::styled(format!("  ({} children)", res.child_count), Style::default().fg(sol::BASE0)),
                    Span::styled("  ", Style::default()),
                    Span::styled(format!("● {}", st.process_health.label()), Style::default().fg(health_color)),
                ]));
            } else {
                l.push(make_kv("  Resources: ", "no PID tracked", sol::BASE01));
            }

            // Activity state indicator (multi-signal detection)
            if let Some(activity) = &st.activity_state {
                let (act_color, act_text) = match activity {
                    ActivityState::Active => (sol::GREEN, "Active"),
                    ActivityState::Slow => (sol::YELLOW, "Slow"),
                    ActivityState::Stale => (sol::ORANGE, "Stale"),
                    ActivityState::Idle => (sol::RED, "Idle"),
                    ActivityState::Stopped => (sol::RED, "Stopped"),
                    ActivityState::WaitingInput => (Color::Rgb(211, 54, 130), "Waiting for input"),
                };
                l.push(Line::from(vec![
                    Span::styled("  Activity: ", Style::default().fg(sol::BASE01)),
                    Span::styled(
                        format!("{} {}", activity.icon(), act_text),
                        Style::default().fg(act_color).add_modifier(Modifier::BOLD),
                    ),
                ]));
            }

            l
        } else {
            vec![Line::from(Span::styled("  Waiting for heartbeat...", Style::default().fg(sol::BASE01)))]
        }
    } else {
        vec![Line::from(Span::styled("  —", Style::default().fg(sol::BASE01)))]
    };

    frame.render_widget(
        Paragraph::new(Text::from(lines)).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(sol::ORANGE))
                .title(Span::styled(" Heartbeat & Resources ", Style::default().fg(sol::BASE1)))
        ),
        area,
    );
}

/// Render the last Claude Code message received via channel bridge.
/// Shows a compact 3-line section with source transport tag.
fn render_claude_msg(frame: &mut Frame, app: &App, area: Rect) {
    let msg = match &app.last_claude_msg {
        Some(m) => m.as_str(),
        None => return,
    };

    let transport_tag = match app.last_msg_transport {
        Some(crate::app::MsgTransport::Bridge) => "bridge",
        Some(crate::app::MsgTransport::Inbox) => "inbox",
        Some(crate::app::MsgTransport::Tmux) => "tmux",
        None => "ch",
    };

    let block = Block::default()
        .borders(Borders::TOP)
        .border_style(Style::default().fg(sol::BASE01))
        .title(Span::styled(
            format!(" Claude [{transport_tag}] "),
            Style::default().fg(sol::CYAN).add_modifier(Modifier::BOLD),
        ));

    let text = Paragraph::new(Line::from(vec![
        Span::styled("  ", Style::default()),
        Span::styled(msg, Style::default().fg(sol::BASE1)),
    ]))
    .block(block)
    .wrap(ratatui::widgets::Wrap { trim: true });

    frame.render_widget(text, area);
}

fn render_queue(frame: &mut Frame, app: &mut App, area: Rect) {
    let mut items: Vec<ListItem> = Vec::new();
    let mut row: usize = 0;

    // Completed runs — show arc_id, PR, and checkpoint-based duration
    for run in &app.completed_runs {
        let is_cursor = row == app.queue_cursor;
        let (icon, status_text, pr_text, color) = match &run.result {
            ArcCompletion::Merged { pr_url } => {
                let pr = format_pr_short(pr_url.as_deref());
                ("✓", "merged", pr, sol::GREEN)
            }
            ArcCompletion::Shipped { pr_url } => {
                let pr = format_pr_short(pr_url.as_deref());
                ("✓", "shipped", pr, sol::CYAN)
            }
            ArcCompletion::Cancelled { .. } => ("✗", "cancelled", String::new(), sol::ORANGE),
            ArcCompletion::Failed { .. } => ("✗", "failed", String::new(), sol::RED),
        };
        let dur = format_duration(Some(run.duration.as_secs() as i64));
        let arc_tag = run.arc_id.as_deref().unwrap_or("");
        let cursor_mark = if is_cursor { "›" } else { " " };

        let mut spans = vec![
            Span::styled(format!(" {cursor_mark}{icon} "), Style::default().fg(color)),
            Span::styled(&run.plan.name, Style::default().fg(sol::BASE0)),
        ];
        if !pr_text.is_empty() {
            spans.push(Span::styled(format!("  {pr_text}"), Style::default().fg(color)));
        } else {
            spans.push(Span::styled(format!("  {status_text}"), Style::default().fg(color)));
        }
        spans.push(Span::styled(format!("  {dur}"), Style::default().fg(sol::BASE01)));
        if !arc_tag.is_empty() {
            // Show shortened arc_id (last 10 chars) for traceability
            let short_arc = if arc_tag.len() > 14 { &arc_tag[arc_tag.len() - 10..] } else { arc_tag };
            spans.push(Span::styled(format!("  arc:{short_arc}"), Style::default().fg(sol::BASE01)));
        }
        items.push(ListItem::new(Line::from(spans)));
        row += 1;
    }

    // Currently running — uses its own config_idx, not selected_config
    if let Some(run) = &app.current_run {
        let is_cursor = row == app.queue_cursor;
        let phase = run.last_status.as_ref().map(|s| s.current_phase.as_str()).unwrap_or("discovering...");
        let run_cfg = app.config_dirs.get(run.config_idx).map(|c| c.label.as_str()).unwrap_or("?");
        let cursor_mark = if is_cursor { "›" } else { " " };
        items.push(ListItem::new(Line::from(vec![
            Span::styled(format!(" {cursor_mark}▶ "), Style::default().fg(sol::YELLOW)),
            Span::styled(&run.plan.name, Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
            Span::styled(format!("  {phase}"), Style::default().fg(sol::BASE0)),
            Span::styled(format!("  [{run_cfg}]"), Style::default().fg(sol::BASE01)),
        ])));
        row += 1;
    }

    // Pending in queue (deletable) — each entry has its own config dir
    for entry in &app.queue {
        if let Some(plan) = app.plans.get(entry.plan_idx) {
            let is_cursor = row == app.queue_cursor;
            let entry_cfg = app.config_dirs.get(entry.config_idx)
                .map(|c| c.label.as_str())
                .unwrap_or("?");
            let (name_style, marker_style) = if is_cursor {
                (
                    Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD),
                    Style::default().fg(sol::YELLOW),
                )
            } else {
                (
                    Style::default().fg(sol::BASE01),
                    Style::default().fg(sol::BASE01),
                )
            };
            let cursor_mark = if is_cursor { "›" } else { " " };
            items.push(ListItem::new(Line::from(vec![
                Span::styled(format!(" {cursor_mark}○ "), marker_style),
                Span::styled(&plan.name, name_style),
                Span::styled(format!("  [{entry_cfg}]"), Style::default().fg(sol::BASE01)),
            ])));
            row += 1;
        }
    }

    let _ = row; // suppress unused warning
    render_scrollable_list(
        frame,
        items,
        Block::default().borders(Borders::ALL)
            .border_style(Style::default().fg(sol::CYAN))
            .title(Span::styled(" Queue ", Style::default().fg(sol::BASE1))),
        area,
        app.queue_cursor,
        &mut app.queue_list_state,
    );
}

/// Helper: make a key-value Line.
fn make_kv(key: &str, val: &str, val_color: Color) -> Line<'static> {
    Line::from(vec![
        Span::styled(key.to_string(), Style::default().fg(sol::BASE01)),
        Span::styled(val.to_string(), Style::default().fg(val_color)),
    ])
}

/// Format unix epoch seconds to a local datetime string.
fn format_epoch(epoch: u64) -> String {
    use chrono::{Local, TimeZone};
    Local
        .timestamp_opt(epoch as i64, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "—".into())
}

/// Format uptime from unix epoch start_time.
fn format_uptime(start_time: u64) -> String {
    if start_time == 0 {
        return "—".into();
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let elapsed = now.saturating_sub(start_time) as i64;
    format_duration(Some(elapsed))
}

/// Format duration in seconds to a human-readable string.
fn format_duration(secs: Option<i64>) -> String {
    match secs {
        None => "—".into(),
        Some(s) if s < 0 => "—".into(),
        Some(s) if s < 60 => format!("{s}s"),
        Some(s) if s < 3600 => format!("{}m{}s", s / 60, s % 60),
        Some(s) => format!("{}h{}m", s / 3600, (s % 3600) / 60),
    }
}

/// Extract short PR reference from a full GitHub URL.
/// "https://github.com/user/repo/pull/331" → "PR #331"
fn format_pr_short(url: Option<&str>) -> String {
    match url {
        Some(u) => {
            if let Some(num) = u.rsplit('/').next() {
                format!("PR #{num}")
            } else {
                u.to_string()
            }
        }
        None => String::new(),
    }
}

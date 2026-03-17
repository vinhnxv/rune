use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};
use ratatui::Frame;

use crate::app::{App, AppView, ArcCompletion, Panel};
use crate::resource::ProcessHealth;

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

pub fn draw(frame: &mut Frame, app: &App) {
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
        AppView::Selection => render_selection(frame, app, area),
        AppView::Running => render_running(frame, app, area),
    }
}

// ── Selection View ──────────────────────────────────────────

fn render_selection(frame: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(5),
            Constraint::Length(1),
        ])
        .split(area);

    // Header
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" torrent ", Style::default().fg(sol::BASE03).bg(sol::BLUE).add_modifier(Modifier::BOLD)),
            Span::styled(" — Arc Orchestrator", Style::default().fg(sol::BASE0)),
        ])),
        chunks[0],
    );

    // Body: config + plans
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(35), Constraint::Percentage(65)])
        .split(chunks[1]);
    render_config_panel(frame, app, body[0]);
    render_plan_panel(frame, app, body[1]);

    // Status bar (only last message, not history)
    let status = if let Some(ref msg) = app.status_message {
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

fn render_config_panel(frame: &mut Frame, app: &App, area: Rect) {
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
    frame.render_widget(
        List::new(items).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(border))
                .title(Span::styled(" Config ", Style::default().fg(sol::BASE1)))
        ),
        area,
    );
}

fn render_plan_panel(frame: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = app.plans.iter().enumerate().map(|(i, plan)| {
        let order = app.selected_plans.iter().position(|&idx| idx == i);
        let marker = match order { Some(n) => format!("[{}]", n + 1), None => "[ ]".into() };
        let is_cursor = i == app.plan_cursor && app.active_panel == Panel::PlanList;
        let style = if is_cursor {
            Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)
        } else if order.is_some() {
            Style::default().fg(sol::CYAN)
        } else {
            Style::default().fg(sol::BASE0)
        };
        let mstyle = if order.is_some() { Style::default().fg(sol::GREEN) } else { Style::default().fg(sol::BASE01) };
        ListItem::new(Line::from(vec![
            Span::styled(format!(" {marker} "), mstyle),
            Span::styled(&plan.title, style),
        ]))
    }).collect();

    let border = if app.active_panel == Panel::PlanList { sol::CYAN } else { sol::BASE01 };
    frame.render_widget(
        List::new(items).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(border))
                .title(Span::styled(" Plans ", Style::default().fg(sol::BASE1)))
        ),
        area,
    );
}

// ── Running View ────────────────────────────────────────────

fn render_running(frame: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Length(8),
            Constraint::Length(7),  // expanded for resource info
            Constraint::Min(3),
            Constraint::Length(1),
        ])
        .split(area);

    // Header
    let cfg = app.config_dirs.get(app.selected_config).map(|c| c.label.as_str()).unwrap_or("?");
    let plan_info = app.current_run.as_ref()
        .map(|r| format!("Plan {}/{}", r.plan_index, r.total_plans))
        .unwrap_or_else(|| format!("Done — {}", app.completed_runs.len()));
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" torrent ", Style::default().fg(sol::BASE03).bg(sol::BLUE).add_modifier(Modifier::BOLD)),
            Span::styled(format!(" ⟫ {cfg} ⟫ {plan_info} "), Style::default().fg(sol::BASE0)),
        ])),
        chunks[0],
    );

    render_checkpoint(frame, app, chunks[1]);
    render_heartbeat(frame, app, chunks[2]);
    render_queue(frame, app, chunks[3]);

    // Status bar — only LAST message
    let status = app.status_message.as_deref()
        .unwrap_or(" [a] attach  [s] skip  [k] kill  [q] quit");
    frame.render_widget(
        Paragraph::new(status).style(Style::default().fg(sol::BASE01)),
        chunks[4],
    );
}

fn render_checkpoint(frame: &mut Frame, app: &App, area: Rect) {
    let lines = if let Some(run) = &app.current_run {
        if let Some(st) = &run.last_status {
            let s = &st.phase_summary;
            let mut l = vec![
                make_kv("  Arc:   ", &st.arc_id, sol::CYAN),
                Line::from(vec![
                    Span::styled("  Phase: ", Style::default().fg(sol::BASE01)),
                    Span::styled(&s.current_phase_name, Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
                    Span::styled(format!("  ({}/{}, {} skip)", s.completed, s.total, s.skipped), Style::default().fg(sol::BASE0)),
                ]),
                make_kv("  Plan:  ", &run.plan.name, sol::BASE0),
            ];
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
    } else {
        vec![Line::from(Span::styled("  All plans completed ✓", Style::default().fg(sol::GREEN)))]
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

            let mut l = vec![
                Line::from(vec![
                    Span::styled("  Activity: ", Style::default().fg(sol::BASE01)),
                    Span::styled(&st.last_activity, Style::default().fg(sol::BASE0)),
                    Span::raw("  "),
                    Span::styled(icon, Style::default().fg(color).add_modifier(Modifier::BOLD)),
                ]),
                make_kv("  Tool:     ", &st.last_tool, sol::BASE0),
                make_kv("  Phase:    ", &st.current_phase, sol::BASE0),
            ];

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

fn render_queue(frame: &mut Frame, app: &App, area: Rect) {
    let mut items: Vec<ListItem> = Vec::new();

    for run in &app.completed_runs {
        let (icon, desc, color) = match &run.result {
            ArcCompletion::Merged { pr_url } => ("✓", pr_url.as_deref().unwrap_or("merged").to_string(), sol::GREEN),
            ArcCompletion::Shipped { pr_url } => ("✓", pr_url.as_deref().unwrap_or("shipped").to_string(), sol::CYAN),
            ArcCompletion::Cancelled { .. } => ("✗", "cancelled".into(), sol::ORANGE),
            ArcCompletion::Failed { .. } => ("✗", "failed".into(), sol::RED),
        };
        let dur = format!("{}m", run.duration.as_secs() / 60);
        items.push(ListItem::new(Line::from(vec![
            Span::styled(format!("  {icon} "), Style::default().fg(color)),
            Span::styled(&run.plan.name, Style::default().fg(sol::BASE0)),
            Span::styled(format!("  {desc}  {dur}"), Style::default().fg(color)),
        ])));
    }

    if let Some(run) = &app.current_run {
        let phase = run.last_status.as_ref().map(|s| s.current_phase.as_str()).unwrap_or("discovering...");
        items.push(ListItem::new(Line::from(vec![
            Span::styled("  ▶ ", Style::default().fg(sol::YELLOW)),
            Span::styled(&run.plan.name, Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
            Span::styled(format!("  {phase}"), Style::default().fg(sol::BASE0)),
        ])));
    }

    for &idx in &app.queue {
        if let Some(plan) = app.plans.get(idx) {
            items.push(ListItem::new(Line::from(vec![
                Span::styled("  ○ ", Style::default().fg(sol::BASE01)),
                Span::styled(&plan.name, Style::default().fg(sol::BASE01)),
            ])));
        }
    }

    frame.render_widget(
        List::new(items).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(sol::CYAN))
                .title(Span::styled(" Queue ", Style::default().fg(sol::BASE1)))
        ),
        area,
    );
}

/// Helper: make a key-value Line.
fn make_kv(key: &str, val: &str, val_color: Color) -> Line<'static> {
    Line::from(vec![
        Span::styled(key.to_string(), Style::default().fg(sol::BASE01)),
        Span::styled(val.to_string(), Style::default().fg(val_color)),
    ])
}

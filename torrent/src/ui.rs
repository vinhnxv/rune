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
        AppView::ActiveArcs => render_active_arcs(frame, app, area),
        AppView::Selection => render_selection(frame, app, area),
        AppView::Running => render_running(frame, app, area),
    }
}

// ── Active Arcs View ───────────────────────────────────────

fn render_active_arcs(frame: &mut Frame, app: &App, area: Rect) {
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
            Span::styled(" torrent ", Style::default().fg(sol::BASE03).bg(sol::ORANGE).add_modifier(Modifier::BOLD)),
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
                // Shorten CWD: ~/Desktop/repos/rune-plugin → rune-plugin
                let short_cwd = si.cwd.rsplit('/').next().unwrap_or(&si.cwd);
                info_spans.push(Span::styled(format!("{short_cwd}"), Style::default().fg(sol::BASE0)));
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

    frame.render_widget(
        List::new(items).block(
            Block::default().borders(Borders::ALL)
                .border_style(Style::default().fg(sol::YELLOW))
                .title(Span::styled(" Active Sessions ", Style::default().fg(sol::BASE1)))
        ),
        chunks[2],
    );

    // Status bar
    frame.render_widget(
        Paragraph::new(" [m/Enter] monitor  [a] attach tmux  [n/Esc] new run  [q] quit")
            .style(Style::default().fg(sol::BASE01)),
        chunks[3],
    );
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

    // Header — different in queue-edit mode
    let header = if app.queue_editing {
        Line::from(vec![
            Span::styled(" torrent ", Style::default().fg(sol::BASE03).bg(sol::ORANGE).add_modifier(Modifier::BOLD)),
            Span::styled(" — Add Plans to Queue", Style::default().fg(sol::ORANGE)),
            Span::styled(format!("  ({} in queue)", app.queue.len()), Style::default().fg(sol::CYAN)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
        ])
    } else {
        Line::from(vec![
            Span::styled(" torrent ", Style::default().fg(sol::BASE03).bg(sol::BLUE).add_modifier(Modifier::BOLD)),
            Span::styled(" — Arc Orchestrator", Style::default().fg(sol::BASE0)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
        ])
    };
    frame.render_widget(Paragraph::new(header), chunks[0]);

    // Body: config + plans
    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(35), Constraint::Percentage(65)])
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

        // Show config dir label for selected plans
        let mut spans = vec![
            Span::styled(format!(" {marker} "), mstyle),
            Span::styled(&plan.title, style),
        ];
        if let Some(cfg_idx) = entry_config {
            let cfg = app.config_dirs.get(cfg_idx)
                .map(|c| c.label.as_str())
                .unwrap_or("?");
            spans.push(Span::styled(
                format!("  [{cfg}]"),
                Style::default().fg(sol::BASE01),
            ));
        }
        ListItem::new(Line::from(spans))
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
            Constraint::Length(13), // phases + session info + loop state
            Constraint::Length(6),  // heartbeat + resources (no phase)
            Constraint::Min(3),
            Constraint::Length(1),
        ])
        .split(area);

    // Header — use current run's config, not the selection cursor
    let run_config_idx = app.current_run.as_ref().map(|r| r.config_idx).unwrap_or(app.selected_config);
    let cfg = app.config_dirs.get(run_config_idx).map(|c| c.label.as_str()).unwrap_or("?");
    let plan_info = app.current_run.as_ref()
        .map(|r| format!("Plan {}/{}", r.plan_index, r.total_plans))
        .unwrap_or_else(|| format!("Done — {}", app.completed_runs.len()));
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" torrent ", Style::default().fg(sol::BASE03).bg(sol::BLUE).add_modifier(Modifier::BOLD)),
            Span::styled(format!(" ⟫ {cfg} ⟫ {plan_info}"), Style::default().fg(sol::BASE0)),
            Span::styled("  ⎇ ", Style::default().fg(sol::BASE01)),
            Span::styled(&app.git_branch, Style::default().fg(sol::GREEN)),
        ])),
        chunks[0],
    );

    render_checkpoint(frame, app, chunks[1]);
    render_heartbeat(frame, app, chunks[2]);
    render_queue(frame, app, chunks[3]);

    // Status bar — context-sensitive
    let all_done = app.current_run.is_none() && app.queue.is_empty() && !app.completed_runs.is_empty();
    let default_status = if all_done {
        " All done! [p] add plans  [q] quit"
    } else if !app.queue.is_empty() {
        " [a] attach  [s] skip  [k] kill  [p] add  [d] remove  [q] quit"
    } else {
        " [a] attach  [s] skip  [k] kill  [p] add plans  [q] quit"
    };
    let status = app.status_message.as_deref().unwrap_or(default_status);
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
                // Current phase (in progress, with elapsed)
                if let Some(ref curr) = nav.current {
                    l.push(Line::from(vec![
                        Span::styled("  ▶ Now: ", Style::default().fg(sol::YELLOW)),
                        Span::styled(&curr.name, Style::default().fg(sol::YELLOW).add_modifier(Modifier::BOLD)),
                        Span::styled(
                            format!("  {}", format_duration(curr.duration_secs)),
                            Style::default().fg(sol::ORANGE),
                        ),
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
                // Fallback: old-style single line
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
    } else {
        // All plans done — show summary
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

            let mut l = vec![
                Line::from(vec![
                    Span::styled("  Activity: ", Style::default().fg(sol::BASE01)),
                    Span::styled(&st.last_activity, Style::default().fg(sol::BASE0)),
                    Span::raw("  "),
                    Span::styled(icon, Style::default().fg(color).add_modifier(Modifier::BOLD)),
                ]),
                make_kv("  Tool:     ", &st.last_tool, sol::BASE0),
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
    let mut row: usize = 0;

    // Completed runs
    for run in &app.completed_runs {
        let is_cursor = row == app.queue_cursor;
        let (icon, desc, color) = match &run.result {
            ArcCompletion::Merged { pr_url } => ("✓", pr_url.as_deref().unwrap_or("merged").to_string(), sol::GREEN),
            ArcCompletion::Shipped { pr_url } => ("✓", pr_url.as_deref().unwrap_or("shipped").to_string(), sol::CYAN),
            ArcCompletion::Cancelled { .. } => ("✗", "cancelled".into(), sol::ORANGE),
            ArcCompletion::Failed { .. } => ("✗", "failed".into(), sol::RED),
        };
        let dur = format!("{}m", run.duration.as_secs() / 60);
        let cursor_mark = if is_cursor { "›" } else { " " };
        items.push(ListItem::new(Line::from(vec![
            Span::styled(format!(" {cursor_mark}{icon} "), Style::default().fg(color)),
            Span::styled(&run.plan.name, Style::default().fg(sol::BASE0)),
            Span::styled(format!("  {desc}  {dur}"), Style::default().fg(color)),
        ])));
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

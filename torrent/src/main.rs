mod app;
mod checkpoint;
mod keybindings;
mod monitor;
mod resource;
mod scanner;
mod tmux;
mod ui;

use std::time::Duration;

use color_eyre::Result;
use crossterm::event::{self, Event};

use crate::app::{App, AppView};
use crate::tmux::Tmux;

fn main() -> Result<()> {
    // Install panic/error hooks BEFORE ratatui::init() so panics restore terminal
    color_eyre::install()?;

    // Verify tmux is available before starting the TUI
    Tmux::verify_available()?;

    // Initialize terminal (raw mode + alternate screen)
    let mut terminal = ratatui::init();

    // Create application state (scans config dirs + plan files)
    let mut app = App::new()?;

    // Main event loop — 1s tick rate
    let tick_rate = Duration::from_secs(1);

    while !app.should_quit {
        // Draw current state
        terminal.draw(|frame| ui::draw(frame, &app))?;

        // Poll for input events with tick timeout
        if event::poll(tick_rate)? {
            if let Event::Key(key) = event::read()? {
                let action = keybindings::handle_key(&app, key);
                app.handle_action(action)?;
            }
        }

        // Tick execution logic (discovery, polling, grace period, next plan)
        match app.view {
            AppView::Running => app.tick_execution()?,
            AppView::ActiveArcs => app.prune_stale_active_arcs(),
            _ => {}
        }
    }

    // Restore terminal (disable raw mode + leave alternate screen)
    ratatui::restore();

    // Print summary to stdout
    app.print_quit_summary();

    Ok(())
}

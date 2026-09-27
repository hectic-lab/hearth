use std::error::Error;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEventKind};

use gitea_kanban_tui::api::{resolve_project, GiteaApi, GiteaClient};
use gitea_kanban_tui::app::{App, MoveAction};
use gitea_kanban_tui::config::{Backend, Config};
use gitea_kanban_tui::terminal::TerminalGuard;
use gitea_kanban_tui::ui;

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let config = Config::load()?;
    let client = GiteaClient::new(&config)?;
    let mut app = load_board(&client, &config)?;
    let repository = format!("{}/{}", config.owner, config.repo);
    let mut terminal = TerminalGuard::enter()?;

    loop {
        terminal
            .terminal()
            .draw(|frame| ui::draw(frame, &app, &repository))?;
        if !event::poll(Duration::from_millis(250))? {
            continue;
        }
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }

        match key.code {
            KeyCode::Char('q') => break,
            KeyCode::Left | KeyCode::Char('h') => app.focus_left(),
            KeyCode::Right | KeyCode::Char('l') => app.focus_right(),
            KeyCode::Up | KeyCode::Char('k') => app.focus_up(),
            KeyCode::Down | KeyCode::Char('j') => app.focus_down(),
            KeyCode::Char('H') => move_card(&client, &mut app, -1),
            KeyCode::Char('L') => move_card(&client, &mut app, 1),
            KeyCode::Char('r') => match load_board(&client, &config) {
                Ok(board) => app = board,
                Err(error) => app.status = format!("Refresh failed: {error}"),
            },
            KeyCode::Char('?') => app.show_help = !app.show_help,
            _ => {}
        }
    }
    Ok(())
}

fn load_board(client: &impl GiteaApi, config: &Config) -> Result<App, Box<dyn Error>> {
    match config.backend {
        Backend::Projects => {
            let projects = client.list_projects()?;
            let project = resolve_project(&projects, config.project.as_deref(), config.project_id)?;
            let columns = client.list_project_columns(project.id)?;
            let issues_by_column = columns
                .iter()
                .map(|column| client.list_project_column_issues(project.id, column.id))
                .collect::<Result<Vec<_>, _>>()?;
            App::new_project(project, columns, issues_by_column).map_err(|error| error.into())
        }
        Backend::Labels => {
            let labels = client.list_labels()?;
            let issues = client.list_open_issues()?;
            App::new_labels(labels, issues, config.label_prefix.clone())
                .map_err(|error| error.into())
        }
    }
}

fn move_card(client: &impl GiteaApi, app: &mut App, offset: isize) {
    let Some(request) = app.prepare_move(offset) else {
        app.status = "Cannot move card beyond board edge".to_owned();
        return;
    };
    let result = match &request.action {
        MoveAction::Project {
            issue_id,
            project_id,
            payload,
        } => client.move_project_issue(*project_id, *issue_id, payload),
        MoveAction::Labels {
            issue_number,
            payload,
        } => client.replace_issue_labels(*issue_number, payload),
    };
    match result {
        Ok(()) => app.apply_move(request),
        Err(error) => app.status = format!("Move failed: {error}"),
    }
}

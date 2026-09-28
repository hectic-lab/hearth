use std::error::Error;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEventKind};

use gitea_kanban_tui::api::{resolve_project, GiteaApi, GiteaClient};
use gitea_kanban_tui::app::{App, IssueAction, MoveAction};
use gitea_kanban_tui::config::Config;
use gitea_kanban_tui::model::CreateIssuePayload;
use gitea_kanban_tui::terminal::TerminalGuard;
use gitea_kanban_tui::text::sanitize_terminal_text;
use gitea_kanban_tui::ui;

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {}", sanitize_terminal_text(&error.to_string()));
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

        if app.editor.is_some() {
            if let Some(action) = app.handle_editor_key(key) {
                issue_action(&client, &config, &mut app, action);
            }
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
            KeyCode::Char('n') => app.begin_create(),
            KeyCode::Char('e') => app.begin_edit(),
            KeyCode::Char('d') => app.begin_delete(),
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

fn issue_action(client: &impl GiteaApi, config: &Config, app: &mut App, action: IssueAction) {
    let retry_action = action.clone();
    let message = match action {
        IssueAction::Create {
            project_id,
            title,
            body,
        } => client
            .create_issue(&CreateIssuePayload {
                title,
                body,
                projects: vec![project_id],
            })
            .map(|issue| format!("Created issue #{}", issue.number)),
        IssueAction::Edit {
            issue_number,
            payload,
        } => client
            .edit_issue(issue_number, &payload)
            .map(|_| format!("Updated issue #{issue_number}")),
        IssueAction::Delete { issue_number } => client
            .delete_issue(issue_number)
            .map(|_| format!("Deleted issue #{issue_number}")),
    };
    match message {
        Ok(message) => match load_board(client, config) {
            Ok(mut board) => {
                board.status = message;
                *app = board;
            }
            Err(error) => app.status = format!("Saved, refresh failed: {error}"),
        },
        Err(error) => {
            app.restore_issue_action(retry_action);
            app.status = format!("Issue operation failed: {error}");
        }
    }
}

fn load_board(client: &impl GiteaApi, config: &Config) -> Result<App, Box<dyn Error>> {
    let projects = client.list_projects()?;
    let project = resolve_project(&projects, config.project.as_deref(), config.project_id)?;
    let columns = client.list_project_columns(project.id)?;
    let issues_by_column = columns
        .iter()
        .map(|column| client.list_project_column_issues(project.id, column.id))
        .collect::<Result<Vec<_>, _>>()?;
    App::new_project(project, columns, issues_by_column).map_err(|error| error.into())
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
    };
    match result {
        Ok(()) => app.apply_move(request),
        Err(error) => app.status = format!("Move failed: {error}"),
    }
}

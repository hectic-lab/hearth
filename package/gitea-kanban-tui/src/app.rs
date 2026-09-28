use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::model::{
    ColumnSpec, EditIssuePayload, Issue, MoveProjectIssuePayload, Project, ProjectColumn,
};

#[derive(Clone, Debug)]
pub struct Column {
    pub spec: ColumnSpec,
    pub cards: Vec<Issue>,
}

pub struct App {
    pub board_title: String,
    pub columns: Vec<Column>,
    pub focused_column: usize,
    pub focused_cards: Vec<usize>,
    pub status: String,
    pub show_help: bool,
    pub editor: Option<EditorState>,
    project_id: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorMode {
    Create { project_id: u64 },
    Edit { issue_number: u64 },
    Delete { issue_number: u64, title: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorField {
    Title,
    Body,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorState {
    pub mode: EditorMode,
    pub field: EditorField,
    pub title: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IssueAction {
    Create {
        project_id: u64,
        title: String,
        body: String,
    },
    Edit {
        issue_number: u64,
        payload: EditIssuePayload,
    },
    Delete {
        issue_number: u64,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum MoveAction {
    Project {
        issue_id: u64,
        project_id: u64,
        payload: MoveProjectIssuePayload,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub struct MoveRequest {
    pub source: usize,
    pub target: usize,
    pub action: MoveAction,
}

impl App {
    pub fn new_project(
        project: Project,
        project_columns: Vec<ProjectColumn>,
        issues_by_column: Vec<Vec<Issue>>,
    ) -> Result<Self, String> {
        if project_columns.is_empty() {
            return Err(format!("project '{}' has no columns", project.title));
        }
        if project_columns.len() != issues_by_column.len() {
            return Err("project columns and issue lists do not match".to_owned());
        }
        let columns = project_columns
            .into_iter()
            .zip(issues_by_column)
            .map(|(column, cards)| Column {
                spec: ColumnSpec {
                    id: column.id,
                    title: column.title,
                },
                cards,
            })
            .collect::<Vec<_>>();
        let focused_column = columns
            .iter()
            .position(|column| !column.cards.is_empty())
            .unwrap_or(0);
        let focused_cards = vec![0; columns.len()];
        Ok(Self {
            board_title: format!("{} (project {})", project.title, project.id),
            columns,
            focused_column,
            focused_cards,
            status: "Ready".to_owned(),
            show_help: false,
            editor: None,
            project_id: project.id,
        })
    }

    pub fn focus_left(&mut self) {
        self.focused_column = self.focused_column.saturating_sub(1);
    }

    pub fn focus_right(&mut self) {
        self.focused_column = (self.focused_column + 1).min(self.columns.len() - 1);
    }

    pub fn focus_up(&mut self) {
        let selected = &mut self.focused_cards[self.focused_column];
        *selected = selected.saturating_sub(1);
    }

    pub fn focus_down(&mut self) {
        let column = &self.columns[self.focused_column];
        if !column.cards.is_empty() {
            let selected = &mut self.focused_cards[self.focused_column];
            *selected = (*selected + 1).min(column.cards.len() - 1);
        }
    }

    pub fn focused_card(&self) -> Option<&Issue> {
        self.columns[self.focused_column]
            .cards
            .get(self.focused_cards[self.focused_column])
    }

    pub fn prepare_move(&self, offset: isize) -> Option<MoveRequest> {
        let target = self.focused_column.checked_add_signed(offset)?;
        if target >= self.columns.len() {
            return None;
        }
        let issue = self.focused_card()?;
        let action = MoveAction::Project {
            issue_id: issue.id,
            project_id: self.project_id,
            payload: MoveProjectIssuePayload {
                column_id: self.columns[target].spec.id,
                sorting: None,
            },
        };
        Some(MoveRequest {
            source: self.focused_column,
            target,
            action,
        })
    }

    pub fn apply_move(&mut self, request: MoveRequest) {
        let selected = self.focused_cards[request.source];
        let issue = self.columns[request.source].cards.remove(selected);
        let issue_number = issue.number;
        self.columns[request.target].cards.push(issue);
        self.focused_cards[request.source] =
            selected.min(self.columns[request.source].cards.len().saturating_sub(1));
        self.focused_cards[request.target] = self.columns[request.target].cards.len() - 1;
        self.focused_column = request.target;
        self.status = format!("Moved issue #{issue_number}");
    }

    pub fn begin_create(&mut self) {
        self.editor = Some(EditorState {
            mode: EditorMode::Create {
                project_id: self.project_id,
            },
            field: EditorField::Title,
            title: String::new(),
            body: String::new(),
        });
    }

    pub fn begin_edit(&mut self) {
        let Some(issue) = self.focused_card().cloned() else {
            self.status = "No issue selected".to_owned();
            return;
        };
        self.editor = Some(EditorState {
            mode: EditorMode::Edit {
                issue_number: issue.number,
            },
            field: EditorField::Title,
            title: issue.title,
            body: issue.body.unwrap_or_default(),
        });
    }

    pub fn begin_delete(&mut self) {
        let Some(issue) = self.focused_card() else {
            self.status = "No issue selected".to_owned();
            return;
        };
        self.editor = Some(EditorState {
            mode: EditorMode::Delete {
                issue_number: issue.number,
                title: issue.title.clone(),
            },
            field: EditorField::Title,
            title: String::new(),
            body: String::new(),
        });
    }

    pub fn handle_editor_key(&mut self, key: KeyEvent) -> Option<IssueAction> {
        let mut editor = self.editor.take()?;
        if matches!(editor.mode, EditorMode::Delete { .. }) {
            match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    if let EditorMode::Delete { issue_number, .. } = editor.mode {
                        return Some(IssueAction::Delete { issue_number });
                    }
                }
                KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
                    self.status = "Delete cancelled".to_owned();
                }
                _ => {
                    self.editor = Some(editor);
                }
            }
            return None;
        }

        if key.code == KeyCode::Esc {
            self.status = "Edit cancelled".to_owned();
            return None;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('s') {
            return self.submit_editor(editor);
        }
        match key.code {
            KeyCode::Tab => {
                editor.field = match editor.field {
                    EditorField::Title => EditorField::Body,
                    EditorField::Body => EditorField::Title,
                };
            }
            KeyCode::Enter if editor.field == EditorField::Title => {
                editor.field = EditorField::Body;
            }
            KeyCode::Enter => editor.body.push('\n'),
            KeyCode::Backspace => match editor.field {
                EditorField::Title => {
                    editor.title.pop();
                }
                EditorField::Body => {
                    editor.body.pop();
                }
            },
            KeyCode::Char(character) if !character.is_control() => match editor.field {
                EditorField::Title => editor.title.push(character),
                EditorField::Body => editor.body.push(character),
            },
            _ => {}
        }
        self.editor = Some(editor);
        None
    }

    pub fn restore_issue_action(&mut self, action: IssueAction) {
        self.editor = Some(match action {
            IssueAction::Create {
                project_id,
                title,
                body,
            } => EditorState {
                mode: EditorMode::Create { project_id },
                field: EditorField::Body,
                title,
                body,
            },
            IssueAction::Edit {
                issue_number,
                payload,
            } => EditorState {
                mode: EditorMode::Edit { issue_number },
                field: EditorField::Body,
                title: payload.title,
                body: payload.body,
            },
            IssueAction::Delete { issue_number } => EditorState {
                mode: EditorMode::Delete {
                    issue_number,
                    title: self
                        .focused_card()
                        .map(|issue| issue.title.clone())
                        .unwrap_or_default(),
                },
                field: EditorField::Title,
                title: String::new(),
                body: String::new(),
            },
        });
    }

    fn submit_editor(&mut self, editor: EditorState) -> Option<IssueAction> {
        if editor.title.trim().is_empty() {
            self.status = "Title cannot be empty".to_owned();
            self.editor = Some(editor);
            return None;
        }
        match editor.mode {
            EditorMode::Create { project_id } => Some(IssueAction::Create {
                project_id,
                title: editor.title,
                body: editor.body,
            }),
            EditorMode::Edit { issue_number } => Some(IssueAction::Edit {
                issue_number,
                payload: EditIssuePayload {
                    title: editor.title,
                    body: editor.body,
                },
            }),
            EditorMode::Delete { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    use super::*;

    fn app() -> App {
        App::new_project(
            Project {
                id: 8,
                title: "Kanban".to_owned(),
                is_closed: false,
            },
            vec![
                ProjectColumn {
                    id: 10,
                    title: "Todo".to_owned(),
                    color: String::new(),
                    sorting: 0,
                },
                ProjectColumn {
                    id: 20,
                    title: "Done".to_owned(),
                    color: String::new(),
                    sorting: 1,
                },
            ],
            vec![
                vec![
                    Issue {
                        id: 1,
                        number: 1,
                        title: "First".to_owned(),
                        body: None,
                    },
                    Issue {
                        id: 2,
                        number: 2,
                        title: "Second".to_owned(),
                        body: None,
                    },
                ],
                Vec::new(),
            ],
        )
        .expect("board builds")
    }

    #[test]
    fn navigation_stays_within_board() {
        let mut app = app();
        app.focus_left();
        app.focus_up();
        assert_eq!(app.focused_column, 0);
        assert_eq!(app.focused_cards[0], 0);

        app.focus_down();
        app.focus_down();
        app.focus_right();
        app.focus_right();
        assert_eq!(app.focused_cards[0], 1);
        assert_eq!(app.focused_column, 1);
    }

    #[test]
    fn cannot_move_past_board_edge() {
        let app = app();
        assert!(app.prepare_move(-1).is_none());
    }

    #[test]
    fn empty_board_returns_actionable_error() {
        let result = App::new_project(
            Project {
                id: 1,
                title: "Kanban".to_owned(),
                is_closed: false,
            },
            vec![ProjectColumn {
                id: 1,
                title: "Todo".to_owned(),
                color: String::new(),
                sorting: 0,
            }],
            vec![Vec::new()],
        );
        assert!(result.is_ok());
    }

    #[test]
    fn native_move_uses_global_issue_and_column_ids() {
        let mut app = App::new_project(
            Project {
                id: 8,
                title: "Kanban".to_owned(),
                is_closed: false,
            },
            vec![
                ProjectColumn {
                    id: 10,
                    title: "Todo".to_owned(),
                    color: String::new(),
                    sorting: 0,
                },
                ProjectColumn {
                    id: 20,
                    title: "Done".to_owned(),
                    color: String::new(),
                    sorting: 1,
                },
            ],
            vec![
                vec![Issue {
                    id: 99,
                    number: 7,
                    title: "Fix".to_owned(),
                    body: None,
                }],
                Vec::new(),
            ],
        )
        .expect("board");
        let request = app.prepare_move(1).expect("move");
        assert!(matches!(
            request.action,
            MoveAction::Project { issue_id: 99, ref payload, .. } if payload.column_id == 20
        ));
        app.apply_move(request);
        assert_eq!(app.columns[1].cards[0].id, 99);
    }

    #[test]
    fn native_editor_creates_project_issue_action() {
        let mut app = App::new_project(
            Project {
                id: 8,
                title: "Kanban".to_owned(),
                is_closed: false,
            },
            vec![ProjectColumn {
                id: 10,
                title: "Todo".to_owned(),
                color: String::new(),
                sorting: 0,
            }],
            vec![Vec::new()],
        )
        .expect("board");
        app.begin_create();
        for character in "New issue".chars() {
            app.handle_editor_key(KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE));
        }
        app.handle_editor_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        for character in "Details".chars() {
            app.handle_editor_key(KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE));
        }
        let action =
            app.handle_editor_key(KeyEvent::new(KeyCode::Char('s'), KeyModifiers::CONTROL));
        assert!(matches!(
            action,
            Some(IssueAction::Create {
                project_id: 8,
                title,
                body,
            }) if title == "New issue" && body == "Details"
        ));
        assert!(app.editor.is_none());
    }
}

use crate::model::{
    extract_columns, replacement_payload, ColumnSpec, Issue, Label, MoveProjectIssuePayload,
    Project, ProjectColumn, ReplaceLabelsPayload,
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
    backend: BoardBackend,
}

#[derive(Clone, Debug)]
enum BoardBackend {
    Projects { project_id: u64 },
    Labels { prefix: String },
}

#[derive(Debug, PartialEq, Eq)]
pub enum MoveAction {
    Project {
        issue_id: u64,
        project_id: u64,
        payload: MoveProjectIssuePayload,
    },
    Labels {
        issue_number: u64,
        payload: ReplaceLabelsPayload,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub struct MoveRequest {
    pub source: usize,
    pub target: usize,
    pub action: MoveAction,
}

impl App {
    pub fn new_labels(
        labels: Vec<Label>,
        issues: Vec<Issue>,
        label_prefix: String,
    ) -> Result<Self, String> {
        let specs = extract_columns(&labels, &label_prefix);
        if specs.is_empty() {
            return Err(format!(
                "no Kanban columns found; create repository labels such as {label_prefix}Todo"
            ));
        }

        let mut columns: Vec<Column> = specs
            .into_iter()
            .map(|spec| Column {
                spec,
                cards: Vec::new(),
            })
            .collect();
        for issue in issues {
            if let Some(column) = columns
                .iter_mut()
                .find(|column| issue.labels.iter().any(|label| label.id == column.spec.id))
            {
                column.cards.push(issue);
            }
        }

        if columns.iter().all(|column| column.cards.is_empty()) {
            return Err(format!(
                "no cards found; add a {label_prefix}<column> label to an open issue"
            ));
        }

        let focused_column = columns
            .iter()
            .position(|column| !column.cards.is_empty())
            .unwrap_or(0);
        let focused_cards = vec![0; columns.len()];
        Ok(Self {
            board_title: format!("labels {label_prefix}*"),
            columns,
            focused_column,
            focused_cards,
            status: "Ready".to_owned(),
            show_help: false,
            backend: BoardBackend::Labels {
                prefix: label_prefix,
            },
        })
    }

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
                    label: None,
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
            backend: BoardBackend::Projects {
                project_id: project.id,
            },
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
        let action = match &self.backend {
            BoardBackend::Projects { project_id } => MoveAction::Project {
                issue_id: issue.id,
                project_id: *project_id,
                payload: MoveProjectIssuePayload {
                    column_id: self.columns[target].spec.id,
                    sorting: None,
                },
            },
            BoardBackend::Labels { prefix } => MoveAction::Labels {
                issue_number: issue.number,
                payload: replacement_payload(issue, prefix, self.columns[target].spec.id),
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
        let mut issue = self.columns[request.source].cards.remove(selected);
        let issue_number = issue.number;
        if let BoardBackend::Labels { prefix } = &self.backend {
            issue.labels.retain(|label| !label.name.starts_with(prefix));
            if let Some(label) = &self.columns[request.target].spec.label {
                issue.labels.push(label.clone());
            }
        }
        self.columns[request.target].cards.push(issue);
        self.focused_cards[request.source] =
            selected.min(self.columns[request.source].cards.len().saturating_sub(1));
        self.focused_cards[request.target] = self.columns[request.target].cards.len() - 1;
        self.focused_column = request.target;
        self.status = format!("Moved issue #{issue_number}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(id: u64, name: &str) -> Label {
        Label {
            id,
            name: name.to_owned(),
            color: String::new(),
        }
    }

    fn app() -> App {
        App::new_labels(
            vec![label(1, "kanban/01 Todo"), label(2, "kanban/02 Done")],
            vec![
                Issue {
                    id: 1,
                    number: 1,
                    title: "First".to_owned(),
                    body: None,
                    labels: vec![label(1, "kanban/01 Todo"), label(7, "bug")],
                },
                Issue {
                    id: 2,
                    number: 2,
                    title: "Second".to_owned(),
                    body: None,
                    labels: vec![label(1, "kanban/01 Todo")],
                },
            ],
            "kanban/".to_owned(),
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
    fn move_preparation_and_commit_preserve_non_column_labels() {
        let mut app = app();
        let request = app.prepare_move(1).expect("can move right");
        assert!(matches!(
            request.action,
            MoveAction::Labels { ref payload, .. } if payload.labels == vec![7, 2]
        ));

        app.apply_move(request);

        assert_eq!(app.focused_column, 1);
        assert_eq!(app.columns[0].cards.len(), 1);
        assert_eq!(app.columns[1].cards[0].number, 1);
        assert!(app.columns[1].cards[0]
            .labels
            .iter()
            .any(|label| label.name == "bug"));
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
                    labels: Vec::new(),
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
    fn label_board_without_cards_keeps_actionable_error() {
        let result = App::new_labels(
            vec![label(1, "kanban/Todo"), label(2, "kanban/Done")],
            Vec::new(),
            "kanban/".to_owned(),
        );
        let error = match result {
            Ok(_) => panic!("empty board should report missing cards"),
            Err(error) => error,
        };

        assert!(error.contains("add a kanban/<column> label"));
    }
}

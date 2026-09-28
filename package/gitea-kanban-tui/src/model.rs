use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Label {
    pub id: u64,
    pub name: String,
    #[serde(default)]
    pub color: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Issue {
    pub id: u64,
    pub number: u64,
    pub title: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub labels: Vec<Label>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CreateIssuePayload {
    pub title: String,
    pub body: String,
    pub projects: Vec<u64>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct EditIssuePayload {
    pub title: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColumnSpec {
    pub id: u64,
    pub label: Option<Label>,
    pub title: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Project {
    pub id: u64,
    pub title: String,
    #[serde(default)]
    pub is_closed: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ProjectColumn {
    pub id: u64,
    pub title: String,
    #[serde(default)]
    pub color: String,
    #[serde(default)]
    pub sorting: i8,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct MoveProjectIssuePayload {
    pub column_id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sorting: Option<u64>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ReplaceLabelsPayload {
    pub labels: Vec<u64>,
}

pub fn extract_columns(labels: &[Label], prefix: &str) -> Vec<ColumnSpec> {
    let mut columns: Vec<ColumnSpec> = labels
        .iter()
        .filter_map(|label| {
            let title = label.name.strip_prefix(prefix)?;
            if title.is_empty() {
                None
            } else {
                Some(ColumnSpec {
                    id: label.id,
                    label: Some(label.clone()),
                    title: title.to_owned(),
                })
            }
        })
        .collect();
    columns.sort_by(|left, right| left.title.cmp(&right.title));
    columns
}

pub fn replacement_payload(
    issue: &Issue,
    column_prefix: &str,
    target_label_id: u64,
) -> ReplaceLabelsPayload {
    let mut labels: Vec<u64> = issue
        .labels
        .iter()
        .filter(|label| !label.name.starts_with(column_prefix))
        .map(|label| label.id)
        .collect();
    labels.push(target_label_id);
    ReplaceLabelsPayload { labels }
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

    #[test]
    fn extracts_prefixed_columns_in_lexical_order() {
        let labels = vec![
            label(1, "bug"),
            label(3, "kanban/Doing"),
            label(2, "kanban/Todo"),
            label(4, "kanban/"),
        ];

        let columns = extract_columns(&labels, "kanban/");

        assert_eq!(columns.len(), 2);
        assert_eq!(columns[0].title, "Doing");
        assert_eq!(columns[1].label.as_ref().expect("label").id, 2);
    }

    #[test]
    fn replacement_removes_columns_and_preserves_other_labels() {
        let issue = Issue {
            id: 70,
            number: 7,
            title: "Fix it".to_owned(),
            body: None,
            labels: vec![label(1, "bug"), label(2, "kanban/Todo"), label(3, "urgent")],
        };

        let payload = replacement_payload(&issue, "kanban/", 9);

        assert_eq!(payload.labels, vec![1, 3, 9]);
        assert_eq!(
            serde_json::to_value(payload).expect("serialize payload"),
            serde_json::json!({"labels": [1, 3, 9]})
        );
    }

    #[test]
    fn deserializes_native_project_data_and_move_payload() {
        let project: Project = serde_json::from_value(serde_json::json!({
            "id": 4,
            "title": "Kanban",
            "is_closed": false
        }))
        .expect("project JSON");
        let column: ProjectColumn = serde_json::from_value(serde_json::json!({
            "id": 9,
            "title": "Doing",
            "sorting": 1
        }))
        .expect("column JSON");
        let issue: Issue = serde_json::from_value(serde_json::json!({
            "id": 70,
            "number": 7,
            "title": "Fix it"
        }))
        .expect("issue JSON");
        let payload = MoveProjectIssuePayload {
            column_id: column.id,
            sorting: Some(3),
        };

        assert_eq!(project.title, "Kanban");
        assert_eq!(issue.id, 70);
        assert_eq!(
            serde_json::to_value(payload).expect("move payload"),
            serde_json::json!({"column_id": 9, "sorting": 3})
        );
    }

    #[test]
    fn serializes_issue_create_and_edit_payloads() {
        let create = CreateIssuePayload {
            title: "New issue".to_owned(),
            body: "Details".to_owned(),
            projects: vec![4],
        };
        let edit = EditIssuePayload {
            title: "Updated".to_owned(),
            body: "Changed".to_owned(),
        };
        assert_eq!(
            serde_json::to_value(create).expect("create payload"),
            serde_json::json!({"title": "New issue", "body": "Details", "projects": [4]})
        );
        assert_eq!(
            serde_json::to_value(edit).expect("edit payload"),
            serde_json::json!({"title": "Updated", "body": "Changed"})
        );
    }
}

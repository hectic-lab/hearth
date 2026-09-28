use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Issue {
    pub id: u64,
    pub number: u64,
    pub title: String,
    #[serde(default)]
    pub body: Option<String>,
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

#[cfg(test)]
mod tests {
    use super::*;

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

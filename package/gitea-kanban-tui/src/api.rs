use std::fmt;
use std::time::Duration;

use reqwest::blocking::{Client, Response};
use reqwest::redirect::Policy;
use reqwest::{StatusCode, Url};
use serde::de::DeserializeOwned;

use crate::config::Config;
use crate::model::{
    Issue, Label, MoveProjectIssuePayload, Project, ProjectColumn, ReplaceLabelsPayload,
};
use crate::text::sanitize_terminal_text;

pub trait GiteaApi {
    fn list_projects(&self) -> Result<Vec<Project>, ApiError>;
    fn list_project_columns(&self, project_id: u64) -> Result<Vec<ProjectColumn>, ApiError>;
    fn list_project_column_issues(
        &self,
        project_id: u64,
        column_id: u64,
    ) -> Result<Vec<Issue>, ApiError>;
    fn move_project_issue(
        &self,
        project_id: u64,
        issue_id: u64,
        payload: &MoveProjectIssuePayload,
    ) -> Result<(), ApiError>;
    fn list_labels(&self) -> Result<Vec<Label>, ApiError>;
    fn list_open_issues(&self) -> Result<Vec<Issue>, ApiError>;
    fn replace_issue_labels(
        &self,
        issue_number: u64,
        payload: &ReplaceLabelsPayload,
    ) -> Result<(), ApiError>;
}

pub struct GiteaClient {
    client: Client,
    api_base: Url,
    token: String,
}

#[derive(Debug)]
pub struct ApiError(String);

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ApiError {}

pub fn resolve_project(
    projects: &[Project],
    project_name: Option<&str>,
    project_id: Option<u64>,
) -> Result<Project, ApiError> {
    if let Some(id) = project_id {
        return projects
            .iter()
            .find(|project| project.id == id)
            .cloned()
            .ok_or_else(|| ApiError(format!("project ID {id} was not found in this repository")));
    }
    let name = project_name.ok_or_else(|| ApiError("project selector is missing".to_owned()))?;
    let matches = projects
        .iter()
        .filter(|project| project.title == name)
        .cloned()
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [project] => Ok(project.clone()),
        [] => Err(ApiError(format!(
            "project named '{name}' was not found; names are matched exactly"
        ))),
        _ => Err(ApiError(format!(
            "multiple projects are named '{name}'; use --project-id"
        ))),
    }
}

impl GiteaClient {
    pub fn new(config: &Config) -> Result<Self, ApiError> {
        let mut api_base = Url::parse(&config.base_url)
            .map_err(|error| ApiError(format!("invalid Gitea URL: {error}")))?;
        require_secure_transport(&api_base)?;
        api_base.set_query(None);
        api_base.set_fragment(None);
        api_base
            .path_segments_mut()
            .map_err(|_| ApiError("Gitea URL cannot be used as an API base".to_owned()))?
            .pop_if_empty()
            .extend(["api", "v1", "repos", &config.owner, &config.repo]);

        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(concat!("gitea-kanban-tui/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| ApiError(format!("cannot create HTTP client: {error}")))?;

        Ok(Self {
            client,
            api_base,
            token: config.token.clone(),
        })
    }

    fn endpoint(&self, path: &str) -> Result<Url, ApiError> {
        let mut url = self.api_base.clone();
        url.path_segments_mut()
            .map_err(|_| ApiError("Gitea URL cannot contain API paths".to_owned()))?
            .extend(path.split('/').filter(|part| !part.is_empty()));
        Ok(url)
    }

    fn decode<T: DeserializeOwned>(
        &self,
        response: Response,
        operation: &str,
    ) -> Result<T, ApiError> {
        let response = check_response(response, operation)?;
        response.json().map_err(|error| {
            ApiError(format!(
                "Gitea returned invalid JSON while {operation}: {error}"
            ))
        })
    }

    fn get_all<T: DeserializeOwned>(
        &self,
        path: &str,
        operation: &str,
        query: &[(&str, &str)],
    ) -> Result<Vec<T>, ApiError> {
        let mut items = Vec::new();
        for page in 1..=10_000_u32 {
            let page_value = page.to_string();
            let mut page_query = query.to_vec();
            page_query.extend([("limit", "100"), ("page", page_value.as_str())]);
            let response = self
                .client
                .get(self.endpoint(path)?)
                .query(&page_query)
                .header("Authorization", format!("token {}", self.token))
                .send()
                .map_err(|error| {
                    ApiError(format!("cannot reach Gitea while {operation}: {error}"))
                })?;
            let page_items: Vec<T> = self.decode(response, operation)?;
            if page_items.is_empty() {
                return Ok(items);
            }
            items.extend(page_items);
        }
        Err(ApiError(format!(
            "Gitea returned too many pages while {operation}; narrow repository data or check server pagination"
        )))
    }
}

impl GiteaApi for GiteaClient {
    fn list_projects(&self) -> Result<Vec<Project>, ApiError> {
        self.get_all(
            "projects",
            "listing repository projects",
            &[("state", "all")],
        )
    }

    fn list_project_columns(&self, project_id: u64) -> Result<Vec<ProjectColumn>, ApiError> {
        let response = self
            .client
            .get(self.endpoint(&format!("projects/{project_id}/columns"))?)
            .header("Authorization", format!("token {}", self.token))
            .send()
            .map_err(|error| {
                ApiError(format!(
                    "cannot reach Gitea while listing project columns: {error}"
                ))
            })?;
        self.decode(response, "listing project columns")
    }

    fn list_project_column_issues(
        &self,
        project_id: u64,
        column_id: u64,
    ) -> Result<Vec<Issue>, ApiError> {
        self.get_all(
            &format!("projects/{project_id}/columns/{column_id}/issues"),
            "listing project issues",
            &[],
        )
    }

    fn move_project_issue(
        &self,
        project_id: u64,
        issue_id: u64,
        payload: &MoveProjectIssuePayload,
    ) -> Result<(), ApiError> {
        let response = self
            .client
            .post(self.endpoint(&format!("projects/{project_id}/issues/{issue_id}/move"))?)
            .header("Authorization", format!("token {}", self.token))
            .json(payload)
            .send()
            .map_err(|error| {
                ApiError(format!(
                    "cannot reach Gitea while moving project issue: {error}"
                ))
            })?;
        check_response(response, "moving project issue")?;
        Ok(())
    }

    fn list_labels(&self) -> Result<Vec<Label>, ApiError> {
        self.get_all("labels", "listing repository labels", &[])
    }

    fn list_open_issues(&self) -> Result<Vec<Issue>, ApiError> {
        self.get_all(
            "issues",
            "listing open repository issues",
            &[("state", "open"), ("type", "issues")],
        )
    }

    fn replace_issue_labels(
        &self,
        issue_number: u64,
        payload: &ReplaceLabelsPayload,
    ) -> Result<(), ApiError> {
        let response = self
            .client
            .put(self.endpoint(&format!("issues/{issue_number}/labels"))?)
            .header("Authorization", format!("token {}", self.token))
            .json(payload)
            .send()
            .map_err(|error| {
                ApiError(format!(
                    "cannot reach Gitea while moving issue #{issue_number}: {error}"
                ))
            })?;
        check_response(
            response,
            &format!("replacing labels on issue #{issue_number}"),
        )?;
        Ok(())
    }
}

fn check_response(response: Response, operation: &str) -> Result<Response, ApiError> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }

    let message = response
        .text()
        .ok()
        .and_then(|body| serde_json::from_str::<serde_json::Value>(&body).ok())
        .and_then(|value| value.get("message")?.as_str().map(sanitize_terminal_text));
    let detail = message
        .map(|message| format!(": {message}"))
        .unwrap_or_default();
    let guidance = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            " Check token validity and repository issue permissions."
        }
        StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED => {
            " Check repository owner/name and whether this Gitea version supports repository issue-label APIs."
        }
        _ => "",
    };
    Err(ApiError(format!(
        "Gitea API failed while {operation} ({status}){detail}.{guidance}"
    )))
}

fn require_secure_transport(url: &Url) -> Result<(), ApiError> {
    if url.scheme() == "https" {
        return Ok(());
    }
    let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    if url.scheme() == "http" && loopback {
        return Ok(());
    }
    Err(ApiError(
        "Gitea URL must use HTTPS to protect the API token; plain HTTP is allowed only for loopback development"
            .to_owned(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc::{self, Receiver};
    use std::thread;

    fn config(base_url: &str) -> Config {
        Config {
            base_url: base_url.to_owned(),
            token: "secret".to_owned(),
            owner: "owner name".to_owned(),
            repo: "repo/name".to_owned(),
            backend: crate::config::Backend::Labels,
            project: None,
            project_id: None,
            label_prefix: "kanban/".to_owned(),
        }
    }

    fn mock_server(responses: Vec<&'static str>) -> (String, Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
        let address = listener.local_addr().expect("mock address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("accept request");
                let mut request = Vec::new();
                let mut buffer = [0_u8; 4096];
                loop {
                    let read = stream.read(&mut buffer).expect("read request");
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..read]);
                    let header_end = request
                        .windows(4)
                        .position(|window| window == b"\r\n\r\n")
                        .map(|position| position + 4);
                    if let Some(header_end) = header_end {
                        let headers = String::from_utf8_lossy(&request[..header_end]);
                        let content_length = headers
                            .lines()
                            .find_map(|line| {
                                line.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")?
                                    .parse::<usize>()
                                    .ok()
                            })
                            .unwrap_or(0);
                        if request.len() >= header_end + content_length {
                            break;
                        }
                    }
                }
                let _ = sender.send(String::from_utf8(request).expect("UTF-8 request"));
                stream
                    .write_all(response.as_bytes())
                    .expect("write response");
            }
        });
        (format!("http://{address}"), receiver)
    }

    #[test]
    fn preserves_base_path_and_encodes_repository_segments() {
        let client = GiteaClient::new(&config("https://gitea.example/subpath"))
            .expect("client should build");

        assert_eq!(
            client.endpoint("labels").expect("endpoint").as_str(),
            "https://gitea.example/subpath/api/v1/repos/owner%20name/repo%2Fname/labels"
        );
    }

    #[test]
    fn rejects_remote_plain_http_but_allows_loopback() {
        assert!(GiteaClient::new(&config("http://gitea.example")).is_err());
        assert!(GiteaClient::new(&config("http://127.0.0.1:3000")).is_ok());
    }

    #[test]
    fn resolves_exact_project_name_and_rejects_ambiguity() {
        let projects = vec![
            Project {
                id: 1,
                title: "Kanban".to_owned(),
                is_closed: false,
            },
            Project {
                id: 2,
                title: "kanban".to_owned(),
                is_closed: false,
            },
        ];
        assert_eq!(
            resolve_project(&projects, Some("Kanban"), None)
                .expect("match")
                .id,
            1
        );
        assert!(resolve_project(&projects, Some("Missing"), None).is_err());
        assert_eq!(
            resolve_project(&projects, None, Some(2)).expect("id").title,
            "kanban"
        );
    }

    #[test]
    fn lists_projects_with_pagination_and_reports_unsupported_api() {
        let (base_url, requests) = mock_server(vec![
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n[{\"id\":4,\"title\":\"Kanban\",\"is_closed\":false}]",
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n[]",
        ]);
        let client = GiteaClient::new(&config(&base_url)).expect("client");
        let projects = client.list_projects().expect("projects");
        assert_eq!(projects[0].title, "Kanban");
        let first = requests.recv().expect("first request");
        let second = requests.recv().expect("second request");
        assert!(first.starts_with("GET /api/v1/repos/owner%20name/repo%2Fname/projects?"));
        assert!(first.contains("state=all"));
        assert!(first.contains("page=1"));
        assert!(second.contains("page=2"));
        assert!(first.contains("authorization: token secret"));

        let (base_url, _) = mock_server(vec![
            "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"message\":\"projects unavailable\"}",
        ]);
        let client = GiteaClient::new(&config(&base_url)).expect("client");
        let error = client
            .list_project_columns(4)
            .expect_err("unsupported API must fail");
        assert!(error.to_string().contains("404 Not Found"));
        assert!(error.to_string().contains("projects unavailable"));
        assert!(!error.to_string().contains("secret"));
    }

    #[test]
    fn sends_global_issue_move_payload() {
        let (base_url, requests) = mock_server(vec![
            "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        ]);
        let client = GiteaClient::new(&config(&base_url)).expect("client");
        client
            .move_project_issue(
                4,
                99,
                &MoveProjectIssuePayload {
                    column_id: 12,
                    sorting: Some(3),
                },
            )
            .expect("move");
        let request = requests.recv().expect("request");
        assert!(request.starts_with(
            "POST /api/v1/repos/owner%20name/repo%2Fname/projects/4/issues/99/move HTTP/1.1"
        ));
        assert!(request.ends_with("{\"column_id\":12,\"sorting\":3}"));
    }

    #[test]
    fn paginates_native_column_issues() {
        let (base_url, requests) = mock_server(vec![
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n[{\"id\":99,\"number\":7,\"title\":\"Fix\"}]",
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n[]",
        ]);
        let client = GiteaClient::new(&config(&base_url)).expect("client");
        let issues = client
            .list_project_column_issues(4, 12)
            .expect("column issues");
        assert_eq!(issues[0].id, 99);
        assert!(requests.recv().expect("page one").contains("page=1"));
        assert!(requests.recv().expect("page two").contains("page=2"));
    }
}

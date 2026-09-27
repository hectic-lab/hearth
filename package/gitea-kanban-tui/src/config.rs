use std::env;
use std::fmt;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use clap::{Parser, ValueEnum};

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Backend {
    Projects,
    Labels,
}

#[derive(Parser)]
#[command(
    name = "gitea-kanban-tui",
    version,
    about = "Browse and move Gitea issues using native projects or labels"
)]
pub struct Args {
    /// Gitea base URL; falls back to GITEA_URL
    #[arg(long)]
    pub url: Option<String>,

    /// File containing API token; falls back to GITEA_TOKEN_FILE
    #[arg(long, value_name = "PATH")]
    pub token_file: Option<PathBuf>,

    /// Board backend: projects or labels
    #[arg(long, value_enum)]
    pub backend: Option<Backend>,

    /// Exact native project name; used with --backend projects
    #[arg(long)]
    pub project: Option<String>,

    /// Native project ID; used with --backend projects
    #[arg(long)]
    pub project_id: Option<u64>,

    /// Label prefix used for columns
    #[arg(long)]
    pub label_prefix: Option<String>,

    /// Repository owner; falls back to GITEA_OWNER
    pub owner: Option<String>,

    /// Repository name; falls back to GITEA_REPO
    pub repo: Option<String>,
}

#[derive(Debug)]
pub struct Config {
    pub base_url: String,
    pub token: String,
    pub owner: String,
    pub repo: String,
    pub backend: Backend,
    pub project: Option<String>,
    pub project_id: Option<u64>,
    pub label_prefix: String,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ConfigError(String);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    pub fn load() -> Result<Self, ConfigError> {
        Self::from_args_with(Args::parse(), |name| env::var(name).ok())
    }

    pub fn from_args_with<F>(args: Args, env_var: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let base_url = required(
            args.url.or_else(|| env_var("GITEA_URL")),
            "Gitea URL",
            "--url or GITEA_URL",
        )?;
        let owner = required(
            args.owner.or_else(|| env_var("GITEA_OWNER")),
            "repository owner",
            "OWNER argument or GITEA_OWNER",
        )?;
        let repo = required(
            args.repo.or_else(|| env_var("GITEA_REPO")),
            "repository name",
            "REPO argument or GITEA_REPO",
        )?;
        let backend = if let Some(backend) = args.backend {
            backend
        } else if let Some(value) = env_var("GITEA_KANBAN_BACKEND") {
            match value.as_str() {
                "projects" => Backend::Projects,
                "labels" => Backend::Labels,
                _ => {
                    return Err(ConfigError(
                        "GITEA_KANBAN_BACKEND must be 'projects' or 'labels'".to_owned(),
                    ));
                }
            }
        } else {
            return Err(ConfigError(
                "missing board backend; use --backend projects or --backend labels".to_owned(),
            ));
        };
        let project = args
            .project
            .or_else(|| env_var("GITEA_PROJECT"))
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        let project_id = args
            .project_id
            .or_else(|| env_var("GITEA_PROJECT_ID").and_then(|value| value.parse::<u64>().ok()));
        if backend == Backend::Projects && project.is_some() == project_id.is_some() {
            return Err(ConfigError(
                "projects backend requires exactly one of --project/GITEA_PROJECT or --project-id/GITEA_PROJECT_ID"
                    .to_owned(),
            ));
        }
        let label_prefix = args
            .label_prefix
            .or_else(|| env_var("GITEA_LABEL_PREFIX"))
            .unwrap_or_else(|| "kanban/".to_owned());

        if label_prefix.trim().is_empty() {
            return Err(ConfigError(
                "label prefix cannot be empty; set --label-prefix or GITEA_LABEL_PREFIX".to_owned(),
            ));
        }

        let token = if let Some(path) = args.token_file {
            read_token_file(path)?
        } else if let Some(path) = env_var("GITEA_TOKEN_FILE") {
            read_token_file(PathBuf::from(path))?
        } else if let Some(token) = env_var("GITEA_TOKEN") {
            clean_token(token, "GITEA_TOKEN")?
        } else {
            return Err(ConfigError(
                "missing Gitea token; use --token-file, GITEA_TOKEN, or GITEA_TOKEN_FILE"
                    .to_owned(),
            ));
        };

        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_owned(),
            token,
            owner,
            repo,
            backend,
            project,
            project_id,
            label_prefix,
        })
    }
}

fn required(value: Option<String>, name: &str, source: &str) -> Result<String, ConfigError> {
    match value.map(|value| value.trim().to_owned()) {
        Some(value) if !value.is_empty() => Ok(value),
        _ => Err(ConfigError(format!("missing {name}; use {source}"))),
    }
}

fn clean_token(token: String, source: &str) -> Result<String, ConfigError> {
    let token = token.trim().to_owned();
    if token.is_empty() {
        Err(ConfigError(format!("{source} contains an empty token")))
    } else {
        Ok(token)
    }
}

fn read_token_file(path: PathBuf) -> Result<String, ConfigError> {
    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        ConfigError(format!(
            "cannot inspect token file {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() {
        return Err(ConfigError(format!(
            "token path {} is not a regular file",
            path.display()
        )));
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(ConfigError(format!(
            "token file {} must not be group- or world-readable",
            path.display()
        )));
    }
    let token = fs::read_to_string(&path).map_err(|error| {
        ConfigError(format!(
            "cannot read token file {}: {error}",
            path.display()
        ))
    })?;
    clean_token(token, &format!("token file {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_env(_: &str) -> Option<String> {
        None
    }

    fn token_env(name: &str) -> Option<String> {
        (name == "GITEA_TOKEN").then(|| "secret".to_owned())
    }

    #[test]
    fn parses_explicit_configuration() {
        let args = Args::try_parse_from([
            "gitea-kanban-tui",
            "--url",
            "https://gitea.example/",
            "--backend",
            "labels",
            "owner",
            "repo",
        ])
        .expect("arguments parse");

        let config = Config::from_args_with(args, token_env).expect("config is valid");
        assert_eq!(config.base_url, "https://gitea.example");
        assert_eq!(config.owner, "owner");
        assert_eq!(config.repo, "repo");
        assert_eq!(config.label_prefix, "kanban/");
        assert_eq!(config.backend, Backend::Labels);
        assert_eq!(config.token, "secret");
    }

    #[test]
    fn parses_native_project_by_name() {
        let args = Args::try_parse_from([
            "gitea-kanban-tui",
            "--url",
            "https://gitea.example",
            "--backend",
            "projects",
            "--project",
            "Kanban",
            "owner",
            "repo",
        ])
        .expect("arguments parse");

        let config = Config::from_args_with(args, token_env).expect("config is valid");
        assert_eq!(config.backend, Backend::Projects);
        assert_eq!(config.project.as_deref(), Some("Kanban"));
        assert_eq!(config.project_id, None);
    }

    #[test]
    fn requires_explicit_backend() {
        let args = Args::try_parse_from([
            "gitea-kanban-tui",
            "--url",
            "https://gitea.example",
            "owner",
            "repo",
        ])
        .expect("arguments parse");

        let error = Config::from_args_with(args, token_env).expect_err("backend is required");
        assert!(error.to_string().contains("--backend projects"));
    }

    #[test]
    fn native_project_selector_is_unambiguous() {
        let args = Args::try_parse_from([
            "gitea-kanban-tui",
            "--url",
            "https://gitea.example",
            "--backend",
            "projects",
            "owner",
            "repo",
        ])
        .expect("arguments parse");

        let error = Config::from_args_with(args, token_env).expect_err("selector is required");
        assert!(error.to_string().contains("exactly one"));
    }

    #[test]
    fn falls_back_to_environment() {
        let args = Args::try_parse_from(["gitea-kanban-tui"]).expect("arguments parse");
        let config = Config::from_args_with(args, |name| {
            match name {
                "GITEA_URL" => Some("https://gitea.example"),
                "GITEA_TOKEN" => Some("secret"),
                "GITEA_KANBAN_BACKEND" => Some("labels"),
                "GITEA_OWNER" => Some("owner"),
                "GITEA_REPO" => Some("repo"),
                "GITEA_LABEL_PREFIX" => Some("board/"),
                _ => None,
            }
            .map(str::to_owned)
        })
        .expect("config is valid");

        assert_eq!(config.label_prefix, "board/");
        assert_eq!(config.owner, "owner");
    }

    #[test]
    fn reports_missing_token_without_exposing_values() {
        let args = Args::try_parse_from([
            "gitea-kanban-tui",
            "--url",
            "https://gitea.example",
            "--backend",
            "labels",
            "owner",
            "repo",
        ])
        .expect("arguments parse");
        let error = match Config::from_args_with(args, empty_env) {
            Ok(_) => panic!("token should be required"),
            Err(error) => error,
        };

        assert!(error.to_string().contains("GITEA_TOKEN_FILE"));
    }
}

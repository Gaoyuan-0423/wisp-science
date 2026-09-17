//! Versioned, read-only project-browser protocol for native clients.

use serde::{Deserialize, Serialize};

use crate::ProjectSummary;

pub const SCHEMA: &str = "wisp.project-browser.v1";

#[derive(Serialize, Deserialize)]
pub struct Request {
    pub schema: String,
    pub id: String,
    #[serde(flatten)]
    pub command: Command,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    ListProjects,
    Capabilities,
}

#[derive(Serialize, Deserialize)]
pub struct Response {
    pub schema: String,
    pub id: Option<String>,
    #[serde(flatten)]
    pub reply: Reply,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reply {
    Projects {
        projects: Vec<ProjectSummary>,
        activity_source: ActivitySource,
    },
    Capabilities {
        commands: Vec<String>,
        read_only: bool,
    },
    Error {
        code: ErrorCode,
        message: String,
    },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivitySource {
    /// No live runtime snapshot: counts reflect saved replies only.
    PersistedOnly,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidRequest,
    UnsupportedSchema,
    QueryFailed,
}

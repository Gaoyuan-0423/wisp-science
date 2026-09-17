//! Versioned project-browser query and explicit command protocol for native clients.

use serde::{Deserialize, Serialize};

use crate::{ProjectSummary, RecentSession};

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
    SetProjectStarred {
        project_id: String,
        starred: bool,
    },
    ListSessions {
        project_id: Option<String>,
    },
    GetTranscript {
        project_id: String,
        session_id: String,
        before_seq: Option<i64>,
    },
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
    Transcript {
        messages: Vec<BrowserMessage>,
        next_before_seq: Option<i64>,
    },
    Sessions {
        sessions: Vec<RecentSession>,
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
    WriteDisabled,
    CommandFailed,
}

/// Saved transcript text for native navigation; tool execution remains in the host.
#[derive(Serialize, Deserialize)]
pub struct BrowserMessage {
    pub seq: i64,
    pub role: String,
    pub text: String,
    pub tool_name: Option<String>,
}

//! A reviewed research milestone, independently readable from its notebook.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchiveScript {
    pub filename: String,
    pub content: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchiveFile {
    pub path: String,
    pub checksum: String,
    pub size_bytes: u64,
    /// snapshot, reference, or delete. Only proven exclusive creations may be deleted.
    pub action: String,
    pub can_delete: bool,
    pub reason: String,
    pub snapshot_path: Option<String>,
    #[serde(default)]
    pub cleanup_status: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResearchArchive {
    pub id: String,
    pub project_id: String,
    pub frame_id: String,
    pub source_hash: String,
    pub title: String,
    /// User-reviewed Markdown: question, findings, limitations and decisions.
    pub report: String,
    pub scripts: Vec<ArchiveScript>,
    pub files: Vec<ArchiveFile>,
    pub created_at: i64,
    pub frozen_at: Option<i64>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveFileChoice {
    pub path: String,
    pub action: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfirmResearchArchive {
    pub id: String,
    pub title: String,
    pub report: String,
    pub scripts: Vec<ArchiveScript>,
    pub files: Vec<ArchiveFileChoice>,
}

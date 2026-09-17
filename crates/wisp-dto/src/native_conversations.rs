//! Native conversation protocol, independent of either platform's UI toolkit.
use serde::{Deserialize, Serialize};

pub const SCHEMA: &str = "wisp.native-conversations.v1";
pub const COMMANDS: &[&str] = &[
    "native_conversation_inbox",
    "native_conversation_seen",
    "native_conversation_trajectory",
    "native_conversation_trajectory_html",
    "native_conversation_outline",
    "native_conversation_create",
    "native_conversation_snapshot",
    "native_conversation_send",
    "native_conversation_stop",
    "native_conversation_approve",
    "native_conversation_model",
];

/// Full persisted question index. The next question's sequence is an exclusive
/// history cursor, allowing clients to locate a turn without matching its text.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct OutlineEntry {
    pub user_index: usize,
    pub text: String,
    pub before_seq: Option<i64>,
    pub sent_at: Option<i64>,
    pub response_at: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionRequest {
    pub session_id: String,
    #[serde(default)]
    pub before_seq: Option<i64>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SendRequest {
    pub session_id: String,
    pub request_id: String,
    pub message: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalRequest {
    pub session_id: String,
    pub approval_id: String,
    pub approved: bool,
    #[serde(default)]
    pub feedback: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ModelRequest {
    pub session_id: String,
    pub model_id: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Item {
    pub role: String,
    pub text: String,
    pub tool_name: Option<String>,
    pub input: Option<String>,
    pub ok: Option<bool>,
    pub status: Option<String>,
}
/// A replacement event, never a delta. Sequence orders responses within one
/// host epoch. Reconnects fetch another snapshot; mutations are never replayed.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Snapshot {
    pub schema: String,
    pub epoch: String,
    pub sequence: u64,
    pub project_id: String,
    pub session_id: String,
    pub items: Vec<Item>,
    pub next_before_seq: Option<i64>,
    #[serde(default)]
    pub user_offset: usize,
    pub running: bool,
    pub stopping: bool,
    pub read_only: bool,
    pub model_id: String,
    pub request_id: Option<String>,
    pub error: Option<String>,
    pub approvals: Vec<super::PendingToolApproval>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inbox_fixture_preserves_cross_project_navigation_identity() {
        let rows: Vec<crate::SessionSearchInfo> = serde_json::from_str(include_str!("../../../contracts/native-conversations/v1/inbox.json")).unwrap();
        assert_eq!(rows[0].project_id, "project-a");
        assert_eq!(rows[1].project_id, "project-b");
        assert_eq!(rows[1].id, "session-b");
        assert!(rows.iter().all(|row| row.status == "needs_you"));
    }
    #[test]
    fn trajectory_fixture_uses_existing_shared_contract() {
        let snapshot: crate::TrajectorySnapshotDto = serde_json::from_str(include_str!("../../../contracts/native-conversations/v1/trajectory.json")).unwrap();
        assert_eq!(snapshot.frame_id, "session-a");
        assert_eq!(snapshot.turns[0].cells[0].duration_ms, Some(40));
        assert!(snapshot.turns[0].cells[0].is_error);
        assert_eq!(snapshot.stats.output_tokens, 20);
    }
    #[test]
    fn outline_fixture_retains_indexes_and_exclusive_cursors() {
        let rows: Vec<OutlineEntry> = serde_json::from_str(include_str!("../../../contracts/native-conversations/v1/outline.json")).unwrap();
        assert_eq!(rows[0].text, rows[1].text);
        assert_eq!(rows[0].before_seq, Some(8));
        assert_eq!(rows[1].before_seq, None);
        assert_eq!(rows[1].user_index, 1);
    }
    #[test]
    fn shared_native_conversation_fixtures_roundtrip() {
        let snapshot: Snapshot = serde_json::from_str(include_str!(
            "../../../contracts/native-conversations/v1/snapshot.json"
        ))
        .unwrap();
        assert_eq!(snapshot.schema, SCHEMA);
        assert_eq!(snapshot.items[1].text, "正在检查样本…");
        assert_eq!(snapshot.approvals[0].frame_id, snapshot.session_id);
        let send: SendRequest = serde_json::from_str(include_str!(
            "../../../contracts/native-conversations/v1/send.json"
        ))
        .unwrap();
        assert_eq!(
            snapshot.request_id.as_deref(),
            Some(send.request_id.as_str())
        );
        let approval: ApprovalRequest = serde_json::from_str(include_str!(
            "../../../contracts/native-conversations/v1/approval.json"
        ))
        .unwrap();
        assert!(!approval.approved);
        assert_eq!(approval.approval_id, snapshot.approvals[0].approval_id);
        let encoded = serde_json::to_value(snapshot).unwrap();
        assert_eq!(encoded["items"][0]["tool_name"], serde_json::Value::Null);
    }
    #[test]
    fn mutation_arguments_reject_unscoped_and_unexpected_fields() {
        assert!(
            serde_json::from_str::<SendRequest>(r#"{"message":"hello","request_id":"x"}"#).is_err()
        );
        assert!(serde_json::from_str::<ApprovalRequest>(
            r#"{"session_id":"s","approval_id":"a","approved":true,"scope":"global"}"#
        )
        .is_err());
        assert!(!COMMANDS.contains(&"send_message"));
    }
}

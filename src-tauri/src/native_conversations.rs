//! Native conversation commands reuse the desktop turn and transcript pipeline.
//! Snapshot reads serialize per session, so clients can discard late responses.
use crate::native_settings::{invoke_command, Broker};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, sync::Arc};
use tauri::Manager;
use tokio::sync::Mutex;
use wisp_dto::{native_conversations as dto, native_settings::Request};

pub(crate) struct Conversations {
    epoch: String,
    sessions: Mutex<HashMap<String, Arc<Mutex<Record>>>>,
}
impl Default for Conversations {
    fn default() -> Self {
        Self {
            epoch: uuid::Uuid::new_v4().to_string(),
            sessions: Mutex::new(HashMap::new()),
        }
    }
}
#[derive(Default)]
struct Record {
    sequence: u64,
    running: bool,
    stopping: bool,
    request_id: Option<String>,
    error: Option<String>,
    accepted: HashMap<String, [u8; 32]>,
}
impl Record {
    fn accept(
        &mut self,
        request: &dto::SendRequest,
        external_running: bool,
    ) -> Result<bool, String> {
        uuid::Uuid::parse_str(&request.request_id).map_err(|_| "Invalid send request ID")?;
        if request.message.trim().is_empty() || request.message.len() > 128 * 1024 {
            return Err("Message must contain 1–131072 bytes".into());
        }
        let digest: [u8; 32] = Sha256::digest(request.message.as_bytes()).into();
        if let Some(previous) = self.accepted.get(&request.request_id) {
            return if previous == &digest {
                Ok(false)
            } else {
                Err("Request ID was already used for another message".into())
            };
        }
        if self.running || external_running {
            return Err("This conversation is already running".into());
        }
        if self.accepted.len() >= 1024 {
            return Err(
                "Native request ledger is full; restart the host after current tasks finish".into(),
            );
        }
        self.accepted.insert(request.request_id.clone(), digest);
        self.running = true;
        self.stopping = false;
        self.error = None;
        self.request_id = Some(request.request_id.clone());
        Ok(true)
    }
}
impl Conversations {
    async fn session(&self, id: &str) -> Result<Arc<Mutex<Record>>, String> {
        let mut sessions = self.sessions.lock().await;
        if let Some(record) = sessions.get(id) {
            return Ok(record.clone());
        }
        if sessions.len() >= 512 {
            return Err("Too many native conversation contexts; restart the host".into());
        }
        let record = Arc::new(Mutex::new(Record::default()));
        sessions.insert(id.to_owned(), record.clone());
        Ok(record)
    }
}
fn decode<T: DeserializeOwned>(value: &Value) -> Result<T, String> {
    serde_json::from_value(value.clone()).map_err(|error| error.to_string())
}

pub(crate) async fn require_owner(
    store: &wisp_store::Store,
    project: &str,
    session: &str,
) -> Result<(), String> {
    if session.is_empty()
        || store
            .frame_project_id(session)
            .await
            .map_err(|e| e.to_string())?
            .as_deref()
            != Some(project)
    {
        return Err("Conversation does not belong to the selected project".into());
    }
    Ok(())
}
async fn running(broker: &Broker, session: &str) -> bool {
    broker
        .app
        .state::<crate::AppState>()
        .running_turns
        .lock()
        .await
        .contains(session)
}
async fn call(broker: &Broker, project: &str, command: &str, args: Value) -> Result<Value, String> {
    invoke_command(broker, Some(project.to_owned()), command, args).await
}

pub(crate) async fn dispatch(broker: &Broker, request: &Request) -> Result<Value, String> {
    let project = request
        .project_id
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or("A project is required")?;
    if request.command == "native_conversation_inbox" {
        if !request.args.as_object().is_some_and(|v| v.is_empty()) {
            return Err("Inbox takes no arguments".into());
        }
        let rows = call(
            broker,
            project,
            "search_sessions",
            json!({"query":"", "limit":50}),
        )
        .await?;
        let rows = rows
            .as_array()
            .ok_or("Invalid inbox response")?
            .iter()
            .filter(|row| row.get("status").and_then(Value::as_str) == Some("needs_you"))
            .cloned()
            .collect::<Vec<_>>();
        return Ok(Value::Array(rows));
    }
    if request.command == "native_conversation_create" {
        if !request.args.as_object().is_some_and(|v| v.is_empty()) {
            return Err("Create takes no arguments".into());
        }
        return call(broker, project, "new_session", json!({})).await;
    }
    let session = request
        .args
        .get("session_id")
        .and_then(Value::as_str)
        .ok_or("A conversation is required")?;
    require_owner(
        &broker.app.state::<crate::AppState>().store,
        project,
        session,
    )
    .await?;
    let record = broker.conversations.session(session).await?;
    match request.command.as_str() {
        "native_conversation_archive_get" | "native_conversation_archive_prepare"
        | "native_conversation_archive_retry" | "native_conversation_archive_continue" => {
            let _: dto::SessionRequest = decode(&request.args)?;
            let command = match request.command.as_str() {
                "native_conversation_archive_get" => "get_research_archive",
                "native_conversation_archive_prepare" => "prepare_research_archive",
                "native_conversation_archive_retry" => "retry_research_archive_cleanup",
                _ => "continue_research_archive",
            };
            call(broker, project, command, json!({"frameId": session})).await
        }
        "native_conversation_archive_confirm" => {
            let args: dto::ArchiveConfirmRequest = decode(&request.args)?;
            call(broker, project, "confirm_research_archive", json!({"frameId": session, "input": args.input})).await
        }

        "native_conversation_seen" => {
            let _: dto::SessionRequest = decode(&request.args)?;
            broker
                .app
                .state::<crate::AppState>()
                .store
                .mark_frame_seen(session)
                .await
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "native_conversation_trajectory" | "native_conversation_trajectory_html" => {
            let _: dto::SessionRequest = decode(&request.args)?;
            let state = broker.app.state::<crate::AppState>();
            crate::session_commands::native_transcript(&state, session, None).await?;
            let snapshot =
                crate::session_commands::folded_session_trajectory(&state.store, session).await?;
            if request.command == "native_conversation_trajectory_html" {
                let exported_at = chrono::Utc::now().to_rfc3339();
                return Ok(Value::String(
                    crate::trajectory_export::render_trajectory_html(&snapshot, "zh", &exported_at),
                ));
            }
            let value = serde_json::to_value(snapshot).map_err(|e| e.to_string())?;
            let snapshot: wisp_dto::TrajectorySnapshotDto =
                serde_json::from_value(value).map_err(|e| e.to_string())?;
            serde_json::to_value(snapshot).map_err(|e| e.to_string())
        }
        "native_conversation_outline" => {
            let _: dto::SessionRequest = decode(&request.args)?;
            let state = broker.app.state::<crate::AppState>();
            // Flush pending persisted events before indexing, using the same
            // barrier as a transcript refresh.
            crate::session_commands::native_transcript(&state, session, None).await?;
            let rows = state
                .store
                .load_session_user_messages(session)
                .await
                .map_err(|e| e.to_string())?;
            let entries: Vec<dto::OutlineEntry> = rows
                .iter()
                .enumerate()
                .map(
                    |(index, (_, text, sent_at, response_at))| dto::OutlineEntry {
                        user_index: index,
                        text: text.clone(),
                        before_seq: rows.get(index + 1).map(|row| row.0),
                        sent_at: Some(*sent_at),
                        response_at: *response_at,
                    },
                )
                .collect();
            serde_json::to_value(entries).map_err(|e| e.to_string())
        }
        "native_conversation_snapshot" => {
            let args: dto::SessionRequest = decode(&request.args)?;
            let mut record = record.lock().await;
            let state = broker.app.state::<crate::AppState>();
            let (items, next_before_seq, frozen, user_offset) =
                crate::session_commands::native_transcript(&state, session, args.before_seq)
                    .await?;
            let model = call(
                broker,
                project,
                "get_session_model",
                json!({"sessionId":session}),
            )
            .await?;
            record.sequence += 1;
            let read_only = frozen || model.as_str().is_some_and(|id| id.starts_with("acp:"));
            let snapshot = dto::Snapshot {
                schema: dto::SCHEMA.into(),
                epoch: broker.conversations.epoch.clone(),
                sequence: record.sequence,
                project_id: project.into(),
                session_id: session.into(),
                items: items
                    .into_iter()
                    .map(|item| dto::Item {
                        role: item.role,
                        text: item.text,
                        tool_name: item.tool_name,
                        input: item.input,
                        ok: item.ok,
                        status: item.status,
                    })
                    .collect(),
                next_before_seq,
                user_offset,
                running: record.running || running(broker, session).await,
                stopping: record.stopping,
                read_only,
                model_id: model.as_str().unwrap_or_default().into(),
                request_id: record.request_id.clone(),
                error: record.error.clone(),
                approvals: state
                    .confirms
                    .lock()
                    .unwrap()
                    .get(session)
                    .map(|pending| wisp_dto::PendingToolApproval {
                        approval_id: pending.request.approval_id.clone(),
                        frame_id: session.into(),
                        message: pending.request.message.clone(),
                        tool: pending.request.tool.clone(),
                        preview: pending.request.preview.clone(),
                    })
                    .into_iter()
                    .collect(),
            };
            serde_json::to_value(snapshot).map_err(|e| e.to_string())
        }
        "native_conversation_send" => {
            let args: dto::SendRequest = decode(&request.args)?;
            // ACP authorization/questions need a separate native protocol. Keep
            // saved ACP transcripts readable, but never start an invisible flow.
            if broker
                .app
                .state::<crate::AppState>()
                .store
                .get_acp_session(session)
                .await
                .map_err(|e| e.to_string())?
                .is_some()
            {
                return Err("ACP conversations are read-only in the native preview".into());
            }
            let mut guard = record.lock().await;
            if guard.accept(&args, running(broker, session).await)? {
                let broker = broker.clone();
                let project = project.to_owned();
                let record = record.clone();
                let session = session.to_owned();
                let message = args.message.clone();
                tauri::async_runtime::spawn(async move {
                    let mut turn = Box::pin(call(
                        &broker,
                        &project,
                        "send_message",
                        json!({"sessionId":session,"message":message}),
                    ));
                    // The Stop request can precede creation of SessionRuntime.
                    // Keep cancelling until the turn settles, without dropping
                    // its persistence/cleanup future or affecting other sessions.
                    let result = loop {
                        tokio::select! {
                            result = &mut turn => break result,
                            _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                                if record.lock().await.stopping {
                                    let _ = call(&broker, &project, "stop_agent", json!({"sessionId":session})).await;
                                }
                            }
                        }
                    };
                    let mut record = record.lock().await;
                    record.running = false;
                    record.stopping = false;
                    record.error = result.err();
                });
            }
            Ok(
                json!({"request_id":args.request_id,"session_id":session,"epoch":broker.conversations.epoch}),
            )
        }
        "native_conversation_stop" => {
            let _: dto::SessionRequest = decode(&request.args)?;
            record.lock().await.stopping = true;
            let result = call(broker, project, "stop_agent", json!({"sessionId":session})).await;
            let mut record = record.lock().await;
            if !record.running {
                record.stopping = false;
            }
            result
        }
        "native_conversation_approve" => {
            let args: dto::ApprovalRequest = decode(&request.args)?;
            crate::approval_commands::respond_native_confirmation(
                &broker.app.state::<crate::AppState>(),
                project,
                &args,
            )
            .await?;
            Ok(Value::Null)
        }
        "native_conversation_model" => {
            let args: dto::ModelRequest = decode(&request.args)?;
            let record = record.lock().await;
            if record.running || running(broker, session).await {
                return Err("Wait for the current turn before changing its model".into());
            }
            let profiles = call(broker, project, "list_models", json!({})).await?;
            if !profiles.as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|row| row["id"].as_str() == Some(&args.model_id))
            }) {
                return Err("Model does not exist".into());
            }
            call(
                broker,
                project,
                "set_active_model",
                json!({"sessionId":session,"id":args.model_id}),
            )
            .await
        }
        _ => Err("Unsupported native conversation command".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sending_is_idempotent_and_rejects_ambiguous_id_reuse_and_busy_sessions() {
        let mut record = Record::default();
        let mut request = dto::SendRequest {
            session_id: "a".into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            message: "hello".into(),
        };
        assert!(record.accept(&request, false).unwrap());
        assert!(!record.accept(&request, false).unwrap());
        request.message = "different".into();
        assert!(record.accept(&request, false).is_err());
        request.request_id = uuid::Uuid::new_v4().to_string();
        assert!(record.accept(&request, false).is_err());
        record.running = false;
        assert!(record.accept(&request, true).is_err());
        assert!(record.accept(&request, false).unwrap());
    }
    #[tokio::test]
    async fn session_ownership_is_required_even_for_read_and_stop() {
        let directory = std::env::temp_dir().join(format!("wisp_native_{}", uuid::Uuid::new_v4()));
        let store = wisp_store::Store::open(&directory.join("test.sqlite"))
            .await
            .unwrap();
        store
            .create_project("a", "A", &directory.to_string_lossy())
            .await
            .unwrap();
        store
            .create_frame("s", "a", "OPERON", "model")
            .await
            .unwrap();
        assert!(require_owner(&store, "a", "s").await.is_ok());
        assert!(require_owner(&store, "b", "s").await.is_err());
        assert!(require_owner(&store, "a", "").await.is_err());
        assert!(require_owner(&store, "a", "missing").await.is_err());
        drop(store);
        let _ = std::fs::remove_dir_all(directory);
    }
}

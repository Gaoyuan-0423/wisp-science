//! Project/scope-checked native access to the existing terminal manager.
use crate::native_settings::Broker;
use base64::Engine;
use serde_json::Value;
use tauri::Manager;
use wisp_dto::{native_conversations::TerminalRequest, native_settings::Request};

pub(crate) async fn dispatch(
    broker: &Broker,
    request: &Request,
    project_id: &str,
    session: &str,
) -> Result<Value, String> {
    let args: TerminalRequest =
        serde_json::from_value(request.args.clone()).map_err(|e| e.to_string())?;
    let state = broker.app.state::<crate::AppState>();
    let (project, scope) =
        crate::exploration_commands::working_project_for_frame(&state, session).await?;
    if project.id != project_id {
        return Err("Project scope mismatch".into());
    }
    let manager = broker
        .app
        .state::<crate::terminal_sessions::TerminalManager>();
    let key = scope.scope_key();
    if request.command == "native_conversation_terminal_list" {
        return serde_json::to_value(manager.native_list(project_id, key))
            .map_err(|e| e.to_string());
    }
    if matches!(
        request.command.as_str(),
        "native_conversation_terminal_open"
            | "native_conversation_terminal_write"
            | "native_conversation_terminal_resize"
    ) {
        crate::exploration_commands::require_writable_scope(&state.store, &scope).await?;
        state
            .store
            .require_unarchived_session(session)
            .await
            .map_err(|e| e.to_string())?;
    }
    if request.command == "native_conversation_terminal_open" {
        let context_id = args.context_id.ok_or("Execution context is required")?;
        let context = state
            .store
            .get_execution_context(&context_id)
            .await
            .map_err(|e| e.to_string())?
            .ok_or("Execution context not found")?;
        let _activity = state.begin_project_activity(project_id)?;
        state
            .store
            .bump_state_generation(&scope)
            .await
            .map_err(|e| e.to_string())?;
        let summary = manager.open(project_id, key, &project.root, &context)?;
        return serde_json::to_value(crate::terminal_sessions::native_terminal_info(summary))
            .map_err(|e| e.to_string());
    }
    let id = args.terminal_id.ok_or("Terminal ID is required")?;
    match request.command.as_str() {
        "native_conversation_terminal_read" => {
            serde_json::to_value(manager.native_read(&id, project_id, key, args.cursor)?)
                .map_err(|e| e.to_string())
        }
        "native_conversation_terminal_write" => {
            let encoded = args.base64.ok_or("Terminal input is required")?;
            if encoded.len() > 128 * 1024 {
                return Err("Terminal input is too large".into());
            }
            let data = base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .map_err(|e| e.to_string())?;
            manager.native_write(&id, project_id, key, &data)?;
            Ok(Value::Null)
        }
        "native_conversation_terminal_resize" => {
            manager.native_resize(
                &id,
                project_id,
                key,
                args.rows.ok_or("Rows required")?,
                args.cols.ok_or("Columns required")?,
            )?;
            Ok(Value::Null)
        }
        "native_conversation_terminal_close" => {
            manager.native_close(&id, project_id, key)?;
            Ok(Value::Null)
        }
        _ => Err("Unknown native terminal command".into()),
    }
}

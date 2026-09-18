//! Native side-panel reads resolve the requested frame directly, never a shared
//! hidden window's active frame. Exploration directories remain isolated.
use crate::native_settings::{invoke_command, Broker};
use serde_json::Value;
use tauri::Manager;
use wisp_dto::{native_conversations::PanelRequest, native_settings::Request};

pub(crate) async fn dispatch(
    broker: &Broker,
    request: &Request,
    project_id: &str,
    session: &str,
) -> Result<Value, String> {
    let args: PanelRequest =
        serde_json::from_value(request.args.clone()).map_err(|e| e.to_string())?;
    let state = broker.app.state::<crate::AppState>();
    let (project, scope) =
        crate::exploration_commands::working_project_for_frame(&state, session).await?;
    if project.id != project_id {
        return Err("Project scope mismatch".into());
    }
    match request.command.as_str() {
        "native_conversation_panel_contexts" => {
            let contexts = state
                .store
                .list_execution_contexts()
                .await
                .map_err(|e| e.to_string())?;
            let enabled_ids = state
                .store
                .list_session_execution_context_ids(session)
                .await
                .map_err(|e| e.to_string())?;
            let read_only =
                crate::exploration_commands::require_writable_scope(&state.store, &scope)
                    .await
                    .is_err()
                    || state
                        .store
                        .require_unarchived_session(session)
                        .await
                        .is_err();
            // Validate the existing store shape against the shared UI contract.
            let contexts =
                serde_json::from_value(serde_json::to_value(contexts).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            serde_json::to_value(wisp_dto::native_conversations::PanelContexts {
                contexts,
                enabled_ids,
                read_only,
            })
            .map_err(|e| e.to_string())
        }
        "native_conversation_panel_context_enabled" => {
            let context_id = args.context_id.ok_or("Execution context is required")?;
            let enabled = args.enabled.ok_or("Enabled state is required")?;
            let context = state
                .store
                .get_execution_context(&context_id)
                .await
                .map_err(|e| e.to_string())?
                .ok_or("Execution context not found")?;
            if context.kind == wisp_store::ExecutionContextKind::Local {
                return Err("The local context is always available".into());
            }
            state
                .store
                .require_unarchived_session(session)
                .await
                .map_err(|e| e.to_string())?;
            let ids = crate::ssh_hosts::set_session_execution_context_enabled(
                state,
                session.into(),
                context_id,
                enabled,
            )
            .await?;
            serde_json::to_value(ids).map_err(|e| e.to_string())
        }
        "native_conversation_panel_artifacts" => {
            invoke_command(
                broker,
                Some(project_id.into()),
                "list_artifacts",
                serde_json::json!({"sessionId": session}),
            )
            .await
        }
        "native_conversation_panel_files" => {
            let path = args.path.unwrap_or_else(|| ".".into());
            let directory = wisp_tools::safety::resolve_under_root(&project.root, &path)?;
            tokio::task::spawn_blocking(move || {
                let entries = crate::file_browser::list_dir_entries(&directory)?;
                serde_json::to_value(entries).map_err(|e| e.to_string())
            })
            .await
            .map_err(|e| e.to_string())?
        }
        "native_conversation_panel_readfile" => {
            let path = args.path.ok_or("File path is required")?;
            read(project.root, path).await
        }
        "native_conversation_panel_readartifact" => {
            let id = args.artifact_id.ok_or("Artifact ID is required")?;
            if !state
                .store
                .artifact_visible_in_scope(&id, &scope)
                .await
                .map_err(|e| e.to_string())?
            {
                return Err("Artifact is not visible in this conversation scope".into());
            }
            let path = state
                .store
                .artifact_path_in_scope(&id, &scope)
                .await
                .map_err(|e| e.to_string())?
                .ok_or("Artifact not found")?;
            read(project.root, path).await
        }
        _ => Err("Unknown native panel command".into()),
    }
}
async fn read(root: std::path::PathBuf, path: String) -> Result<Value, String> {
    tokio::task::spawn_blocking(move || {
        let content = crate::file_browser::read_file_at(&root, path, None)?;
        serde_json::to_value(content).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn preview_reuses_workspace_boundary_and_file_contract() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("project");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("report.txt"), "result").unwrap();
        std::fs::write(temp.path().join("outside.txt"), "outside").unwrap();
        let value = read(root.clone(), "report.txt".into()).await.unwrap();
        let content: wisp_dto::FileContent = serde_json::from_value(value).unwrap();
        assert_eq!(content.text.as_deref(), Some("result"));
        assert!(!content.truncated);
        assert!(read(root, "../outside.txt".into()).await.is_err());
    }
}

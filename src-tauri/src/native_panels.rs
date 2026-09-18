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
        "native_conversation_panel_activity" => {
            let runtimes = state
                .runtime_manager
                .list()
                .into_iter()
                .filter(|runtime| {
                    crate::runtime_commands::runtime_visible(&runtime.key, &scope, session)
                })
                .collect::<Vec<_>>();
            let runs = state
                .store
                .list_run_summaries_in_scope(&scope)
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
            contract::<wisp_dto::native_conversations::PanelActivity>(
                serde_json::json!({"runtimes": runtimes, "runs": runs, "read_only": read_only}),
            )
        }
        "native_conversation_panel_runtime_inspect" => {
            let id = args.runtime_id.ok_or("Runtime ID is required")?;
            let runtime = state
                .runtime_manager
                .list()
                .into_iter()
                .find(|runtime| {
                    runtime.runtime_id == id
                        && crate::runtime_commands::runtime_visible(&runtime.key, &scope, session)
                })
                .ok_or("Runtime is not visible in this conversation scope")?;
            let objects = state
                .runtime_manager
                .inspect(&runtime.key)
                .await
                .map_err(|e| e.to_string())?;
            contract::<wisp_dto::RuntimeObjectList>(
                serde_json::to_value(objects).map_err(|e| e.to_string())?,
            )
        }
        "native_conversation_panel_run_detail"
        | "native_conversation_panel_run_cancel"
        | "native_conversation_panel_run_harvest" => {
            let id = args.run_id.ok_or("Run ID is required")?;
            let mutation = request.command != "native_conversation_panel_run_detail";
            require_run_scope(&state.store, &scope, &id, mutation).await?;
            if request.command != "native_conversation_panel_run_detail" {
                crate::exploration_commands::require_writable_scope(&state.store, &scope).await?;
                state
                    .store
                    .require_unarchived_session(session)
                    .await
                    .map_err(|e| e.to_string())?;
                let _activity = state.begin_project_activity(project_id)?;
                if request.command == "native_conversation_panel_run_cancel" {
                    state.run_manager.cancel(&state.store, &id).await?;
                } else {
                    state.run_manager.harvest_run(&state.store, &id).await?;
                }
            }
            let run = state
                .store
                .get_run(&id)
                .await
                .map_err(|e| e.to_string())?
                .ok_or("Run not found")?;
            contract::<wisp_dto::RunRecord>(serde_json::to_value(run).map_err(|e| e.to_string())?)
        }
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
async fn require_run_scope(
    store: &wisp_store::Store,
    scope: &wisp_store::StateScope,
    id: &str,
    mutation: bool,
) -> Result<(), String> {
    if !store
        .run_visible_in_scope(id, scope)
        .await
        .map_err(|e| e.to_string())?
    {
        return Err("Run is not visible in this conversation scope".into());
    }
    if mutation
        && store
            .run_state_scope(id)
            .await
            .map_err(|e| e.to_string())?
            .as_ref()
            != Some(scope)
    {
        return Err("An inherited run cannot be modified from this scope".into());
    }
    Ok(())
}
fn contract<T: serde::de::DeserializeOwned + serde::Serialize>(
    value: Value,
) -> Result<Value, String> {
    let parsed: T = serde_json::from_value(value).map_err(|e| e.to_string())?;
    serde_json::to_value(parsed).map_err(|e| e.to_string())
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
    async fn native_run_reads_and_mutations_reject_foreign_and_missing_runs() {
        let temp = tempfile::tempdir().unwrap();
        let store = wisp_store::Store::open(&temp.path().join("store.sqlite"))
            .await
            .unwrap();
        store.create_project("p", "Project", "").await.unwrap();
        store.create_project("other", "Other", "").await.unwrap();
        store
            .create_run(&wisp_store::RunRecord::new(
                "r", "p", "local", "Run", "command",
            ))
            .await
            .unwrap();
        let own = wisp_store::StateScope::mainline("p");
        let other = wisp_store::StateScope::mainline("other");
        for mutation in [false, true] {
            assert!(require_run_scope(&store, &own, "r", mutation).await.is_ok());
            assert!(require_run_scope(&store, &other, "r", mutation)
                .await
                .is_err());
            assert!(require_run_scope(&store, &own, "missing", mutation)
                .await
                .is_err());
        }
        drop(store);
    }
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

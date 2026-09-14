//! Desktop-only Workflow confirmation service. The application installs it
//! once; headless tests and MCP re-exec processes have no implicit UI authority.
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use tauri::Manager;
use wisp_tools::ConfirmDecision;

static APP: OnceLock<tauri::AppHandle> = OnceLock::new();
pub(crate) fn install(app: tauri::AppHandle) {
    let _ = APP.set(app);
}

/// Shared with normal turns so concurrent child nodes and their parent never
/// replace one another's one-shot confirmation channel on the owning frame.
pub(crate) async fn lock_frame(frame: &str) -> tokio::sync::OwnedMutexGuard<()> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    let lock = {
        let mut locks = LOCKS.get_or_init(Default::default).lock().unwrap();
        locks.retain(|_, lock| lock.strong_count() > 0);
        if let Some(lock) = locks.get(frame).and_then(Weak::upgrade) {
            lock
        } else {
            let lock = Arc::new(tokio::sync::Mutex::new(()));
            locks.insert(frame.into(), Arc::downgrade(&lock));
            lock
        }
    };
    lock.lock_owned().await
}

#[async_trait::async_trait]
pub(crate) trait WorkflowConfirmer: Send + Sync {
    async fn confirm(&self, message: &str) -> ConfirmDecision;
}

pub(crate) async fn confirm_during_workflow(
    confirmer: &dyn WorkflowConfirmer,
    message: &str,
    store: &wisp_store::Store,
    workflow_id: &str,
) -> ConfirmDecision {
    let pending = confirmer.confirm(message);
    tokio::pin!(pending);
    loop {
        tokio::select! {
            decision=&mut pending=>return decision,
            _=tokio::time::sleep(std::time::Duration::from_millis(100))=>{
                if store.agent_workflow_cancel_requested(workflow_id).await.unwrap_or(true) {
                    return ConfirmDecision::Denied {feedback:Some("Workflow cancelled".into())};
                }
            }
        }
    }
}

pub(crate) async fn for_node(
    store: &wisp_store::Store,
    project_id: &str,
    frame_id: &str,
    node: &str,
) -> Option<Arc<dyn WorkflowConfirmer>> {
    let app = APP.get()?.clone();
    let owner = store.root_frame_id(frame_id).await.ok().flatten()?;
    Some(Arc::new(DesktopConfirmer {
        app,
        owner,
        project: project_id.into(),
        node: node.into(),
    }))
}

struct DesktopConfirmer {
    app: tauri::AppHandle,
    owner: String,
    project: String,
    node: String,
}
struct PendingGuard {
    app: tauri::AppHandle,
    owner: String,
    project: String,
    request: crate::ConfirmRequest,
}
impl Drop for PendingGuard {
    fn drop(&mut self) {
        let state = self.app.state::<crate::AppState>();
        let removed = {
            let mut pending = state.confirms.lock().unwrap();
            if pending
                .get(&self.owner)
                .is_some_and(|p| p.request.approval_id == self.request.approval_id)
            {
                pending.remove(&self.owner);
                true
            } else {
                false
            }
        };
        if removed {
            state.awaiting_confirm.lock().unwrap().remove(&self.owner);
            state.device_hub.resolve_needs_user(&self.owner);
        }
        crate::emit_confirm_resolved(&self.app, &self.request, &self.project);
    }
}
#[async_trait::async_trait]
impl WorkflowConfirmer for DesktopConfirmer {
    async fn confirm(&self, message: &str) -> ConfirmDecision {
        let _slot = lock_frame(&self.owner).await;
        let state = self.app.state::<crate::AppState>();
        let (tool, preview) = crate::parse_confirm_payload(message);
        let request = crate::ConfirmRequest::new(
            &self.owner,
            format!(
                "Workflow node {} requests confirmation:\n{message}",
                self.node
            ),
            tool,
            preview,
        );
        let (tx, rx) = tokio::sync::oneshot::channel();
        let guard = PendingGuard {
            app: self.app.clone(),
            owner: self.owner.clone(),
            project: self.project.clone(),
            request: request.clone(),
        };
        // Explicit node decisions do not inherit parent full-permission or
        // permanent grants. Tool/capability checks have already run upstream.
        state.confirms.lock().unwrap().insert(
            self.owner.clone(),
            crate::PendingConfirm {
                tx,
                grant: None,
                project_id: self.project.clone(),
                request: request.clone(),
            },
        );
        state
            .awaiting_confirm
            .lock()
            .unwrap()
            .insert(self.owner.clone());
        state
            .device_hub
            .mark_needs_user(&self.owner, Some(&self.project));
        crate::emit_confirm_request(&self.app, &request, Some(&self.project));
        let decision = crate::receive_confirm_decision(rx).await;
        drop(guard);
        decision
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn same_owner_confirmations_queue_and_different_owners_do_not_block() {
        let id = uuid::Uuid::new_v4().to_string();
        let first = lock_frame(&id).await;
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(10), lock_frame(&id))
                .await
                .is_err()
        );
        let other = lock_frame(&format!("{id}-other")).await;
        drop(first);
        let second = lock_frame(&id).await;
        drop((other, second));
    }
}

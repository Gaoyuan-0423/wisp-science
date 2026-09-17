//! Project-list queries shared by desktop and future native hosts.

use std::collections::HashSet;

use anyhow::Result;
use wisp_dto::ProjectSummary;
use wisp_store::Store;

/// List projects in the store's order (starred first, then latest activity).
///
/// `running` and `awaiting` are snapshots of session IDs, not project IDs.
/// Hosts must release their runtime locks before awaiting this query. The
/// snapshots need not include idle sessions: unseen replies come from the store.
/// Database-list and star-query errors propagate; optional activity and sync
/// enrichment retains the desktop's best-effort fallback behavior.
pub async fn list_projects(
    store: &Store,
    running: &HashSet<String>,
    awaiting: &HashSet<String>,
) -> Result<Vec<ProjectSummary>> {
    let rows = store.list_projects().await?;
    let starred = store.starred_project_ids().await?;
    let mut projects = Vec::with_capacity(rows.len());
    for (
        id,
        name,
        workspace_dir,
        _created_at,
        updated_at,
        session_count,
        description,
        artifact_count,
    ) in rows
    {
        let (running_count, needs_you_count) =
            project_status_counts(store, &id, running, awaiting).await;
        let sync_state = store.get_project_sync_state(&id).await.ok().flatten();
        let sync_configured = sync_state
            .as_ref()
            .is_some_and(|state| state.base_revision.is_some());
        projects.push(ProjectSummary {
            starred: starred.contains(&id),
            id,
            name,
            description,
            workspace_dir,
            session_count,
            artifact_count,
            updated_at,
            running_count,
            needs_you_count,
            sync_configured,
            last_synced_at: sync_state.and_then(|state| state.last_synced_at),
        });
    }
    Ok(projects)
}

/// Count running sessions and sessions needing attention in one project.
///
/// Pending approvals take precedence over running turns. Otherwise, an unseen
/// assistant/internal reply needs attention until viewed. Like the desktop's
/// existing query, unavailable session metadata falls back to zero counts.
pub async fn project_status_counts(
    store: &Store,
    project_id: &str,
    running: &HashSet<String>,
    awaiting: &HashSet<String>,
) -> (i64, i64) {
    let Ok(rows) = store.list_session_last_roles(project_id).await else {
        return (0, 0);
    };
    let mut running_count = 0;
    let mut needs_you_count = 0;
    for (id, role, unseen) in rows {
        if awaiting.contains(&id) {
            needs_you_count += 1;
        } else if running.contains(&id) {
            running_count += 1;
        } else if matches!(role.as_deref(), Some("assistant" | "internal")) && unseen {
            needs_you_count += 1;
        }
    }
    (running_count, needs_you_count)
}

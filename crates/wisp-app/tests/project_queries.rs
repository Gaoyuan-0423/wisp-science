use std::collections::HashSet;

use serde_json::json;
use sqlx::{sqlite::SqliteConnectOptions, SqlitePool};
use tempfile::TempDir;
use wisp_app::projects::{list_projects, project_status_counts};
use wisp_llm::Message;
use wisp_store::{ProjectSyncState, Store};

struct TestDb {
    store: Store,
    sql: SqlitePool,
    _directory: TempDir,
}

impl TestDb {
    async fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("queries.sqlite");
        let store = Store::open(&path).await.unwrap();
        let sql = SqlitePool::connect_with(SqliteConnectOptions::new().filename(&path))
            .await
            .unwrap();
        Self {
            store,
            sql,
            _directory: directory,
        }
    }

    async fn project(&self, id: &str) {
        // Deliberately share a workspace: project IDs must not be coalesced.
        self.store
            .create_project(id, id, &self._directory.path().to_string_lossy())
            .await
            .unwrap();
    }

    async fn session(&self, id: &str, project: &str) {
        self.store
            .create_frame(id, project, "test", "mock")
            .await
            .unwrap();
        self.store
            .append_message(id, 1, &Message::user("Inspect the project"))
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn preserves_project_identity_order_metadata_and_visible_counts() {
    let db = TestDb::new().await;
    let idle = HashSet::new();
    assert!(list_projects(&db.store, &idle, &idle)
        .await
        .unwrap()
        .is_empty());

    for id in ["older", "newer", "same-time", "scratch:hidden"] {
        db.project(id).await;
    }
    db.store
        .update_project("older", "Older project", "Research notes")
        .await
        .unwrap();
    db.store.set_project_starred("older", true).await.unwrap();
    sqlx::query("UPDATE projects SET updated_at = CASE WHEN id='older' THEN 10 ELSE 20 END")
        .execute(&db.sql)
        .await
        .unwrap();
    db.session("used", "older").await;
    for id in ["named-draft", "empty-draft"] {
        db.store
            .create_frame(id, "older", "test", "mock")
            .await
            .unwrap();
    }
    db.store
        .rename_session("named-draft", "older", "Planned analysis")
        .await
        .unwrap();
    db.store
        .create_child_frame("child", "used", "older", "test", "mock")
        .await
        .unwrap();
    db.store
        .append_message("child", 1, &Message::user("Child task"))
        .await
        .unwrap();
    db.store
        .save_artifact(
            "figure",
            "older",
            "used",
            "figure.svg",
            "image/svg+xml",
            "figure.svg",
        )
        .await
        .unwrap();

    let projects = list_projects(&db.store, &idle, &idle).await.unwrap();
    assert_eq!(
        projects.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
        ["older", "same-time", "newer"]
    );
    let project = &projects[0];
    assert!(project.starred);
    assert_eq!(project.name, "Older project");
    assert_eq!(project.description, "Research notes");
    assert_eq!(
        project.workspace_dir,
        db._directory.path().to_string_lossy()
    );
    assert_eq!(project.updated_at, 10);
    assert_eq!(project.session_count, 2);
    assert_eq!(project.artifact_count, 1);
    assert_eq!((project.running_count, project.needs_you_count), (0, 0));
    assert!(!project.sync_configured);
    assert_eq!(project.last_synced_at, None);
    assert!(!projects[1].starred);
    assert_eq!(projects[1].session_count, 0);
}

#[tokio::test]
async fn activity_is_project_scoped_with_approval_and_unseen_reply_precedence() {
    let db = TestDb::new().await;
    db.project("p").await;
    db.project("other").await;
    for id in ["pending", "running", "reply", "internal", "seen", "idle"] {
        db.session(id, "p").await;
    }
    db.session("foreign", "other").await;
    for id in ["running", "reply", "internal", "seen"] {
        db.store
            .append_message(id, 2, &Message::assistant("Done"))
            .await
            .unwrap();
    }
    // Historical internal replies are persisted roles, not an LLM Role variant.
    sqlx::query("UPDATE messages SET role='internal' WHERE frame_id='internal' AND seq=2")
        .execute(&db.sql)
        .await
        .unwrap();
    sqlx::query("UPDATE messages SET ts=100")
        .execute(&db.sql)
        .await
        .unwrap();
    for id in ["pending", "seen"] {
        db.store.mark_frame_seen(id).await.unwrap();
    }
    db.store
        .create_frame("empty", "p", "test", "mock")
        .await
        .unwrap();
    let running = ["pending", "running", "foreign", "missing", "empty"]
        .map(String::from)
        .into_iter()
        .collect();
    let awaiting = ["pending", "foreign", "missing", "empty"]
        .map(String::from)
        .into_iter()
        .collect();

    let projects = list_projects(&db.store, &running, &awaiting).await.unwrap();
    let project = projects.iter().find(|p| p.id == "p").unwrap();
    assert_eq!((project.running_count, project.needs_you_count), (1, 3));
    let other = projects.iter().find(|p| p.id == "other").unwrap();
    assert_eq!((other.running_count, other.needs_you_count), (0, 1));

    for id in ["reply", "internal"] {
        db.store.mark_frame_seen(id).await.unwrap();
    }
    assert_eq!(
        project_status_counts(&db.store, "p", &running, &awaiting).await,
        (1, 1)
    );
    // A subsequent query uses the new snapshot, not cached live activity.
    let idle = HashSet::new();
    assert_eq!(
        project_status_counts(&db.store, "p", &idle, &idle).await,
        (0, 1)
    );
}

#[tokio::test]
async fn sync_metadata_uses_base_revision_and_preserves_the_existing_wire_contract() {
    let db = TestDb::new().await;
    db.project("synced").await;
    db.project("configured-only").await;
    let mut synced = ProjectSyncState::uninitialized("synced", "relay", "https://example.invalid");
    synced.base_revision = Some("revision-1".into());
    synced.last_synced_at = Some(42);
    db.store.upsert_project_sync_state(&synced).await.unwrap();
    db.store
        .upsert_project_sync_state(&ProjectSyncState::uninitialized(
            "configured-only",
            "relay",
            "https://example.invalid",
        ))
        .await
        .unwrap();
    sqlx::query("UPDATE projects SET updated_at=10")
        .execute(&db.sql)
        .await
        .unwrap();

    let idle = HashSet::new();
    let projects = list_projects(&db.store, &idle, &idle).await.unwrap();
    let configured = projects.iter().find(|p| p.id == "configured-only").unwrap();
    assert!(!configured.sync_configured);
    assert_eq!(configured.last_synced_at, None);
    let synced = projects.iter().find(|p| p.id == "synced").unwrap();
    assert_eq!(
        serde_json::to_value(synced).unwrap(),
        json!({
            "id": "synced",
            "name": "synced",
            "description": "",
            "workspace_dir": db._directory.path().to_string_lossy(),
            "starred": false,
            "session_count": 0,
            "artifact_count": 0,
            "updated_at": 10,
            "running_count": 0,
            "needs_you_count": 0,
            "sync_configured": true,
            "last_synced_at": 42
        })
    );
}

#[tokio::test]
async fn optional_enrichment_stays_best_effort_and_primary_query_errors_propagate() {
    let db = TestDb::new().await;
    db.project("p").await;
    db.session("reply", "p").await;
    let idle = HashSet::new();
    // seen_at is only needed by the activity enrichment, not the primary list.
    sqlx::query("ALTER TABLE frames RENAME COLUMN seen_at TO unavailable_seen_at")
        .execute(&db.sql)
        .await
        .unwrap();
    sqlx::query("DROP TABLE project_sync_state")
        .execute(&db.sql)
        .await
        .unwrap();
    let projects = list_projects(&db.store, &idle, &idle).await.unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0].session_count, 1);
    assert_eq!(
        (projects[0].running_count, projects[0].needs_you_count),
        (0, 0)
    );
    assert!(!projects[0].sync_configured);
    assert_eq!(projects[0].last_synced_at, None);

    sqlx::query("DROP TABLE projects")
        .execute(&db.sql)
        .await
        .unwrap();
    assert!(list_projects(&db.store, &idle, &idle).await.is_err());
}

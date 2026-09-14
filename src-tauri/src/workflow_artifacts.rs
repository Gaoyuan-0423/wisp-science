//! Strict result and ArtifactVersion capture for independently converted nodes.
use serde_json::Value;
use std::path::Path;
use wisp_core::{AgentArtifact, AgentEvidence};
use wisp_store::{ArtifactCaptureTiming, ArtifactMaterialization, ArtifactVersionDraft, Store};

pub(crate) async fn validate_and_capture(
    store: &Store,
    project_id: &str,
    root: &Path,
    frame_id: &str,
    workflow_id: &str,
    node_id: &str,
    contract: &Value,
    output: &Value,
) -> Result<(Vec<AgentArtifact>, Vec<AgentEvidence>), String> {
    if !wisp_core::workflow_conversion::is_independent_contract(contract) {
        return Ok((vec![], vec![]));
    }
    if !wisp_core::delegation::matches_json_contract(output, contract) {
        return Err("Independent Workflow node output failed its declared contract; it cannot be marked succeeded".into());
    }
    let paths = output
        .get("artifacts")
        .and_then(Value::as_array)
        .ok_or("Missing artifacts array")?;
    let mut artifacts = vec![];
    let mut evidence = vec![];
    for value in paths {
        let path = value
            .as_str()
            .ok_or("Workflow artifacts must be project-relative path strings")?;
        if Path::new(path).is_absolute() || path.contains(':') {
            return Err(format!(
                "Workflow artifact must be project-relative: {path}"
            ));
        }
        let captured = crate::snapshot_store::capture_file(
            root,
            Path::new(path),
            crate::snapshot_store::SnapshotPolicy::UpTo(
                crate::snapshot_store::DEFAULT_SNAPSHOT_LIMIT,
            ),
        )?;
        if captured.materialization != ArtifactMaterialization::Snapshot {
            return Err(format!("Workflow artifact exceeds snapshot limit: {path}"));
        }
        let id = format!(
            "workflow-{}",
            wisp_sync::sha256_hex(format!("{workflow_id}\0{node_id}\0{path}").as_bytes())
        );
        let version = store
            .save_artifact_version(&ArtifactVersionDraft {
                version_id: None,
                artifact_id: id.clone(),
                project_id: project_id.into(),
                root_frame_id: frame_id.into(),
                filename: Path::new(path)
                    .file_name()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                content_type: wisp_runs::mime::mime_for_path(Path::new(path)).into(),
                storage_path: captured.storage_path.clone(),
                logical_key: Some(format!("workflow:{workflow_id}:{node_id}:{path}")),
                size_bytes: Some(captured.size_bytes as i64),
                checksum: Some(captured.checksum),
                producing_run_id: None,
                env_snapshot_hash: None,
                materialization: ArtifactMaterialization::Snapshot,
                capture_timing: ArtifactCaptureTiming::AtCreation,
            })
            .await
            .map_err(|e| e.to_string())?;
        artifacts.push(AgentArtifact {
            id,
            name: path.into(),
            kind: wisp_runs::mime::mime_for_path(Path::new(path)).into(),
            path: Some(
                root.join(&captured.storage_path)
                    .to_string_lossy()
                    .into_owned(),
            ),
        });
        evidence.push(AgentEvidence {
            kind: "workflow_artifact_version".into(),
            summary: path.into(),
            reference: Some(version),
        });
    }
    Ok((artifacts, evidence))
}

/// Reuse successful nodes only against their pinned ArtifactVersions, never
/// whichever version happens to be latest when a retry starts.
pub(crate) async fn validate_cached(
    store: &Store,
    project_id: &str,
    root: &Path,
    contract: &Value,
    response: &wisp_core::AgentDelegationResponse,
) -> Result<(), String> {
    if !wisp_core::workflow_conversion::is_independent_contract(contract) {
        return Ok(());
    }
    let output = response.output.get("data").unwrap_or(&response.output);
    if !wisp_core::delegation::matches_json_contract(output, contract) {
        return Err("Cached Workflow result no longer satisfies its contract".into());
    }
    for path in output["artifacts"]
        .as_array()
        .ok_or("Invalid cached artifacts")?
    {
        let path = path.as_str().ok_or("Invalid cached artifact path")?;
        let receipt = response
            .artifacts
            .iter()
            .find(|a| a.name == path)
            .ok_or("Cached Workflow artifact has no verified receipt; start a new run")?;
        let version_id = response
            .evidence
            .iter()
            .find(|e| e.kind == "workflow_artifact_version" && e.summary == path)
            .and_then(|e| e.reference.as_deref())
            .ok_or("Cached Workflow artifact has no pinned version; start a new run")?;
        let context = store
            .get_artifact_version_context(version_id)
            .await
            .map_err(|e| e.to_string())?
            .ok_or("Cached ArtifactVersion was removed")?;
        let version = context.version;
        if context.project_id != project_id || version.artifact_id != receipt.id {
            return Err("Cached artifact does not belong to this Workflow project".into());
        }
        let file = wisp_tools::safety::validate_file_path(root, path)?;
        if std::fs::metadata(&file).map_err(|e| e.to_string())?.len()
            > crate::snapshot_store::DEFAULT_SNAPSHOT_LIMIT
        {
            return Err(format!("Cached artifact changed: {path}"));
        }
        let captured = crate::snapshot_store::capture_file(
            root,
            Path::new(path),
            crate::snapshot_store::SnapshotPolicy::Reference,
        )?;
        if version.checksum.as_deref() != Some(captured.checksum.as_str()) {
            return Err(format!("Cached artifact changed: {path}; start a new run"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn contract() -> Value {
        serde_json::json!({"type":"object","required":["status","summary","artifacts"],"properties":{
        "status":{"const":"succeeded"},"summary":{"type":"string"},"artifacts":{"type":"array","const":["report.md"]}}})
    }
    #[tokio::test]
    async fn converted_result_requires_real_files_and_registers_durable_artifact_versions() {
        let root =
            std::env::temp_dir().join(format!("wisp-workflow-artifacts-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let store = Store::open(&root.join("store.sqlite")).await.unwrap();
        store
            .create_project("p", "test", &root.to_string_lossy())
            .await
            .unwrap();
        store.create_frame("f", "p", "frame", "test").await.unwrap();
        let output =
            serde_json::json!({"status":"succeeded","summary":"written","artifacts":["report.md"]});
        assert!(
            validate_and_capture(&store, "p", &root, "f", "w", "n", &contract(), &output)
                .await
                .is_err()
        );
        std::fs::write(root.join("report.md"), "real report").unwrap();
        let (artifacts, evidence) =
            validate_and_capture(&store, "p", &root, "f", "w", "n", &contract(), &output)
                .await
                .unwrap();
        assert_eq!(artifacts.len(), 1);
        let version = store
            .latest_artifact_version(&artifacts[0].id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join(version.storage_path)).unwrap(),
            "real report"
        );
        let response = wisp_core::AgentDelegationResponse {
            request_id: "request".into(),
            status: wisp_core::DelegationStatus::Succeeded,
            output: serde_json::json!({"data":output}),
            artifact_ids: artifacts.iter().map(|a| a.id.clone()).collect(),
            artifacts: artifacts.clone(),
            evidence,
            usage: Default::default(),
            agent_session_id: None,
            child_frame_id: Some("f".into()),
            error: None,
            nested_results: vec![],
        };
        validate_cached(&store, "p", &root, &contract(), &response)
            .await
            .unwrap();
        std::fs::write(root.join("report.md"), "changed after success").unwrap();
        assert!(validate_cached(&store, "p", &root, &contract(), &response)
            .await
            .unwrap_err()
            .contains("changed"));
        std::fs::write(root.join("report.md"), "real report").unwrap();
        let failed = serde_json::json!({"status":"failed","summary":"missing search provider","artifacts":["report.md"]});
        assert!(
            validate_and_capture(&store, "p", &root, "f", "w", "n", &contract(), &failed)
                .await
                .is_err()
        );
        drop(store);
        let _ = std::fs::remove_dir_all(root);
    }
    #[tokio::test]
    async fn unsafe_artifact_paths_and_directories_cannot_become_successful_deliveries() {
        let root =
            std::env::temp_dir().join(format!("wisp-workflow-paths-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("directory")).unwrap();
        let store = Store::open(&root.join("store.sqlite")).await.unwrap();
        let mut schema = contract();
        schema["properties"]["artifacts"] =
            serde_json::json!({"type":"array","items":{"type":"string"}});
        for path in ["../outside", "/tmp/outside", "directory"] {
            let output =
                serde_json::json!({"status":"succeeded","summary":"claimed","artifacts":[path]});
            assert!(
                validate_and_capture(&store, "p", &root, "f", "w", "n", &schema, &output)
                    .await
                    .is_err()
            );
        }
        drop(store);
        let _ = std::fs::remove_dir_all(root);
    }
}

//! Context epochs: one frame, many model-context snapshots.
//!
//! A compaction used to rewrite `messages` in place (delete + renumber 1..n),
//! which severed every seq-anchored record (visual `MessageBoundary`,
//! `turn_file_undo`, resource links, reviews). An epoch instead appends the
//! compacted working set as new rows and moves `frames.head_epoch`; rows in
//! older epochs are frozen history. `seq` is unique per frame across epochs
//! and never renumbered.
//!
//! Two views of one frame:
//! - **head epoch** (`HEAD_EPOCH_ROWS`): what the model sees now.
//! - **live log** (`LIVE_LOG_ROWS`): every row except the ones a compaction
//!   materialised (system copies, checkpoint, retained tail). This is the
//!   transcript-facing view — exactly what `messages` would hold had no
//!   compaction ever happened — and the only view whose user rows line up
//!   with visual `User` events.

use super::sessions::{insert_message_row_in_epoch, message_from_row};
use super::Store;
use anyhow::Result;
use sqlx::Row;
use wisp_llm::Message;

/// Predicate on a `messages` row aliased `m`: the row belongs to its frame's
/// head epoch. `COALESCE` keeps rows readable for frames that have no
/// `frames` row (some tests insert messages directly).
pub(crate) const HEAD_EPOCH_ROWS: &str =
    "m.epoch=COALESCE((SELECT f.head_epoch FROM frames f WHERE f.id=m.frame_id),0)";

/// Predicate on a `messages` row aliased `m`: the row was appended live, not
/// materialised by a compaction.
pub(crate) const LIVE_LOG_ROWS: &str = "NOT EXISTS (SELECT 1 FROM context_epochs ce \
     WHERE ce.frame_id=m.frame_id AND m.seq BETWEEN ce.first_seq AND ce.initial_head_seq)";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextEpochRecord {
    pub frame_id: String,
    pub epoch: i64,
    pub parent_epoch: i64,
    /// `manual` | `auto` | `overflow`.
    pub strategy: String,
    /// `prune_only` | `semantic`.
    pub kind: String,
    pub before_tokens: i64,
    pub after_tokens: i64,
    /// First row of the epoch (a system message).
    pub first_seq: i64,
    /// Last row written when the epoch was opened; rows above it were
    /// appended by later turns.
    pub initial_head_seq: i64,
    /// The `[context summary checkpoint]` row, when the fold was semantic.
    pub checkpoint_seq: Option<i64>,
    /// Seq (in the parent epoch) of the first retained-tail message. Best
    /// effort; only informs UI markers.
    pub first_kept_seq: Option<i64>,
    /// `wisp-history:<id>` reference of the archive written before the fold.
    pub archive_ref: Option<String>,
    /// `session_ui_events.seq` of the matching Compaction event.
    pub ui_event_seq: Option<i64>,
    pub created_at: i64,
}

pub struct OpenContextEpoch<'a> {
    /// The compacted model context, in order. Becomes the new head epoch.
    pub messages: &'a [Message],
    pub strategy: &'a str,
    pub kind: &'a str,
    pub before_tokens: usize,
    pub after_tokens: usize,
    /// Index into `messages` of the summary checkpoint row, if any.
    pub checkpoint_index: Option<usize>,
    pub first_kept_seq: Option<i64>,
    pub archive_ref: Option<&'a str>,
    pub ui_event_seq: Option<i64>,
}

fn record_from_row(row: &sqlx::sqlite::SqliteRow) -> Result<ContextEpochRecord> {
    Ok(ContextEpochRecord {
        frame_id: row.try_get("frame_id")?,
        epoch: row.try_get("epoch")?,
        parent_epoch: row.try_get("parent_epoch")?,
        strategy: row.try_get("strategy")?,
        kind: row.try_get("kind")?,
        before_tokens: row.try_get("before_tokens")?,
        after_tokens: row.try_get("after_tokens")?,
        first_seq: row.try_get("first_seq")?,
        initial_head_seq: row.try_get("initial_head_seq")?,
        checkpoint_seq: row.try_get("checkpoint_seq")?,
        first_kept_seq: row.try_get("first_kept_seq")?,
        archive_ref: row.try_get("archive_ref")?,
        ui_event_seq: row.try_get("ui_event_seq")?,
        created_at: row.try_get("created_at")?,
    })
}

const SELECT_EPOCH: &str = "SELECT frame_id,epoch,parent_epoch,strategy,kind,before_tokens,\
     after_tokens,first_seq,initial_head_seq,checkpoint_seq,first_kept_seq,archive_ref,\
     ui_event_seq,created_at FROM context_epochs";

impl Store {
    pub async fn frame_head_epoch(&self, frame_id: &str) -> Result<i64> {
        Ok(
            sqlx::query_scalar("SELECT COALESCE((SELECT head_epoch FROM frames WHERE id=?),0)")
                .bind(frame_id)
                .fetch_one(&self.pool)
                .await?,
        )
    }

    /// Rows of one epoch, oldest first, with their durable seqs.
    pub async fn load_messages_in_epoch(
        &self,
        frame_id: &str,
        epoch: i64,
    ) -> Result<Vec<(i64, Message)>> {
        let rows = sqlx::query(
            "SELECT seq,role,content,tool_calls,tool_call_id,tool_name,reasoning,ts,model_name \
             FROM messages m WHERE m.frame_id=? AND m.epoch=? ORDER BY seq ASC",
        )
        .bind(frame_id)
        .bind(epoch)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .filter_map(|row| match message_from_row(row) {
                Ok(item) => Some(item),
                Err(error) => {
                    tracing::warn!(frame_id, %error, "skipping unreadable message row");
                    None
                }
            })
            .collect())
    }

    /// Every row of every epoch as `(epoch, seq, message)`, ordered by seq.
    /// For lossless export; model and transcript readers must not use it.
    pub async fn load_messages_all_epochs(
        &self,
        frame_id: &str,
    ) -> Result<Vec<(i64, i64, Message)>> {
        let rows = sqlx::query(
            "SELECT epoch,seq,role,content,tool_calls,tool_call_id,tool_name,reasoning,ts,model_name \
             FROM messages m WHERE m.frame_id=? ORDER BY seq ASC",
        )
        .bind(frame_id)
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|row| {
                let epoch: i64 = row.try_get("epoch")?;
                let (seq, message) = message_from_row(row)?;
                Ok((epoch, seq, message))
            })
            .collect()
    }

    /// Append a compacted context as a new epoch and make it the head. One
    /// write transaction: the previous epoch's rows are untouched, new rows
    /// take seqs from `MAX(seq)+1` upward, and `frames.head_epoch` advances.
    /// Returns the new epoch number.
    pub async fn open_context_epoch(
        &self,
        frame_id: &str,
        input: OpenContextEpoch<'_>,
    ) -> Result<i64> {
        if input.messages.is_empty() {
            anyhow::bail!("a context epoch needs at least one message");
        }
        let mut tx = self.begin_write().await?;
        let head: Option<i64> = sqlx::query_scalar("SELECT head_epoch FROM frames WHERE id=?")
            .bind(frame_id)
            .fetch_optional(&mut *tx)
            .await?;
        let head = head.ok_or_else(|| anyhow::anyhow!("Session not found"))?;
        let recorded_max: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(epoch),0) FROM context_epochs WHERE frame_id=?",
        )
        .bind(frame_id)
        .fetch_one(&mut *tx)
        .await?;
        let epoch = head.max(recorded_max) + 1;
        let first_seq: i64 =
            sqlx::query_scalar("SELECT COALESCE(MAX(seq),0)+1 FROM messages WHERE frame_id=?")
                .bind(frame_id)
                .fetch_one(&mut *tx)
                .await?;
        for (offset, message) in input.messages.iter().enumerate() {
            insert_message_row_in_epoch(
                &mut *tx,
                frame_id,
                Some(epoch),
                first_seq + offset as i64,
                message,
            )
            .await?;
        }
        let initial_head_seq = first_seq + input.messages.len() as i64 - 1;
        let checkpoint_seq = input
            .checkpoint_index
            .filter(|index| *index < input.messages.len())
            .map(|index| first_seq + index as i64);
        sqlx::query(
            "INSERT INTO context_epochs(frame_id,epoch,parent_epoch,strategy,kind,before_tokens,\
             after_tokens,first_seq,initial_head_seq,checkpoint_seq,first_kept_seq,archive_ref,\
             ui_event_seq,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        )
        .bind(frame_id)
        .bind(epoch)
        .bind(head)
        .bind(input.strategy)
        .bind(input.kind)
        .bind(input.before_tokens as i64)
        .bind(input.after_tokens as i64)
        .bind(first_seq)
        .bind(initial_head_seq)
        .bind(checkpoint_seq)
        .bind(input.first_kept_seq)
        .bind(input.archive_ref)
        .bind(input.ui_event_seq)
        .bind(chrono::Utc::now().timestamp())
        .execute(&mut *tx)
        .await?;
        sqlx::query("UPDATE frames SET head_epoch=? WHERE id=?")
            .bind(epoch)
            .bind(frame_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(epoch)
    }

    /// Recorded epochs (epoch 0 is implicit), oldest first.
    pub async fn context_epochs(&self, frame_id: &str) -> Result<Vec<ContextEpochRecord>> {
        let rows = sqlx::query(&format!("{SELECT_EPOCH} WHERE frame_id=? ORDER BY epoch"))
            .bind(frame_id)
            .fetch_all(&self.pool)
            .await?;
        rows.iter().map(record_from_row).collect()
    }

    pub async fn context_epoch(
        &self,
        frame_id: &str,
        epoch: i64,
    ) -> Result<Option<ContextEpochRecord>> {
        let row = sqlx::query(&format!("{SELECT_EPOCH} WHERE frame_id=? AND epoch=?"))
            .bind(frame_id)
            .bind(epoch)
            .fetch_optional(&self.pool)
            .await?;
        row.as_ref().map(record_from_row).transpose()
    }

    /// Attach a Compaction UI event to an already-open epoch.
    pub async fn set_context_epoch_ui_event(
        &self,
        frame_id: &str,
        epoch: i64,
        ui_event_seq: i64,
    ) -> Result<()> {
        sqlx::query("UPDATE context_epochs SET ui_event_seq=? WHERE frame_id=? AND epoch=?")
            .bind(ui_event_seq)
            .bind(frame_id)
            .bind(epoch)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// `session_ui_events.seq` of the newest persisted context-compaction
    /// event, if any. `auto_continue` reuses the Compaction event for
    /// truncated-output continuation and is not a context rewrite.
    pub async fn latest_compaction_ui_event_seq(&self, frame_id: &str) -> Result<Option<i64>> {
        Ok(sqlx::query_scalar(
            "SELECT MAX(seq) FROM session_ui_events WHERE frame_id=? \
             AND json_extract(event_json,'$.kind')='Compaction' \
             AND COALESCE(json_extract(event_json,'$.strategy'),'')<>'auto_continue'",
        )
        .bind(frame_id)
        .fetch_one(&self.pool)
        .await?)
    }

    /// The epoch that owns `(frame_id, seq)`, or `None` when no such row.
    pub async fn resolve_message_epoch(&self, frame_id: &str, seq: i64) -> Result<Option<i64>> {
        Ok(
            sqlx::query_scalar("SELECT epoch FROM messages WHERE frame_id=? AND seq=?")
                .bind(frame_id)
                .bind(seq)
                .fetch_optional(&self.pool)
                .await?,
        )
    }

    /// Seq of the model-context row that starts the `user_index`-th visual
    /// user turn (0-based, checkpoint User events skipped). `None` when the
    /// transcript has no User events yet (legacy message-only prefix) or the
    /// index is past the log.
    pub async fn visual_turn_anchor(
        &self,
        frame_id: &str,
        user_index: usize,
    ) -> Result<Option<i64>> {
        let rows = sqlx::query(
            "SELECT json_extract(event_json,'$.kind') AS kind, \
             json_extract(event_json,'$.text') AS text, \
             json_extract(event_json,'$.seq') AS message_seq \
             FROM session_ui_events WHERE frame_id=? \
             AND json_extract(event_json,'$.kind') IN ('User','MessageBoundary') \
             ORDER BY seq",
        )
        .bind(frame_id)
        .fetch_all(&self.pool)
        .await?;
        let mut seen = 0usize;
        let mut waiting = false;
        for row in rows {
            let kind: String = row.try_get("kind")?;
            match kind.as_str() {
                "User" => {
                    let Some(text) = row.try_get::<Option<String>, _>("text")? else {
                        continue;
                    };
                    if is_compaction_checkpoint_text(&text) {
                        continue;
                    }
                    waiting = seen == user_index;
                    seen += 1;
                }
                "MessageBoundary" if waiting => {
                    return Ok(row.try_get::<Option<i64>, _>("message_seq")?);
                }
                _ => {}
            }
        }
        Ok(None)
    }

    /// Visual user turns in the live transcript (checkpoint cards omitted).
    pub async fn visual_user_count(&self, frame_id: &str) -> Result<usize> {
        let rows: Vec<Option<String>> = sqlx::query_scalar(
            "SELECT json_extract(event_json,'$.text') FROM session_ui_events \
             WHERE frame_id=? AND json_extract(event_json,'$.kind')='User' ORDER BY seq",
        )
        .bind(frame_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .flatten()
            .filter(|text| !is_compaction_checkpoint_text(text))
            .count())
    }

    /// Make `epoch` the head and drop every model-context row after
    /// `keep_seq`. Later epochs (higher seqs and their `context_epochs`
    /// records) disappear. The visual transcript is cut at the last
    /// `MessageBoundary` whose message seq is `<= keep_seq`.
    pub async fn rewind_to_seq(&self, frame_id: &str, epoch: i64, keep_seq: i64) -> Result<()> {
        let mut tx = self.begin_write().await?;
        let current: Option<i64> = sqlx::query_scalar("SELECT head_epoch FROM frames WHERE id=?")
            .bind(frame_id)
            .fetch_optional(&mut *tx)
            .await?;
        let current = current.ok_or_else(|| anyhow::anyhow!("Session not found"))?;
        if epoch < 0 || epoch > current {
            anyhow::bail!("context epoch {epoch} is not in this session");
        }
        sqlx::query("UPDATE frames SET head_epoch=? WHERE id=?")
            .bind(epoch)
            .bind(frame_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM context_epochs WHERE frame_id=? AND epoch>?")
            .bind(frame_id)
            .bind(epoch)
            .execute(&mut *tx)
            .await?;
        crate::Store::truncate_message_rows(&mut tx, frame_id, keep_seq).await?;
        crate::sessions::reconcile_session_branches_after_truncate(&mut tx, frame_id, keep_seq)
            .await?;
        tx.commit().await?;
        Ok(())
    }
}

/// Synthetic compaction cards are not user-authored questions.
pub fn is_compaction_checkpoint_text(text: &str) -> bool {
    text.starts_with("[context summary checkpoint]") || text.starts_with("[compacted;")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Store;

    async fn store() -> Store {
        let tmp = std::env::temp_dir().join(format!(
            "wisp_context_epochs_{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        let store = Store::open(&tmp).await.unwrap();
        store.create_project("p", "proj", "").await.unwrap();
        store.create_frame("f", "p", "OPERON", "m").await.unwrap();
        store
    }

    async fn seed(store: &Store, texts: &[(&str, &str)]) {
        for (index, (role, text)) in texts.iter().enumerate() {
            let message = match *role {
                "system" => Message::system(*text),
                "user" => Message::user(*text),
                _ => Message::assistant(*text),
            };
            store
                .append_message("f", index as i64 + 1, &message)
                .await
                .unwrap();
        }
    }

    fn compacted() -> Vec<Message> {
        vec![
            Message::system("sys"),
            Message::user("[context summary checkpoint]\n\nsummary"),
            Message::user("q2"),
            Message::assistant("a2"),
        ]
    }

    fn open_input(messages: &[Message]) -> OpenContextEpoch<'_> {
        OpenContextEpoch {
            messages,
            strategy: "manual",
            kind: "semantic",
            before_tokens: 1000,
            after_tokens: 200,
            checkpoint_index: Some(1),
            first_kept_seq: Some(4),
            archive_ref: Some("wisp-history:abc"),
            ui_event_seq: None,
        }
    }

    #[tokio::test]
    async fn fresh_database_defaults_to_epoch_zero() {
        let store = store().await;
        seed(&store, &[("system", "sys"), ("user", "q1")]).await;
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 0);
        assert!(store.context_epochs("f").await.unwrap().is_empty());
        let all = store.load_messages_all_epochs("f").await.unwrap();
        assert_eq!(
            all.iter()
                .map(|(epoch, seq, _)| (*epoch, *seq))
                .collect::<Vec<_>>(),
            [(0, 1), (0, 2)]
        );
        assert_eq!(store.resolve_message_epoch("f", 2).await.unwrap(), Some(0));
        assert_eq!(store.resolve_message_epoch("f", 9).await.unwrap(), None);
    }

    /// A database from before epochs: no `epoch` / `head_epoch` columns and no
    /// `context_epochs` table. Opening it must backfill everything to epoch 0
    /// and read the old rows back unchanged.
    #[tokio::test]
    async fn legacy_database_backfills_epoch_zero() {
        let tmp = std::env::temp_dir().join(format!(
            "wisp_context_epochs_legacy_{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        {
            let pool = sqlx::SqlitePool::connect(&format!("sqlite://{}?mode=rwc", tmp.display()))
                .await
                .unwrap();
            for statement in [
                "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, description TEXT, \
                 workspace_dir TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
                "CREATE TABLE frames (id TEXT PRIMARY KEY, parent_frame_id TEXT, root_frame_id TEXT, \
                 agent_name TEXT NOT NULL, status TEXT NOT NULL, project_id TEXT, model TEXT, \
                 input_tokens INTEGER, output_tokens INTEGER, created_at INTEGER NOT NULL, \
                 updated_at INTEGER NOT NULL, completed_at INTEGER, title TEXT)",
                "CREATE TABLE messages (id TEXT PRIMARY KEY, frame_id TEXT NOT NULL, seq INTEGER NOT NULL, \
                 role TEXT NOT NULL, content TEXT, tool_calls TEXT, tool_call_id TEXT, tool_name TEXT, \
                 reasoning TEXT, ts INTEGER NOT NULL, model_name TEXT, UNIQUE(frame_id, seq))",
                "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                "INSERT INTO projects(id,name,description,created_at,updated_at) VALUES('p','proj','',1,1)",
                "INSERT INTO frames(id,parent_frame_id,root_frame_id,agent_name,status,project_id,created_at,updated_at) \
                 VALUES('f','f','f','OPERON','running','p',1,1)",
                "INSERT INTO messages(id,frame_id,seq,role,content,ts) VALUES('m1','f',1,'system','\"sys\"',1)",
                "INSERT INTO messages(id,frame_id,seq,role,content,ts) VALUES('m2','f',2,'user','\"legacy\"',2)",
            ] {
                sqlx::query(statement).execute(&pool).await.unwrap();
            }
            pool.close().await;
        }
        let store = Store::open(&tmp).await.unwrap();
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 0);
        assert!(store.context_epochs("f").await.unwrap().is_empty());
        let messages = store.load_messages_with_seq("f").await.unwrap();
        assert_eq!(
            messages
                .iter()
                .map(|(seq, message)| (*seq, message.content.as_text()))
                .collect::<Vec<_>>(),
            [(1, "sys".to_string()), (2, "legacy".to_string())]
        );
        assert_eq!(store.resolve_message_epoch("f", 2).await.unwrap(), Some(0));
        // Reopening is idempotent.
        store.pool.close().await;
        let store = Store::open(&tmp).await.unwrap();
        assert_eq!(store.load_messages("f").await.unwrap().len(), 2);
        let _ = std::fs::remove_file(&tmp);
    }

    #[tokio::test]
    async fn opening_an_epoch_freezes_old_rows_and_moves_the_head() {
        let store = store().await;
        seed(
            &store,
            &[
                ("system", "sys"),
                ("user", "q1"),
                ("assistant", "a1"),
                ("user", "q2"),
                ("assistant", "a2"),
            ],
        )
        .await;
        let snapshot = |rows: &[(i64, i64, Message)]| {
            rows.iter()
                .map(|(epoch, seq, message)| {
                    (*epoch, *seq, serde_json::to_string(message).unwrap())
                })
                .collect::<Vec<_>>()
        };
        let before = snapshot(&store.load_messages_all_epochs("f").await.unwrap());

        let messages = compacted();
        let epoch = store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        assert_eq!(epoch, 1);
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 1);

        // Old rows are byte-for-byte untouched.
        let all = store.load_messages_all_epochs("f").await.unwrap();
        assert_eq!(snapshot(&all[..5]), before);
        // New rows continue the seq space and carry the new epoch.
        assert_eq!(
            all[5..]
                .iter()
                .map(|(epoch, seq, message)| (*epoch, *seq, message.content.as_text()))
                .collect::<Vec<_>>(),
            [
                (1, 6, "sys".to_string()),
                (1, 7, "[context summary checkpoint]\n\nsummary".to_string()),
                (1, 8, "q2".to_string()),
                (1, 9, "a2".to_string()),
            ]
        );
        // The model reads only the head epoch.
        let head = store.load_messages_with_seq("f").await.unwrap();
        assert_eq!(
            head.iter().map(|(seq, _)| *seq).collect::<Vec<_>>(),
            [6, 7, 8, 9]
        );
        assert_eq!(store.load_messages("f").await.unwrap().len(), 4);
        let in_epoch = store.load_messages_in_epoch("f", 0).await.unwrap();
        assert_eq!(in_epoch.len(), 5);

        let records = store.context_epochs("f").await.unwrap();
        assert_eq!(records.len(), 1);
        let record = &records[0];
        assert_eq!(record.epoch, 1);
        assert_eq!(record.parent_epoch, 0);
        assert_eq!(record.first_seq, 6);
        assert_eq!(record.initial_head_seq, 9);
        assert_eq!(record.checkpoint_seq, Some(7));
        assert_eq!(record.first_kept_seq, Some(4));
        assert_eq!(record.archive_ref.as_deref(), Some("wisp-history:abc"));
        assert_eq!(record.strategy, "manual");
        assert_eq!(record.kind, "semantic");
        assert_eq!(store.resolve_message_epoch("f", 3).await.unwrap(), Some(0));
        assert_eq!(store.resolve_message_epoch("f", 8).await.unwrap(), Some(1));
        assert_eq!(store.max_message_seq("f").await.unwrap(), 9);
    }

    #[tokio::test]
    async fn appends_after_an_epoch_land_in_the_head_epoch() {
        let store = store().await;
        seed(&store, &[("system", "sys"), ("user", "q1")]).await;
        let messages = compacted();
        store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        let next = store.max_message_seq("f").await.unwrap() + 1;
        store
            .append_message("f", next, &Message::user("q3"))
            .await
            .unwrap();
        assert_eq!(
            store.resolve_message_epoch("f", next).await.unwrap(),
            Some(1)
        );
        let head = store.load_messages_with_seq("f").await.unwrap();
        assert_eq!(head.last().unwrap().1.content.as_text(), "q3");
        // The appended row is outside the materialised range.
        let record = store.context_epoch("f", 1).await.unwrap().unwrap();
        assert!(next > record.initial_head_seq);
    }

    #[tokio::test]
    async fn epochs_chain_through_parent_epoch() {
        let store = store().await;
        seed(&store, &[("system", "sys"), ("user", "q1")]).await;
        let messages = compacted();
        assert_eq!(
            store
                .open_context_epoch("f", open_input(&messages))
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .open_context_epoch("f", open_input(&messages))
                .await
                .unwrap(),
            2
        );
        let records = store.context_epochs("f").await.unwrap();
        assert_eq!(
            records
                .iter()
                .map(|record| (record.epoch, record.parent_epoch))
                .collect::<Vec<_>>(),
            [(1, 0), (2, 1)]
        );
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 2);
        assert_eq!(store.load_messages("f").await.unwrap().len(), 4);
    }

    #[tokio::test]
    async fn replace_messages_resets_to_epoch_zero() {
        let store = store().await;
        seed(&store, &[("system", "sys"), ("user", "q1")]).await;
        let messages = compacted();
        store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        store
            .replace_messages("f", &[Message::system("fresh"), Message::user("imported")])
            .await
            .unwrap();
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 0);
        assert!(store.context_epochs("f").await.unwrap().is_empty());
        let all = store.load_messages_all_epochs("f").await.unwrap();
        assert_eq!(
            all.iter()
                .map(|(epoch, seq, _)| (*epoch, *seq))
                .collect::<Vec<_>>(),
            [(0, 1), (0, 2)]
        );
    }

    /// Transcript-facing readers walk the live log: a compaction's copies add
    /// no user turns, so paging and the outline still see exactly the turns
    /// the visual transcript has, plus anything appended afterwards.
    #[tokio::test]
    async fn transcript_readers_skip_epoch_copies() {
        let store = store().await;
        seed(
            &store,
            &[
                ("system", "sys"),
                ("user", "q1"),
                ("assistant", "a1"),
                ("user", "q2"),
                ("assistant", "a2"),
            ],
        )
        .await;
        let messages = compacted();
        store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        let next = store.max_message_seq("f").await.unwrap() + 1;
        store
            .append_message("f", next, &Message::user("q3"))
            .await
            .unwrap();
        store
            .append_message("f", next + 1, &Message::assistant("a3"))
            .await
            .unwrap();

        let outline = store.load_session_user_messages("f").await.unwrap();
        assert_eq!(
            outline
                .iter()
                .map(|(seq, text, _, _)| (*seq, text.as_str()))
                .collect::<Vec<_>>(),
            [(2, "q1"), (4, "q2"), (next, "q3")]
        );

        let page = store
            .load_session_transcript_page("f", None, 10)
            .await
            .unwrap();
        assert_eq!(
            page.messages
                .iter()
                .map(|(seq, message)| (*seq, message.content.as_text()))
                .collect::<Vec<_>>(),
            [
                (1, "sys".to_string()),
                (2, "q1".to_string()),
                (3, "a1".to_string()),
                (4, "q2".to_string()),
                (5, "a2".to_string()),
                (next, "q3".to_string()),
                (next + 1, "a3".to_string()),
            ]
        );
        assert_eq!(page.user_offset, 0);
        assert!(page.next_before_seq.is_none());

        // One turn per page: the newest live turn first, then q2, then q1.
        let last = store
            .load_session_transcript_page("f", None, 1)
            .await
            .unwrap();
        assert_eq!(last.messages[0].0, next);
        assert_eq!(last.user_offset, 2);
        let middle = store
            .load_session_transcript_page("f", last.next_before_seq, 1)
            .await
            .unwrap();
        assert_eq!(middle.messages[0].0, 4);
        assert_eq!(middle.user_offset, 1);

        // Model-side readers see the head epoch only.
        let head = store.load_messages("f").await.unwrap();
        assert_eq!(
            head.iter()
                .map(|message| message.content.as_text())
                .collect::<Vec<_>>(),
            [
                "sys",
                "[context summary checkpoint]\n\nsummary",
                "q2",
                "a2",
                "q3",
                "a3"
            ]
        );
    }

    #[tokio::test]
    async fn moving_a_session_keeps_every_epoch() {
        let store = store().await;
        seed(&store, &[("system", "sys"), ("user", "q1")]).await;
        let messages = compacted();
        store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        store.create_project("p2", "other", "").await.unwrap();
        let moved = "moved";
        store
            .move_session_to_project("f", "p", "p2", moved)
            .await
            .unwrap();
        assert_eq!(store.frame_head_epoch(moved).await.unwrap(), 1);
        let records = store.context_epochs(moved).await.unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].first_seq, 3);
        assert_eq!(
            store
                .load_messages_all_epochs(moved)
                .await
                .unwrap()
                .iter()
                .map(|(epoch, seq, _)| (*epoch, *seq))
                .collect::<Vec<_>>(),
            [(0, 1), (0, 2), (1, 3), (1, 4), (1, 5), (1, 6)]
        );
        assert_eq!(store.load_messages(moved).await.unwrap().len(), 4);
    }

    #[tokio::test]
    async fn open_rejects_an_empty_context_or_unknown_frame() {
        let store = store().await;
        assert!(store
            .open_context_epoch("f", open_input(&[]))
            .await
            .is_err());
        let messages = compacted();
        assert!(store
            .open_context_epoch("missing", open_input(&messages))
            .await
            .is_err());
    }

    #[tokio::test]
    async fn set_ui_event_attaches_the_compaction_event() {
        let store = store().await;
        seed(&store, &[("system", "sys"), ("user", "q1")]).await;
        let messages = compacted();
        let epoch = store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        store
            .set_context_epoch_ui_event("f", epoch, 42)
            .await
            .unwrap();
        assert_eq!(
            store
                .context_epoch("f", epoch)
                .await
                .unwrap()
                .unwrap()
                .ui_event_seq,
            Some(42)
        );
    }

    async fn persist_visual_turn(store: &Store, event_seq: &mut i64, message_seq: i64, text: &str) {
        store
            .append_session_ui_event(
                "f",
                *event_seq,
                &format!(r#"{{"kind":"User","frame_id":"f","text":"{text}"}}"#),
            )
            .await
            .unwrap();
        *event_seq += 1;
        store
            .append_session_ui_event(
                "f",
                *event_seq,
                &format!(r#"{{"kind":"MessageBoundary","frame_id":"f","seq":{message_seq}}}"#),
            )
            .await
            .unwrap();
        *event_seq += 1;
        store
            .append_session_ui_event(
                "f",
                *event_seq,
                &format!(r#"{{"kind":"Text","frame_id":"f","delta":"answer {text}"}}"#),
            )
            .await
            .unwrap();
        *event_seq += 1;
        store
            .append_session_ui_event(
                "f",
                *event_seq,
                &format!(
                    r#"{{"kind":"MessageBoundary","frame_id":"f","seq":{}}}"#,
                    message_seq + 1
                ),
            )
            .await
            .unwrap();
        *event_seq += 1;
    }

    #[tokio::test]
    async fn visual_turn_anchor_skips_checkpoints_and_legacy_prefix() {
        let store = store().await;
        seed(
            &store,
            &[
                ("system", "sys"),
                ("user", "legacy"),
                ("assistant", "old"),
                ("user", "q1"),
                ("assistant", "a1"),
            ],
        )
        .await;
        assert_eq!(store.visual_turn_anchor("f", 0).await.unwrap(), None);

        let mut event_seq = 1i64;
        persist_visual_turn(&store, &mut event_seq, 4, "q1").await;
        store
            .append_session_ui_event(
                "f",
                event_seq,
                r#"{"kind":"User","frame_id":"f","text":"[context summary checkpoint]\n\nfolded"}"#,
            )
            .await
            .unwrap();
        assert_eq!(store.visual_turn_anchor("f", 0).await.unwrap(), Some(4));
        assert_eq!(store.visual_turn_anchor("f", 1).await.unwrap(), None);
        assert_eq!(store.visual_user_count("f").await.unwrap(), 1);
    }

    #[tokio::test]
    async fn rewind_to_seq_restores_an_older_epoch() {
        let store = store().await;
        seed(
            &store,
            &[
                ("system", "sys"),
                ("user", "q1"),
                ("assistant", "a1"),
                ("user", "q2"),
                ("assistant", "a2"),
            ],
        )
        .await;
        let mut event_seq = 1i64;
        persist_visual_turn(&store, &mut event_seq, 2, "q1").await;
        persist_visual_turn(&store, &mut event_seq, 4, "q2").await;
        store
            .save_turn_file_undo(
                "f",
                2,
                "notes.md",
                true,
                None,
                Some("a"),
                Some("b"),
                true,
                None,
            )
            .await
            .unwrap();
        let messages = compacted();
        store
            .open_context_epoch("f", open_input(&messages))
            .await
            .unwrap();
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 1);

        store.rewind_to_seq("f", 0, 3).await.unwrap();
        assert_eq!(store.frame_head_epoch("f").await.unwrap(), 0);
        assert!(store.context_epochs("f").await.unwrap().is_empty());
        let head = store.load_messages_with_seq("f").await.unwrap();
        assert_eq!(
            head.iter()
                .map(|(seq, message)| (*seq, message.content.as_text().to_string()))
                .collect::<Vec<_>>(),
            [(1, "sys".into()), (2, "q1".into()), (3, "a1".into()),]
        );
        assert_eq!(store.list_turn_file_undo("f", 2).await.unwrap().len(), 1);
        assert_eq!(store.visual_user_count("f").await.unwrap(), 1);
        assert!(store.visual_turn_anchor("f", 1).await.unwrap().is_none());
    }
}

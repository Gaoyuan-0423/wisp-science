-- Context epochs: a compaction appends a fresh model-context snapshot inside
-- the same frame instead of rewriting `messages`. Rows whose epoch is below
-- `frames.head_epoch` are frozen history; `seq` stays unique per frame across
-- epochs so visual MessageBoundary anchors never dangle. Epoch 0 has no row
-- here. `first_seq..=initial_head_seq` is the range of rows materialised by
-- the compaction (system copies, checkpoint, retained tail); rows appended
-- later in the same epoch fall outside it.
CREATE TABLE IF NOT EXISTS context_epochs (
    frame_id         TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
    epoch            INTEGER NOT NULL,
    parent_epoch     INTEGER NOT NULL,
    strategy         TEXT NOT NULL,
    kind             TEXT NOT NULL,
    before_tokens    INTEGER NOT NULL,
    after_tokens     INTEGER NOT NULL,
    first_seq        INTEGER NOT NULL,
    initial_head_seq INTEGER NOT NULL,
    checkpoint_seq   INTEGER,
    first_kept_seq   INTEGER,
    archive_ref      TEXT,
    ui_event_seq     INTEGER,
    created_at       INTEGER NOT NULL,
    PRIMARY KEY(frame_id, epoch)
);
CREATE INDEX IF NOT EXISTS ix_messages_frame_epoch_seq ON messages(frame_id, epoch, seq);

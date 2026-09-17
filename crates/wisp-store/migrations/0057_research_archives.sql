CREATE TABLE IF NOT EXISTS research_archives (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    frame_id TEXT NOT NULL UNIQUE REFERENCES frames(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    record_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    frozen_at INTEGER
);
CREATE INDEX IF NOT EXISTS ix_research_archives_project ON research_archives(project_id, frozen_at);
CREATE TRIGGER IF NOT EXISTS research_archive_frame_delete BEFORE DELETE ON frames
WHEN EXISTS (SELECT 1 FROM research_archives a WHERE a.frame_id=OLD.root_frame_id AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;
CREATE TABLE IF NOT EXISTS research_archive_continuations (
    frame_id TEXT PRIMARY KEY REFERENCES frames(id) ON DELETE CASCADE,
    archive_id TEXT NOT NULL REFERENCES research_archives(id) ON DELETE CASCADE
);
-- A frozen notebook cannot be rewritten by undo, compaction, import or a late writer.
CREATE TRIGGER IF NOT EXISTS research_archive_messages_insert BEFORE INSERT ON messages
WHEN EXISTS (SELECT 1 FROM research_archives a JOIN frames f ON f.root_frame_id=a.frame_id WHERE f.id=NEW.frame_id AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;
CREATE TRIGGER IF NOT EXISTS research_archive_events_insert BEFORE INSERT ON session_ui_events
WHEN EXISTS (SELECT 1 FROM research_archives a WHERE a.frame_id=NEW.frame_id AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;
CREATE TRIGGER IF NOT EXISTS research_archive_events_update BEFORE UPDATE ON session_ui_events
WHEN EXISTS (SELECT 1 FROM research_archives a WHERE (a.frame_id=OLD.frame_id OR a.frame_id=NEW.frame_id) AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;
CREATE TRIGGER IF NOT EXISTS research_archive_events_delete BEFORE DELETE ON session_ui_events
WHEN EXISTS (SELECT 1 FROM research_archives a WHERE a.frame_id=OLD.frame_id AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;
CREATE TRIGGER IF NOT EXISTS research_archive_messages_update BEFORE UPDATE ON messages
WHEN EXISTS (SELECT 1 FROM research_archives a JOIN frames f ON f.root_frame_id=a.frame_id WHERE (f.id=OLD.frame_id OR f.id=NEW.frame_id) AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;
CREATE TRIGGER IF NOT EXISTS research_archive_messages_delete BEFORE DELETE ON messages
WHEN EXISTS (SELECT 1 FROM research_archives a JOIN frames f ON f.root_frame_id=a.frame_id WHERE f.id=OLD.frame_id AND a.frozen_at IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'research_archive_read_only'); END;

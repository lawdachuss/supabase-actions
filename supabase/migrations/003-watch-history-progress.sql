-- Add progress tracking to watch_history
-- progress: 0-100 (percentage watched)
-- last_position_ms: resume position in milliseconds
-- total_watch_ms: total time spent watching this recording
ALTER TABLE watch_history
  ADD COLUMN IF NOT EXISTS progress integer DEFAULT 0 CHECK (progress >= 0 AND progress <= 100),
  ADD COLUMN IF NOT EXISTS last_position_ms bigint DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_watch_ms bigint DEFAULT 0;

-- Index for "continue watching" query (unfinished videos, sorted by most recent)
CREATE INDEX IF NOT EXISTS idx_watch_history_continue
  ON watch_history (user_id, watched_at DESC)
  WHERE progress < 100;

-- Index for stats queries
CREATE INDEX IF NOT EXISTS idx_watch_history_stats
  ON watch_history (user_id, progress, total_watch_ms);

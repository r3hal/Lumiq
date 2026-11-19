-- AI Shot learning: one row per AI Shot result. No images and no personal data:
-- `session` is a random id that lives only until the app closes.
CREATE TABLE IF NOT EXISTS shots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  session TEXT NOT NULL,
  model TEXT,
  technique TEXT,
  subject TEXT,
  ai_zoom REAL NOT NULL,
  start_zoom REAL,
  crop REAL,
  aspect REAL,
  outcome TEXT NOT NULL,
  reached_ready INTEGER NOT NULL DEFAULT 0,
  seconds_to_ready REAL,
  user_zoom REAL,
  app TEXT
);
CREATE INDEX IF NOT EXISTS shots_created ON shots (created_at);

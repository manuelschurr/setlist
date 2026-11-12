-- Setlist schema v1. Migration 0 -> 1 in lib/store.dart runs exactly these statements, then sets PRAGMA user_version = 1 in the same transaction.
-- Connection settings, applied on every open and not part of any migration: PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;
-- Units: weight in integer grams, distance in integer metres, time in integer seconds, logged_at in unix milliseconds. Days are TEXT 'YYYY-MM-DD'.

CREATE TABLE exercise (
  id            INTEGER PRIMARY KEY,
  name          TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  -- ExerciseKind.name in lib/day.dart. No CHECK: a new kind would then need a table rebuild. The store parses this column and rejects unknown values.
  kind          TEXT    NOT NULL,
  category      TEXT,
  weight_step_g INTEGER NOT NULL DEFAULT 2500 CHECK (weight_step_g > 0),
  rest_s        INTEGER NOT NULL DEFAULT 120 CHECK (rest_s >= 0),
  -- Stable id in an import source, such as 'fitnotes:42'. NULL for exercises created in the app. Lets a second import find the same exercise after a rename.
  import_key    TEXT    UNIQUE
);

-- One row per non-empty day. A day with no exercises and no note has no row.
CREATE TABLE workout (
  day  TEXT PRIMARY KEY CHECK (day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  note TEXT NOT NULL DEFAULT ''
) WITHOUT ROWID;

-- One exercise in a day. The primary key is the "an exercise at most once per day" rule.
CREATE TABLE workout_slot (
  day         TEXT    NOT NULL REFERENCES workout (day),
  exercise_id INTEGER NOT NULL REFERENCES exercise (id),
  position    INTEGER NOT NULL CHECK (position >= 0),
  PRIMARY KEY (day, exercise_id),
  UNIQUE (day, position)
) WITHOUT ROWID;

-- One set. Clustered by day, so loading or replacing a day reads or deletes one contiguous key range.
CREATE TABLE workout_set (
  day         TEXT    NOT NULL,
  exercise_id INTEGER NOT NULL,
  set_index   INTEGER NOT NULL CHECK (set_index >= 0),
  weight_g    INTEGER NOT NULL DEFAULT 0,
  reps        INTEGER NOT NULL DEFAULT 0 CHECK (reps >= 0),
  metres      INTEGER NOT NULL DEFAULT 0 CHECK (metres >= 0),
  seconds     INTEGER NOT NULL DEFAULT 0 CHECK (seconds >= 0),
  warmup      INTEGER NOT NULL DEFAULT 0 CHECK (warmup IN (0, 1)),
  done        INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
  -- NULL for planned sets, and for done sets imported without a time.
  logged_at   INTEGER CHECK (logged_at IS NULL OR done = 1),
  PRIMARY KEY (day, exercise_id, set_index),
  FOREIGN KEY (day, exercise_id) REFERENCES workout_slot (day, exercise_id)
) WITHOUT ROWID;

-- Previous-session lookup: MAX(day) for one exercise before a day, then that day's done sets in order. Also orders the exercise picker by last use. Partial, so planned sets copied ahead never count as a session.
CREATE INDEX set_done_by_exercise ON workout_set (exercise_id, day, set_index) WHERE done = 1;

-- Days the app has saved at least once, including days it later emptied and deleted. The importer never writes these days, so a re-import cannot overwrite or resurrect what the lifter changed in Setlist.
CREATE TABLE app_day (
  day TEXT PRIMARY KEY
) WITHOUT ROWID;

/// Nothing outside this file sees a table name, a column, a [Row] or a [SqliteException]. Callers get the domain types from day.dart and the import types declared here. Every method is synchronous; on the phone each one runs on the UI isolate in a few milliseconds, except an import, which runs on its own isolate with its own connection (see fitnotes.dart).
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'day.dart';

typedef ExerciseDefaults = ({int weightStepGrams, Duration rest});

final class Store {
  Store._(this._db, this.path);

  /// Opens or creates the database at [path], applies the connection settings and migrates it to the schema this build knows. Before migrating a file that already holds a schema, it copies the file to `<path>.v<from>.bak`. Throws [StoreTooNew] when the file was written by a newer build, before writing anything to it.
  factory Store.open(String path) => _connect(sqlite3.open(path), path);

  factory Store.inMemory() => _connect(sqlite3.openInMemory(), null);

  static Store _connect(Database db, String? path) {
    try {
      final found = db.userVersion;
      if (found > _migrations.length) throw StoreTooNew(found, _migrations.length);
      _configure(db);
      _migrate(db, path);
      return Store._(db, path);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final Database _db;

  final String? path;

  final Map<String, PreparedStatement> _statements = {};

  /// Statements are prepared on first use and kept, because the whole-day save runs after every stepper tap.
  PreparedStatement _sql(String sql) => _statements[sql] ??= _db.prepare(sql, persistent: true);

  Workout loadDay(Day day) => _assemble(_sql('$_selectDays WHERE w.day = ? ORDER BY sl.position, s.set_index').select([day.iso])).firstOrNull ?? Workout(day: day);

  /// Replaces everything the database holds for [workout.day] with [workout], in one transaction. Saving the same day twice leaves the same rows. An empty day is deleted. Also records the day in app_day, which hands it from the importer to the app for good.
  ///
  /// A failure throws [StoreWriteFailed] and leaves the previous rows in place; because the save is a whole-day replace, the next successful save converges with no repair step.
  void saveDay(Workout workout) {
    try {
      _inTransaction(_db, () {
        _replaceDay(workout.day, workout.note, [
          for (final entry in workout.entries) [for (final slot in entry.slots) (slot.exercise.id, slot.sets)],
        ]);
        _sql('INSERT INTO app_day (day) VALUES (?) ON CONFLICT DO NOTHING').execute([workout.day.iso]);
      });
    } on SqliteException catch (e) {
      throw StoreWriteFailed(e);
    }
  }

  /// The done sets of [exercise] on the most recent day before [before] on which any of its sets was done, in set order, notes included. Empty when it was never done. Planned sets never count, so a day copied ahead and not trained is skipped.
  List<SetEntry> lastSession(ExerciseId exercise, {required Day before}) {
    final rows = _sql('SELECT $_setColumns FROM workout_set s WHERE s.exercise_id = ?1 AND s.done = 1 AND s.day = (SELECT MAX(day) FROM workout_set WHERE exercise_id = ?1 AND done = 1 AND day < ?2) ORDER BY s.set_index').select([exercise.value, before.iso]);
    return [for (final row in rows) _set(row)];
  }

  List<({Day day, List<SetEntry> sets})> exerciseHistory(ExerciseId exercise, {int limit = 200}) {
    final rows = _sql('SELECT s.day, $_setColumns FROM workout_set s WHERE s.exercise_id = ?1 AND s.done = 1 AND s.day IN (SELECT DISTINCT day FROM workout_set WHERE exercise_id = ?1 AND done = 1 ORDER BY day DESC LIMIT ?2) ORDER BY s.day DESC, s.set_index').select([exercise.value, limit]);
    final sessions = <({Day day, List<SetEntry> sets})>[];
    for (final row in rows) {
      final day = Day.parse(row['day'] as String);
      if (sessions.lastOrNull?.day != day) sessions.add((day: day, sets: []));
      sessions.last.sets.add(_set(row));
    }
    return sessions;
  }

  List<Workout> recentWorkouts({Day? before, int limit = 30}) => _assemble(_sql('$_selectDays WHERE w.day IN (SELECT day FROM workout WHERE ?1 IS NULL OR day < ?1 ORDER BY day DESC LIMIT ?2) ORDER BY w.day DESC, sl.position, s.set_index').select([before?.iso, limit]));

  List<Exercise> exercises() {
    final rows = _sql('SELECT $_exerciseColumns FROM exercise e ORDER BY (SELECT MAX(day) FROM workout_set s WHERE s.exercise_id = e.id AND s.done = 1) DESC NULLS LAST, e.name').select();
    return [for (final row in rows) _exercise(row)];
  }

  ExerciseDefaults loadDefaults() {
    final values = {for (final row in _sql('SELECT key, value FROM setting').select()) row['key'] as String: row['value']};
    return (
      weightStepGrams: switch (values[_weightStepKey]) {
        final int grams when grams > 0 => grams,
        _ => 2500,
      },
      rest: Duration(
        seconds: switch (values[_restKey]) {
          final int seconds when seconds >= 0 => seconds,
          _ => 120,
        },
      ),
    );
  }

  /// Creates an exercise. A null [weightStepGrams] or [rest] takes the value from [loadDefaults]. Throws [DuplicateExerciseName] when another exercise has [name], ignoring case.
  Exercise createExercise({required String name, required ExerciseKind kind, String? category, int? weightStepGrams, Duration? rest, Equipment equipment = Equipment.none}) {
    final defaults = loadDefaults();
    final step = weightStepGrams ?? defaults.weightStepGrams;
    final restTime = rest ?? defaults.rest;
    final (equipmentName, barGrams, handleGrams) = _equipmentColumns(equipment);
    final id = _writeExercise(name, () => _sql('INSERT INTO exercise (name, kind, category, weight_step_g, rest_s, equipment, bar_g, handle_g) VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id').select([name, kind.name, category, step, restTime.inSeconds, equipmentName, barGrams, handleGrams]).single['id'] as int);
    return Exercise(id: ExerciseId(id), name: name, kind: kind, equipment: equipment, category: category, weightStepGrams: step, rest: restTime);
  }

  /// Saves name, kind, category, increment, rest and equipment for [exercise.id]. Throws [DuplicateExerciseName] like [createExercise]. Dispatch [UpdateExercise] afterwards so the open day shows the change.
  void updateExercise(Exercise exercise) {
    final (equipmentName, barGrams, handleGrams) = _equipmentColumns(exercise.equipment);
    _writeExercise(exercise.name, () => _sql('UPDATE exercise SET name = ?, kind = ?, category = ?, weight_step_g = ?, rest_s = ?, equipment = ?, bar_g = ?, handle_g = ? WHERE id = ?').execute([exercise.name, exercise.kind.name, exercise.category, exercise.weightStepGrams, exercise.rest.inSeconds, equipmentName, barGrams, handleGrams, exercise.id.value]));
  }

  T _writeExercise<T>(String name, T Function() write) {
    try {
      return write();
    } on SqliteException catch (e) {
      if (e.extendedResultCode == SqlExtendedError.SQLITE_CONSTRAINT_UNIQUE) throw DuplicateExerciseName(name);
      throw StoreWriteFailed(e);
    }
  }

  /// Writes an importer's output. Safe to run any number of times. Each run converges on the same rows, and a failure at any point leaves the database as it was before the run. Throws [ArgumentError] for a day that appears twice, an entry with no slots, a slot with no sets, or a slot whose exercise key is not in [ImportBatch.exercises], and [StoreWriteFailed] when SQLite refuses a row.
  ///
  /// The batch's defaults, when given, replace the stored ones first. Ownership decides who writes a day. The importer writes a day only if the app has never saved it (no app_day row); those days it replaces wholesale, so a newer backup refreshes them. Days the app has saved are skipped and listed in [ImportReport.skippedDays]. Exercises are matched by import key, then by name ignoring case, then created; a matched exercise keeps the lifter's own name, increment, rest, equipment and bar weight. No source tells the equipment, so a created exercise has none. A created exercise whose name is taken by one with another import key gets the source appended, as in `Squat (fitnotes)`.
  ImportReport importBatch(ImportBatch batch) {
    try {
      return _inTransaction(_db, () {
        _putSetting(_weightStepKey, batch.defaultWeightStepGrams);
        _putSetting(_restKey, batch.defaultRest?.inSeconds);
        final defaults = loadDefaults();
        final ids = <String, ExerciseId>{};
        var created = 0;
        for (final e in batch.exercises) {
          final key = '${batch.source}:${e.key}';
          final found = _sql('SELECT id FROM exercise WHERE import_key = ?').select([key]).firstOrNull ?? _sql('UPDATE exercise SET import_key = ?1 WHERE name = ?2 AND import_key IS NULL RETURNING id').select([key, e.name]).firstOrNull;
          if (found == null) created++;
          ids[e.key] = ExerciseId((found ?? _sql('INSERT INTO exercise (name, kind, category, weight_step_g, rest_s, import_key) VALUES (?, ?, ?, ?, ?, ?) RETURNING id').select([_freeName(e.name, batch.source), e.kind.name, e.category, e.weightStepGrams ?? defaults.weightStepGrams, (e.rest ?? defaults.rest).inSeconds, key]).single)['id'] as int);
        }
        final skipped = <Day>[];
        var daysWritten = 0;
        var setsWritten = 0;
        final seen = <Day>{};
        for (final d in batch.days) {
          if (!seen.add(d.day)) throw ArgumentError.value(d.day.iso, 'days', 'an import batch holds each day at most once');
          if (_sql('SELECT 1 FROM app_day WHERE day = ?').select([d.day.iso]).isNotEmpty) {
            skipped.add(d.day);
            continue;
          }
          final entries = <List<(ExerciseId, List<SetEntry>)>>[];
          for (final entry in d.entries) {
            if (entry.isEmpty) throw ArgumentError.value(d.day.iso, 'entries', 'an imported entry holds at least one slot');
            entries.add([]);
            for (final s in entry) {
              final id = ids[s.exerciseKey];
              if (id == null || s.sets.isEmpty) throw ArgumentError.value(s.exerciseKey, 'entries', 'an imported slot needs an exercise from the batch and at least one set');
              entries.last.add((id, s.sets));
            }
          }
          setsWritten += _replaceDay(d.day, d.note, entries);
          daysWritten++;
        }
        return ImportReport(exercisesCreated: created, exercisesLinked: batch.exercises.length - created, daysWritten: daysWritten, setsWritten: setsWritten, skippedDays: skipped);
      });
    } on SqliteException catch (e) {
      throw StoreWriteFailed(e);
    }
  }

  /// Writes a consistent copy of the whole database to [destination] with `VACUUM INTO`, replacing any file already there. The importer calls it before writing, and the export action shares the same file. Throws [StoreWriteFailed] when SQLite or the file system refuses the copy.
  void copyTo(String destination) {
    try {
      _vacuumInto(_db, destination);
    } on SqliteException catch (e) {
      throw StoreWriteFailed(e);
    } on FileSystemException catch (e) {
      throw StoreWriteFailed(e);
    }
  }

  /// Restores a copy made by [copyTo]: moves [backupPath] over the database at [dbPath]. Close every store on [dbPath] first and open a new one after, which migrates an older copy. Throws [NotASetlistBackup] and changes nothing when [backupPath] is not a Setlist database this build can open. Otherwise copies the current database to `<dbPath>.before-restore-<unix ms>` and removes its `-wal` and `-shm` files, because SQLite would replay a leftover log onto the restored file.
  static void replaceWith(String backupPath, {required String dbPath}) {
    _checkSetlistFile(backupPath);
    if (File(dbPath).existsSync()) {
      final current = sqlite3.open(dbPath);
      try {
        _vacuumInto(current, '$dbPath.before-restore-${DateTime.now().millisecondsSinceEpoch}');
      } finally {
        current.close();
      }
    }
    for (final leftover in [File('$dbPath-wal'), File('$dbPath-shm')]) {
      if (leftover.existsSync()) leftover.deleteSync();
    }
    File(backupPath).renameSync(dbPath);
  }

  static void _checkSetlistFile(String path) {
    const notSetlist = 'This file is not a Setlist backup. Pick a backup that Setlist exported.';
    final Database db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
    } on SqliteException {
      throw const NotASetlistBackup(notSetlist);
    }
    try {
      final version = db.userVersion;
      final tables = {for (final row in db.select("SELECT name FROM sqlite_master WHERE type = 'table'")) row['name'] as String};
      if (version == 0 || !tables.containsAll(_setlistTables)) throw const NotASetlistBackup(notSetlist);
      if (version > _migrations.length) throw const NotASetlistBackup('This backup was made by a newer version of Setlist. Update the app, then restore it.');
      if (db.select('PRAGMA quick_check').first.values.first != 'ok') throw const NotASetlistBackup('This Setlist backup is damaged and cannot be restored.');
    } on SqliteException {
      throw const NotASetlistBackup(notSetlist);
    } finally {
      db.close();
    }
  }

  void close() {
    for (final statement in _statements.values) {
      statement.close();
    }
    _db.close();
  }

  /// Deletes the day's rows and inserts the given ones, children first so the foreign keys hold at every statement. [entries] holds one list of slots per entry, and every slot after the first of its entry is written joined. A day with no slots and no note keeps no row. Returns the number of sets written. The caller owns the transaction.
  int _replaceDay(Day day, String note, List<List<(ExerciseId, List<SetEntry>)>> entries) {
    final d = day.iso;
    _sql('DELETE FROM workout_set WHERE day = ?').execute([d]);
    _sql('DELETE FROM workout_slot WHERE day = ?').execute([d]);
    _sql('DELETE FROM workout WHERE day = ?').execute([d]);
    if (entries.isEmpty && note.isEmpty) return 0;
    _sql('INSERT INTO workout (day, note) VALUES (?, ?)').execute([d, note]);
    var written = 0;
    var position = 0;
    for (final entry in entries) {
      for (final (i, (exercise, sets)) in entry.indexed) {
        _sql('INSERT INTO workout_slot (day, exercise_id, position, joined) VALUES (?, ?, ?, ?)').execute([d, exercise.value, position++, i > 0 ? 1 : 0]);
        for (final (index, s) in sets.indexed) {
          final loggedAt = switch (s.status) {
            Done(:final at) => at?.millisecondsSinceEpoch,
            Planned() => null,
          };
          _sql('INSERT INTO workout_set (day, exercise_id, set_index, weight_g, reps, metres, seconds, warmup, done, logged_at, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)').execute([d, exercise.value, index, s.grams, s.reps, s.metres, s.seconds, s.warmup ? 1 : 0, s.isDone ? 1 : 0, loggedAt, s.note]);
          written++;
        }
      }
    }
    return written;
  }

  void _putSetting(String key, int? value) {
    if (value == null) return;
    _sql('INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value').execute([key, value]);
  }

  String _freeName(String name, String source) {
    for (var n = 1;; n++) {
      final candidate = switch (n) {
        1 => name,
        2 => '$name ($source)',
        _ => '$name ($source ${n - 1})',
      };
      if (_sql('SELECT 1 FROM exercise WHERE name = ?').select([candidate]).isEmpty) return candidate;
    }
  }
}

/// Tables every Setlist database has had since v1. A migration that drops one removes it here.
const _setlistTables = {'exercise', 'workout', 'workout_slot', 'workout_set', 'app_day', 'setting'};

const _weightStepKey = 'default_weight_step_g';
const _restKey = 'default_rest_s';

const _exerciseColumns = 'e.id, e.name, e.kind, e.category, e.weight_step_g, e.rest_s, e.equipment, e.bar_g, e.handle_g';
const _setColumns = 's.weight_g, s.reps, s.metres, s.seconds, s.warmup, s.done, s.logged_at, s.note AS set_note';

const _selectDays = 'SELECT w.day, w.note AS day_note, sl.joined, $_exerciseColumns, $_setColumns FROM workout w LEFT JOIN workout_slot sl ON sl.day = w.day LEFT JOIN exercise e ON e.id = sl.exercise_id LEFT JOIN workout_set s ON s.day = sl.day AND s.exercise_id = sl.exercise_id';

/// Folds [_selectDays] rows, already in day, position and set order, into workouts. A joined slot goes into the entry of the slot before it. Rows parse through the validating [Day], [Slot], [Superset] and [Workout] constructors, so a corrupt row fails here with an error instead of reaching a screen.
List<Workout> _assemble(ResultSet rows) {
  final days = <String, ({String note, Map<int, (Exercise, bool, List<SetEntry>)> slots})>{};
  for (final row in rows) {
    final day = days.putIfAbsent(row['day'] as String, () => (note: row['day_note'] as String, slots: {}));
    final id = row['id'] as int?;
    if (id == null) continue;
    final (_, _, sets) = day.slots.putIfAbsent(id, () => (_exercise(row), row['joined'] == 1, []));
    if (row['done'] != null) sets.add(_set(row));
  }
  return [
    for (final MapEntry(key: day, value: (:note, :slots)) in days.entries) Workout(day: Day.parse(day), note: note, entries: _entries(slots.values)),
  ];
}

List<Entry> _entries(Iterable<(Exercise, bool, List<SetEntry>)> slots) {
  final groups = <List<Slot>>[];
  for (final (exercise, joined, sets) in slots) {
    joined ? groups.last.add(Slot(exercise, sets)) : groups.add([Slot(exercise, sets)]);
  }
  return [for (final group in groups) group.length == 1 ? group.single : Superset(group)];
}

Exercise _exercise(Row row) => Exercise(id: ExerciseId(row['id'] as int), name: row['name'] as String, kind: ExerciseKind.values.byName(row['kind'] as String), equipment: Equipment.named(row['equipment'] as String, barGrams: row['bar_g'] as int?, handleGrams: row['handle_g'] as int?), category: row['category'] as String?, weightStepGrams: row['weight_step_g'] as int, rest: Duration(seconds: row['rest_s'] as int));

(String, int?, int?) _equipmentColumns(Equipment equipment) => switch (equipment) {
  Barbell(:final barGrams) => (equipment.name, barGrams, null),
  Dumbbell(:final handleGrams) => (equipment.name, null, handleGrams),
  NoEquipment() => (equipment.name, null, null),
};

SetEntry _set(Row row) {
  final loggedAt = row['logged_at'] as int?;
  return SetEntry(grams: row['weight_g'] as int, reps: row['reps'] as int, metres: row['metres'] as int, seconds: row['seconds'] as int, warmup: row['warmup'] == 1, note: row['set_note'] as String, status: row['done'] == 1 ? Done(loggedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(loggedAt)) : const Planned());
}

T _inTransaction<T>(Database db, T Function() body) {
  db.execute('BEGIN IMMEDIATE');
  try {
    final result = body();
    db.execute('COMMIT');
    return result;
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}

/// Writes a copy to a side file and renames it over [destination], so a crash mid-copy never leaves a truncated file under the real name.
void _vacuumInto(Database db, String destination) {
  final partial = File('$destination.partial');
  if (partial.existsSync()) partial.deleteSync();
  db.execute('VACUUM INTO ?', [partial.path]);
  partial.renameSync(destination);
}

/// Applies the per-connection settings. WAL lets the import isolate write while the UI connection reads; synchronous = NORMAL drops the fsync per commit, which matters when every stepper tap commits.
void _configure(Database db) => db.execute('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;');

/// Append-only. Entry i moves the schema from user_version i to i + 1. A shipped entry is never edited; a change is a new entry. docs/schema.sql is generated from a database these build, and test/store_test.dart fails when the two differ.
///
/// Comments that document the schema sit inside each statement, because SQLite keeps a statement's text in sqlite_master and drops anything between statements.
const List<String> _migrations = [_v1, _v2, _v3, _v4];

const String _v1 = r'''
CREATE TABLE exercise (
  id            INTEGER PRIMARY KEY,
  name          TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  -- ExerciseKind.name in lib/day.dart. No CHECK, so a new kind needs no table rebuild; the store parses this column and rejects unknown values.
  kind          TEXT    NOT NULL,
  category      TEXT,
  -- No defaults here: the store always writes them, from the caller or from the setting table.
  weight_step_g INTEGER NOT NULL CHECK (weight_step_g > 0),
  rest_s        INTEGER NOT NULL CHECK (rest_s >= 0),
  -- Stable id in an import source, such as 'fitnotes:42'. NULL for exercises created in the app. Lets a second import find the same exercise after a rename.
  import_key    TEXT    UNIQUE
) STRICT;

CREATE TABLE workout (
  -- One row per non-empty day, keyed by 'YYYY-MM-DD'. A day with no exercises and no note has no row.
  day  TEXT PRIMARY KEY CHECK (day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  note TEXT NOT NULL DEFAULT ''
) STRICT, WITHOUT ROWID;

CREATE TABLE workout_slot (
  -- One exercise in a day. The primary key is the "an exercise at most once per day" rule.
  day         TEXT    NOT NULL REFERENCES workout (day),
  exercise_id INTEGER NOT NULL REFERENCES exercise (id),
  position    INTEGER NOT NULL CHECK (position >= 0),
  PRIMARY KEY (day, exercise_id),
  UNIQUE (day, position)
) STRICT, WITHOUT ROWID;

CREATE INDEX slot_by_exercise ON workout_slot (
  -- Serves the foreign key from exercise, so changing or deleting an exercise does not scan every slot.
  exercise_id
);

CREATE TABLE workout_set (
  -- One set. Clustered by day, so loading or replacing a day reads or deletes one contiguous key range. Units: grams, metres, seconds, and logged_at in unix milliseconds.
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
  note        TEXT    NOT NULL DEFAULT '',
  PRIMARY KEY (day, exercise_id, set_index),
  FOREIGN KEY (day, exercise_id) REFERENCES workout_slot (day, exercise_id)
) STRICT, WITHOUT ROWID;

CREATE INDEX set_done_by_exercise ON workout_set (
  -- Previous-session lookup and the picker's recent-first order: MAX(day) for one exercise, then that day's done sets in order. Partial, so planned sets copied ahead never count as a session.
  exercise_id, day, set_index
) WHERE done = 1;

CREATE TABLE app_day (
  -- Days the app has saved at least once, including days it later emptied and deleted. The importer never writes these days, so a re-import cannot overwrite or resurrect what the lifter changed in Setlist.
  day TEXT PRIMARY KEY
) STRICT, WITHOUT ROWID;

CREATE TABLE setting (
  -- Global defaults for new exercises: default_weight_step_g in grams and default_rest_s in seconds. The FitNotes import writes the owner's values here.
  key   TEXT PRIMARY KEY,
  value ANY  NOT NULL
) STRICT, WITHOUT ROWID;
''';

/// Adds `workout_slot.joined` by building the table again. SQLite's ADD COLUMN would splice the column onto the line of `position` and drop a comment placed before it, renaming the old table away would point workout_set's foreign key at the old name, and renaming a new table into place would store its name quoted. So a temporary copy holds the rows while the table is created with exactly this text, whatever SQLite version runs it.
const String _v2 = r'''
CREATE TEMP TABLE slot_v1 AS SELECT day, exercise_id, position FROM workout_slot;

DROP TABLE workout_slot;

CREATE TABLE workout_slot (
  -- One exercise in a day. The primary key is the "an exercise at most once per day" rule.
  day         TEXT    NOT NULL REFERENCES workout (day),
  exercise_id INTEGER NOT NULL REFERENCES exercise (id),
  position    INTEGER NOT NULL CHECK (position >= 0),
  -- 1 when this slot is in the same superset as the slot before it in position order, so a superset is a slot with 0 and the run of 1s after it, and a superset of one or one whose exercises are apart cannot be stored. The first slot of a day, at position 0, is never joined.
  joined      INTEGER NOT NULL DEFAULT 0 CHECK (joined IN (0, 1)) CHECK (joined = 0 OR position > 0),
  PRIMARY KEY (day, exercise_id),
  UNIQUE (day, position)
) STRICT, WITHOUT ROWID;

INSERT INTO workout_slot (day, exercise_id, position) SELECT day, exercise_id, position FROM slot_v1;

DROP TABLE slot_v1;

CREATE INDEX slot_by_exercise ON workout_slot (
  -- Serves the foreign key from exercise, so changing or deleting an exercise does not scan every slot.
  exercise_id
);
''';

/// Adds `exercise.equipment` and `exercise.bar_g` by building the table again, for the reasons [_v2] gives.
const String _v3 = r'''
CREATE TEMP TABLE exercise_v2 AS SELECT id, name, kind, category, weight_step_g, rest_s, import_key FROM exercise;

DROP TABLE exercise;

CREATE TABLE exercise (
  id            INTEGER PRIMARY KEY,
  name          TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  -- ExerciseKind.name in lib/day.dart. No CHECK, so a new kind needs no table rebuild; the store parses this column and rejects unknown values.
  kind          TEXT    NOT NULL,
  category      TEXT,
  -- No defaults here: the store always writes them, from the caller or from the setting table.
  weight_step_g INTEGER NOT NULL CHECK (weight_step_g > 0),
  rest_s        INTEGER NOT NULL CHECK (rest_s >= 0),
  -- Stable id in an import source, such as 'fitnotes:42'. NULL for exercises created in the app. Lets a second import find the same exercise after a rename.
  import_key    TEXT    UNIQUE,
  -- Equipment.name in lib/day.dart: what the logged total is lifted with, for the marker and the panel's breakdown. No CHECK on the names, like kind. The default is what an import writes, because no source tells the equipment.
  equipment     TEXT    NOT NULL DEFAULT 'none',
  -- Grams of the bar, set exactly when equipment is 'barbell'. Per exercise, because an EZ bar is lighter than a squat bar.
  bar_g         INTEGER CHECK (bar_g > 0) CHECK ((bar_g IS NOT NULL) = (equipment = 'barbell'))
) STRICT;

INSERT INTO exercise (id, name, kind, category, weight_step_g, rest_s, import_key) SELECT id, name, kind, category, weight_step_g, rest_s, import_key FROM exercise_v2;

DROP TABLE exercise_v2;
''';

/// Adds `exercise.handle_g` by building the table again, for the reasons [_v2] gives.
const String _v4 = r'''
CREATE TEMP TABLE exercise_v3 AS SELECT id, name, kind, category, weight_step_g, rest_s, import_key, equipment, bar_g FROM exercise;

DROP TABLE exercise;

CREATE TABLE exercise (
  id            INTEGER PRIMARY KEY,
  name          TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  -- ExerciseKind.name in lib/day.dart. No CHECK, so a new kind needs no table rebuild; the store parses this column and rejects unknown values.
  kind          TEXT    NOT NULL,
  category      TEXT,
  -- No defaults here: the store always writes them, from the caller or from the setting table.
  weight_step_g INTEGER NOT NULL CHECK (weight_step_g > 0),
  rest_s        INTEGER NOT NULL CHECK (rest_s >= 0),
  -- Stable id in an import source, such as 'fitnotes:42'. NULL for exercises created in the app. Lets a second import find the same exercise after a rename.
  import_key    TEXT    UNIQUE,
  -- Equipment.name in lib/day.dart: what the logged total is lifted with, for the marker and the panel's breakdown. No CHECK on the names, like kind. The default is what an import writes, because no source tells the equipment.
  equipment     TEXT    NOT NULL DEFAULT 'none',
  -- Grams of the bar, set exactly when equipment is 'barbell'. Per exercise, because an EZ bar is lighter than a squat bar.
  bar_g         INTEGER CHECK (bar_g > 0) CHECK ((bar_g IS NOT NULL) = (equipment = 'barbell')),
  -- Grams of an adjustable dumbbell's empty handle, which the plates go on. Only for 'dumbbellPair' and 'oneDumbbell', and NULL for fixed dumbbells. Per exercise, because a home set and a gym's differ.
  handle_g      INTEGER CHECK (handle_g > 0) CHECK (handle_g IS NULL OR equipment IN ('dumbbellPair', 'oneDumbbell'))
) STRICT;

INSERT INTO exercise (id, name, kind, category, weight_step_g, rest_s, import_key, equipment, bar_g) SELECT id, name, kind, category, weight_step_g, rest_s, import_key, equipment, bar_g FROM exercise_v3;

DROP TABLE exercise_v3;
''';

/// Brings [db] to `_migrations.length`. Each step is one transaction that includes the user_version bump, and user_version lives in the database header, so it rolls back with the step. A crash mid-migration therefore leaves the old version, and the next launch reruns that step from the start.
void _migrate(Database db, String? path) {
  final from = db.userVersion;
  if (from == _migrations.length) return;
  if (path != null && db.select('SELECT 1 FROM sqlite_master LIMIT 1').isNotEmpty) _vacuumInto(db, '$path.v$from.bak');
  // Must be outside a transaction, where SQLite ignores it. Later steps may rebuild tables with SQLite's 12-step ALTER, which needs it off.
  db.execute('PRAGMA foreign_keys = OFF');
  try {
    for (var version = from; version < _migrations.length; version++) {
      _inTransaction(db, () {
        db.execute(_migrations[version]);
        final broken = db.select('PRAGMA foreign_key_check');
        if (broken.isNotEmpty) throw StateError('migration to v${version + 1} breaks a foreign key: ${broken.first}');
        db.userVersion = version + 1;
      });
    }
  } finally {
    db.execute('PRAGMA foreign_keys = ON');
  }
}

final class ImportBatch {
  const ImportBatch({required this.source, required this.exercises, required this.days, this.defaultWeightStepGrams, this.defaultRest});

  /// Names the source, such as `fitnotes`. Prefixes every exercise key in the database.
  final String source;
  final List<ImportedExercise> exercises;

  /// At most one per day. A day may hold only a note.
  final List<ImportedDay> days;

  /// The source's global increment and rest, which the import writes as Setlist's defaults. Null leaves the stored default as it is.
  final int? defaultWeightStepGrams;
  final Duration? defaultRest;
}

final class ImportedExercise {
  const ImportedExercise({required this.key, required this.name, required this.kind, this.category, this.weightStepGrams, this.rest});

  /// The exercise's stable id in the source, such as FitNotes' exercise._id as text.
  final String key;
  final String name;
  final ExerciseKind kind;
  final String? category;

  /// Null takes the default, after the batch's own defaults are applied. Only used when the import creates the exercise.
  final int? weightStepGrams;
  final Duration? rest;
}

final class ImportedDay {
  const ImportedDay({required this.day, this.note = '', this.entries = const []});

  final Day day;
  final String note;

  /// In workout order, one list per entry: one slot is a plain exercise, two or more a superset in round order. Each exercise key at most once in the day, and each slot with at least one set.
  final List<List<ImportedSlot>> entries;
}

typedef ImportedSlot = ({String exerciseKey, List<SetEntry> sets});

final class ImportReport {
  const ImportReport({required this.exercisesCreated, required this.exercisesLinked, required this.daysWritten, required this.setsWritten, required this.skippedDays});

  final int exercisesCreated;

  final int exercisesLinked;
  final int daysWritten;
  final int setsWritten;

  final List<Day> skippedDays;
}

final class StoreTooNew implements Exception {
  const StoreTooNew(this.found, this.known);
  final int found;
  final int known;

  @override
  String toString() => 'StoreTooNew: the database is at schema version $found, and this build knows up to $known';
}

final class DuplicateExerciseName implements Exception {
  const DuplicateExerciseName(this.name);
  final String name;

  @override
  String toString() => 'DuplicateExerciseName: $name';
}

/// The file picked for a restore is not a Setlist database this build can open. [message] is shown to the lifter as is.
final class NotASetlistBackup implements Exception {
  const NotASetlistBackup(this.message);
  final String message;

  @override
  String toString() => 'NotASetlistBackup: $message';
}

final class StoreWriteFailed implements Exception {
  const StoreWriteFailed(this.cause);
  final Object cause;

  @override
  String toString() => 'StoreWriteFailed: $cause';
}

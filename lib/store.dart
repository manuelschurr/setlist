/// Everything about the SQLite file: the schema and its migrations, the queries, the whole-day save, and the import policy.
///
/// Nothing outside this file sees a table name, a column, a [Row] or a [SqliteException]. Callers get the domain types from day.dart and the import types declared here. Every method is synchronous; on the phone each one runs on the UI isolate in a few milliseconds, except an import, which runs on its own isolate with its own connection (see fitnotes.dart).
library;

import 'package:sqlite3/sqlite3.dart';

import 'day.dart';

final class Store {
  Store._(this._db, this.path);

  /// Opens or creates the database at [path], applies the connection settings and migrates it to the schema this build knows. Throws [StoreTooNew] when the file was written by a newer build, instead of writing to a schema it does not understand.
  factory Store.open(String path) {
    final db = sqlite3.open(path);
    _configure(db);
    _migrate(db);
    return Store._(db, path);
  }

  /// A migrated in-memory database, for tests on the VPS.
  factory Store.inMemory() {
    final db = sqlite3.openInMemory();
    _configure(db);
    _migrate(db);
    return Store._(db, null);
  }

  final Database _db;

  /// The file this store writes, so the importer can open its own connection on another isolate. Null for [Store.inMemory].
  final String? path;

  /// The day as saved, or an empty [Workout] for a day with no row. Slots come back in position order and sets in index order. Each slot carries the exercise as it is now, joined from the exercise table.
  Workout loadDay(Day day) {
    // TODO: one SELECT over workout LEFT JOIN workout_slot JOIN exercise LEFT JOIN workout_set WHERE workout.day = ? ORDER BY position, set_index, folded into slots by _assemble.
    throw UnimplementedError();
  }

  /// Replaces everything the database holds for [workout.day] with [workout], in one transaction. Saving the same day twice leaves the same rows. An empty day is deleted. Also records the day in app_day, which hands it from the importer to the app for good.
  ///
  /// Runs after every change on the workout screen, so its statements are prepared once and kept. A failure throws [StoreWriteFailed] and leaves the previous rows in place; because the save is a whole-day replace, the next successful save converges with no repair step.
  void saveDay(Workout workout) {
    // TODO(save-day):
    //   BEGIN IMMEDIATE
    //   DELETE FROM workout_set  WHERE day = ?1
    //   DELETE FROM workout_slot WHERE day = ?1
    //   DELETE FROM workout      WHERE day = ?1          (children first, so foreign keys hold at every statement)
    //   INSERT OR IGNORE INTO app_day (day) VALUES (?1)
    //   if (!workout.isEmpty):
    //     INSERT INTO workout (day, note)
    //     for (position, slot) in workout.slots:
    //       INSERT INTO workout_slot (day, exercise_id, position)
    //       for (i, s) in slot.sets:
    //         INSERT INTO workout_set (day, exercise_id, set_index, weight_g, reps, metres, seconds, warmup, done, logged_at)
    //           with done = s.status is Done, logged_at = (s.status as Done?)?.at?.millisecondsSinceEpoch
    //   COMMIT; on any error ROLLBACK and throw StoreWriteFailed(cause)
    throw UnimplementedError();
  }

  /// The done sets of [exercise] on the most recent day before [before] on which any of its sets was done, in set order. Empty when it was never done. Planned sets never count, so a day copied ahead and not trained is skipped.
  ///
  /// Index i of the result is what the lifter did "last time" on set i, and [AddExercise] copies the whole list as the new plan, so the muted text under a freshly added set always shows the set it was copied from.
  List<SetEntry> lastSession(ExerciseId exercise, {required Day before}) {
    // TODO(last-session): the MAX(day) subquery is one seek on the covering index set_done_by_exercise; the outer query is a primary-key range (day, exercise_id), already in set_index order. No scan, no sort (EXPLAIN QUERY PLAN on SQLite 3.46).
    //   SELECT weight_g, reps, metres, seconds, warmup, logged_at FROM workout_set
    //   WHERE exercise_id = ?1 AND done = 1
    //     AND day = (SELECT MAX(day) FROM workout_set WHERE exercise_id = ?1 AND done = 1 AND day < ?2)
    //   ORDER BY set_index
    //   -> SetEntry(..., status: Done(logged_at == null ? null : DateTime.fromMillisecondsSinceEpoch(logged_at)))
    throw UnimplementedError();
  }

  /// Saved days before [before] (all days when null), newest first, at most [limit]. Feeds the history list and the empty day's "Copy" list, which therefore show the same thing. Page by passing the last day of the previous page.
  List<Workout> recentWorkouts({Day? before, int limit = 30}) {
    // TODO: the loadDay query with `WHERE workout.day IN (SELECT day FROM workout WHERE day < ?1 ORDER BY day DESC LIMIT ?2)` and `ORDER BY workout.day DESC, position, set_index`, folded by _assemble.
    throw UnimplementedError();
  }

  /// Every exercise, most recently done first, then never-done ones by name. The picker filters this list in memory.
  List<Exercise> exercises() {
    // TODO:
    //   SELECT e.*, (SELECT MAX(day) FROM workout_set s WHERE s.exercise_id = e.id AND s.done = 1) AS last_day
    //   FROM exercise e ORDER BY last_day DESC NULLS LAST, e.name
    throw UnimplementedError();
  }

  /// Throws [DuplicateExerciseName] when another exercise has [name], ignoring case.
  Exercise createExercise({required String name, required ExerciseKind kind, String? category, int weightStepGrams = 2500, Duration rest = const Duration(minutes: 2)}) => throw UnimplementedError();

  /// Saves name, kind, category, increment and rest for [exercise.id]. Throws [DuplicateExerciseName] like [createExercise].
  void updateExercise(Exercise exercise) => throw UnimplementedError();

  /// Writes an importer's output. Safe to run any number of times. Each run converges on the same rows, and a crash at any point leaves the database as it was before the run.
  ///
  /// Ownership decides who writes a day. The importer writes a day only if the app has never saved it (no app_day row); those days it replaces wholesale, so a newer backup refreshes them. Days the app has saved are skipped and listed in [ImportReport.skippedDays]. Exercises are matched by import key, then by name ignoring case, then created; a matched exercise keeps the lifter's own name, increment and rest.
  ImportReport importBatch(ImportBatch batch) {
    // TODO(import): one transaction, BEGIN IMMEDIATE ... COMMIT, ROLLBACK and rethrow on error.
    //   ids = <String, ExerciseId>{}
    //   for e in batch.exercises:
    //     key = '${batch.source}:${e.key}'
    //     ids[e.key] = SELECT id FROM exercise WHERE import_key = key                                   -> linked, untouched
    //               ?? UPDATE exercise SET import_key = key WHERE name = e.name AND import_key IS NULL RETURNING id   -> linked
    //               ?? INSERT INTO exercise (name, kind, category, weight_step_g, rest_s, import_key) RETURNING id   -> created
    //     (a name taken by an exercise with another import key gets ' (${batch.source})' appended before the insert)
    //   for d in batch.days:
    //     if (EXISTS app_day WHERE day = d.day) { skipped.add(d.day); continue }
    //     DELETE the day's sets, slots and workout row, then INSERT them as saveDay does, with ids[slot.exerciseKey]
    //     (no app_day row: the day stays the importer's until the lifter edits it)
    //   return ImportReport(...counts...)
    throw UnimplementedError();
  }

  /// Writes a consistent copy of the whole database to [destination] with `VACUUM INTO`. The importer calls it before writing; a later "export backup" action can share the same file.
  void copyTo(String destination) => throw UnimplementedError();

  void close() => _db.close();
}

/// Applies the per-connection settings. WAL lets the import isolate write while the UI connection reads; synchronous = NORMAL drops the fsync per commit, which matters when every stepper tap commits.
void _configure(Database db) => db.execute('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;');

/// Append-only. Entry i moves the schema from user_version i to i + 1. A shipped entry is never edited; a change is a new entry. test/store_test.dart migrates an empty database and compares sqlite_master with schema.sql, so an edit to an old entry or a missing new one fails the build.
const List<String> _migrations = [
  // v1: the statements of schema.sql, verbatim.
  _v1,
];

const String _v1 = 'TODO: CREATE TABLE exercise ...; CREATE TABLE workout ...; CREATE TABLE workout_slot ...; CREATE TABLE workout_set ...; CREATE INDEX set_done_by_exercise ...; CREATE TABLE app_day ...;';

/// Brings [db] to `_migrations.length`. Each step is one transaction that includes the user_version bump, and user_version lives in the database header, so it rolls back with the step. A crash mid-migration therefore leaves the old version, and the next launch reruns that step from the start.
void _migrate(Database db) {
  // TODO(migrate):
  //   current = db.userVersion
  //   if (current > _migrations.length) throw StoreTooNew(current, _migrations.length)
  //   if (current == _migrations.length) return
  //   db.execute('PRAGMA foreign_keys = OFF')    // must be outside a transaction; later migrations may rebuild tables (SQLite's 12-step ALTER)
  //   for v in current ..< _migrations.length:
  //     BEGIN IMMEDIATE
  //     db.execute(_migrations[v])
  //     require `PRAGMA foreign_key_check` returns no rows
  //     db.userVersion = v + 1
  //     COMMIT; on error ROLLBACK, turn foreign keys back on, rethrow
  //   db.execute('PRAGMA foreign_keys = ON')
  throw UnimplementedError();
}

/// What an importer hands to [Store.importBatch]. It holds domain values only, keyed by the source's own exercise ids. No source rows and no Setlist ids cross this boundary.
final class ImportBatch {
  const ImportBatch({required this.source, required this.exercises, required this.days});

  /// Names the source, such as `fitnotes`. Prefixes every exercise key in the database.
  final String source;
  final List<ImportedExercise> exercises;

  /// At most one per day. A day may hold only a note.
  final List<ImportedDay> days;
}

final class ImportedExercise {
  const ImportedExercise({required this.key, required this.name, required this.kind, this.category, this.weightStepGrams = 2500, this.rest = const Duration(minutes: 2)});

  /// The exercise's stable id in the source, such as FitNotes' exercise._id as text.
  final String key;
  final String name;
  final ExerciseKind kind;
  final String? category;
  final int weightStepGrams;
  final Duration rest;
}

final class ImportedDay {
  const ImportedDay({required this.day, this.note = '', this.slots = const []});

  final Day day;
  final String note;

  /// In workout order; each exercise key at most once.
  final List<ImportedSlot> slots;
}

typedef ImportedSlot = ({String exerciseKey, List<SetEntry> sets});

final class ImportReport {
  const ImportReport({required this.exercisesCreated, required this.exercisesLinked, required this.daysWritten, required this.setsWritten, required this.skippedDays});

  final int exercisesCreated;
  final int exercisesLinked;
  final int daysWritten;
  final int setsWritten;

  /// Days the app had saved, which the import left alone.
  final List<Day> skippedDays;
}

final class StoreTooNew implements Exception {
  const StoreTooNew(this.found, this.known);
  final int found;
  final int known;
}

final class DuplicateExerciseName implements Exception {
  const DuplicateExerciseName(this.name);
  final String name;
}

final class StoreWriteFailed implements Exception {
  const StoreWriteFailed(this.cause);
  final Object cause;
}

/// This file knows FitNotes' tables and conventions (docs/research.md, Q1) and nothing about Setlist's schema, which stays behind [Store.importBatch]. The only thing it hands over is domain values.
library;

import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import 'day.dart';
import 'store.dart';

/// What one import did, for the dialog after it. On a fresh database `written.setsWritten == trainingLogRows`, which is the import check in docs/design.md.
typedef ImportOutcome = ({int trainingLogRows, Map<String, int> leftOut, ImportReport written});

/// The picked file is not a FitNotes backup this importer understands. [message] is shown to the lifter as is.
final class FitNotesFormatError implements Exception {
  const FitNotesFormatError(this.message);
  final String message;

  @override
  String toString() => 'FitNotesFormatError: $message';
}

/// Imports the backup at [backupPath] into the Setlist database at [dbPath] on a background isolate, so years of history never block a frame. Takes a safety copy of the Setlist database first. Safe to run twice; [Store.importBatch] says why.
///
/// [backupPath] must be a real file. On Android the picker can return a content URI, so the caller copies the bytes into the cache directory first.
Future<ImportOutcome> importFitNotes({required String backupPath, required String dbPath}) {
  return Isolate.run(() {
    final Database backup;
    try {
      backup = sqlite3.open(backupPath, mode: OpenMode.readOnly);
    } on SqliteException {
      throw const FitNotesFormatError(_notABackup);
    }
    try {
      final read = readFitNotes(backup);
      final store = Store.open(dbPath);
      try {
        store.copyTo('$dbPath.before-import-${DateTime.now().millisecondsSinceEpoch}');
        return (trainingLogRows: read.trainingLogRows, leftOut: read.leftOut, written: store.importBatch(read.batch));
      } finally {
        store.close();
      }
    } finally {
      backup.close();
    }
  });
}

/// The pure half of the import, FitNotes rows in and domain values out. Never writes to [backup]. Throws [FitNotesFormatError] when [backup] is not a FitNotes database with user_version 22.
///
/// Every set on a day before [today] (default: the local date) is done, because FitNotes' done flag only means something with "Mark Sets Complete" on and its never-ticked copies are history now. From [today] on, `is_complete` decides. [leftOut] names what the batch does not carry, with its count, and lists only what the backup has.
({ImportBatch batch, int trainingLogRows, Map<String, int> leftOut}) readFitNotes(Database backup, {Day? today}) {
  try {
    return _read(backup, today ?? Day.of(DateTime.now()));
  } on SqliteException {
    throw const FitNotesFormatError(_notABackup);
  } on FormatException catch (e) {
    throw FitNotesFormatError('This FitNotes backup has a date Setlist cannot read: ${e.source}.');
  }
}

({ImportBatch batch, int trainingLogRows, Map<String, int> leftOut}) _read(Database backup, Day today) {
  if (backup.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'training_log'").isEmpty) throw const FitNotesFormatError(_notABackup);
  final version = backup.userVersion;
  if (version != 22) throw FitNotesFormatError('This FitNotes backup is format version $version. Setlist reads version 22, which current FitNotes versions write. Update FitNotes, make a new backup and import that.');

  final settings = backup.select('SELECT weight_increment, rest_timer_seconds FROM settings').firstOrNull;
  final defaultStep = _positive(_grams(settings?['weight_increment']));
  final defaultRest = _positive(settings?['rest_timer_seconds'] as int?);

  final taken = <String>{};
  final exercises = [
    for (final row in backup.select('SELECT e._id, e.name, e.exercise_type_id, e.weight_increment, e.default_rest_time, c.name AS category FROM exercise e LEFT JOIN Category c ON c._id = e.category_id ORDER BY e._id'))
      ImportedExercise(
        key: '${row['_id']}',
        name: _freeName(row['name'] as String, taken),
        kind: _kinds[row['exercise_type_id']] ?? (throw FitNotesFormatError('The exercise "${row['name']}" has a type Setlist does not know (${row['exercise_type_id']}).')),
        category: row['category'] as String?,
        weightStepGrams: _positive(_grams(row['weight_increment'])) ?? defaultStep,
        rest: switch (_positive(row['default_rest_time'] as int?) ?? defaultRest) {
          final int seconds => Duration(seconds: seconds),
          null => null,
        },
      ),
  ];
  final exerciseKeys = {for (final e in exercises) e.key};

  final setComments = <int, List<String>>{};
  for (final row in backup.select('SELECT owner_id, comment FROM Comment WHERE owner_type_id = 1 ORDER BY _id')) {
    setComments.putIfAbsent(row['owner_id'] as int, () => []).add(row['comment'] as String);
  }

  final notes = <String, List<String>>{};
  for (final row in backup.select('SELECT date, comment FROM WorkoutComment ORDER BY _id')) {
    notes.putIfAbsent(Day.parse(row['date'] as String).iso, () => []).add(row['comment'] as String);
  }

  // Map literals keep insertion order, and rows arrive by date then _id, so each day's exercises come out ordered by their smallest set _id, as FitNotes shows them.
  final days = <String, Map<String, List<SetEntry>>>{};
  final rows = backup.select('SELECT _id, exercise_id, date, metric_weight, reps, unit, distance, duration_seconds, is_complete FROM training_log ORDER BY date, _id');
  for (final row in rows) {
    final key = '${row['exercise_id']}';
    if (!exerciseKeys.contains(key)) throw FitNotesFormatError('This FitNotes backup has a set (${row['_id']}) of an exercise it does not contain.');
    final day = Day.parse(row['date'] as String);
    final done = day.isBefore(today) || row['is_complete'] == 1;
    days.putIfAbsent(day.iso, () => {}).putIfAbsent(key, () => []).add(
      SetEntry(
        grams: _grams(row['metric_weight'])!,
        reps: row['reps'] as int,
        metres: _metres(row['distance'] as num, row['unit'] as int),
        seconds: row['duration_seconds'] as int,
        note: setComments.remove(row['_id'])?.join(' / ') ?? '',
        status: done ? const Done() : const Planned(),
      ),
    );
  }

  int count(String from) => backup.select('SELECT COUNT(*) AS n FROM $from').single['n'] as int;
  final leftOut = {
    'superset groups': count('WorkoutGroup'),
    'routines': count('Routine'),
    'body weight entries': count('BodyWeight'),
    'comments on deleted sets': setComments.values.fold(0, (n, comments) => n + comments.length),
    'other comments': count('Comment WHERE owner_type_id != 1'),
  }..removeWhere((_, n) => n == 0);

  final batch = ImportBatch(
    source: 'fitnotes',
    exercises: exercises,
    days: [
      for (final iso in {...days.keys, ...notes.keys}.toList()..sort())
        ImportedDay(
          day: Day.parse(iso),
          note: notes[iso]?.join('\n') ?? '',
          entries: [
            for (final MapEntry(key: exerciseKey, value: sets) in (days[iso] ?? const {}).entries) [(exerciseKey: exerciseKey, sets: sets)],
          ],
        ),
    ],
    defaultWeightStepGrams: defaultStep,
    defaultRest: defaultRest == null ? null : Duration(seconds: defaultRest),
  );
  return (batch: batch, trainingLogRows: rows.length, leftOut: leftOut);
}

const _notABackup = "This file is not a FitNotes backup. Make a backup in FitNotes' settings, then pick its .fitnotes file. A Google Drive automatic backup arrives as a .zip file: unzip it first and pick the .fitnotes file inside.";

int? _grams(Object? kilograms) => kilograms == null ? null : ((kilograms as num) * 1000).round();

/// FitNotes stores "use the global setting" as NULL or 0.
int? _positive(int? value) => value != null && value > 0 ? value : null;

/// [name], or the first of `name (2)`, `name (3)`, ... not in [taken], ignoring case, because Setlist names are unique ignoring case and FitNotes names are not. Adds the result to [taken].
String _freeName(String name, Set<String> taken) {
  for (var n = 1;; n++) {
    final candidate = n == 1 ? name : '$name ($n)';
    if (taken.add(candidate.toLowerCase())) return candidate;
  }
}

/// FitNotes `exercise_type_id` to kind, from ExerciseType.java as cited in docs/research.md.
const Map<int, ExerciseKind> _kinds = {
  0: ExerciseKind.weightReps,
  1: ExerciseKind.distanceTime,
  2: ExerciseKind.weightDistance,
  3: ExerciseKind.weightTime,
  4: ExerciseKind.repsDistance,
  5: ExerciseKind.repsTime,
  6: ExerciseKind.weight,
  7: ExerciseKind.reps,
  8: ExerciseKind.distance,
  9: ExerciseKind.time,
};

/// A training_log distance in metres. `unit` is FitNotes' DistanceUnit: 2 metres, 3 kilometres, 4 feet, 5 miles, and anything else falls back to metres as FitNotes does.
int _metres(num distance, int unit) => switch (unit) {
  3 => (distance * 1000).round(),
  4 => (distance * 0.3048).round(),
  5 => (distance * 1609.344).round(),
  _ => distance.round(),
};

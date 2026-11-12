/// Reads a FitNotes backup into an [ImportBatch] and runs the import off the UI isolate.
///
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
}

/// Imports the backup at [backupPath] into the Setlist database at [dbPath] on a background isolate, so years of history never block a frame. Takes a safety copy of the Setlist database first. Safe to run twice; [Store.importBatch] says why.
///
/// [backupPath] must be a real file. On Android the picker can return a content URI, so the caller copies the bytes into the cache directory first.
Future<ImportOutcome> importFitNotes({required String backupPath, required String dbPath}) {
  return Isolate.run(() {
    // TODO:
    //   backup = sqlite3.open(backupPath, mode: OpenMode.readOnly)
    //   read = readFitNotes(backup)                       // throws FitNotesFormatError before anything is written
    //   store = Store.open(dbPath)                        // its own connection; WAL lets the UI connection keep reading
    //   store.copyTo('$dbPath.before-import-${DateTime.now().millisecondsSinceEpoch}')
    //   written = store.importBatch(read.batch)
    //   close both (finally), return (trainingLogRows: read.trainingLogRows, leftOut: read.leftOut, written: written)
    throw UnimplementedError();
  });
}

/// The pure half of the import, FitNotes rows in and domain values out. Never writes to [backup]. Throws [FitNotesFormatError] when [backup] is not a FitNotes database with user_version 22.
({ImportBatch batch, int trainingLogRows, Map<String, int> leftOut}) readFitNotes(Database backup) {
  // TODO(read):
  //   if (backup.userVersion != 22) throw FitNotesFormatError('Expected a FitNotes backup (version 22), found version ${backup.userVersion}.')
  //
  //   exercises: SELECT e._id, e.name, c.name, e.exercise_type_id, e.weight_increment, e.default_rest_time
  //              FROM exercise e LEFT JOIN Category c ON c._id = e.category_id
  //     -> ImportedExercise(key: '${e._id}', name, kind: _kinds[exercise_type_id], category: c.name,
  //                         weightStepGrams: from weight_increment (unit to confirm on a real backup), default 2500,
  //                         rest: Duration(seconds: default_rest_time ?? 120))
  //     an unknown exercise_type_id throws FitNotesFormatError naming the exercise
  //     names equal ignoring case get ' (2)', ' (3)' appended in _id order, because Setlist names are unique ignoring case
  //
  //   notes: SELECT date, comment FROM WorkoutComment ORDER BY _id -> Map<Day, String>, several comments on one date joined by '\n'
  //
  //   sets: SELECT _id, exercise_id, date, metric_weight, reps, unit, distance, duration_seconds, is_pending_update
  //         FROM training_log ORDER BY date, _id
  //     a new date starts a new ImportedDay (note from `notes`)
  //     within a date, the first row of an exercise_id starts its slot, which orders slots by smallest _id as FitNotes does
  //     each row -> SetEntry(grams: (metric_weight * 1000).round(), reps: reps, metres: _metres(distance, unit),
  //                          seconds: duration_seconds,
  //                          status: is_pending_update == 1 ? const Planned() : const Done())   // FitNotes keeps no time per set
  //     every row becomes exactly one set, so the count check holds by construction
  //   dates with a WorkoutComment and no sets become ImportedDay(day, note) with no slots
  //
  //   trainingLogRows: SELECT COUNT(*) FROM training_log
  //   leftOut: {'routines': COUNT(Routine), 'superset groups': COUNT(WorkoutGroup),
  //             'set comments': COUNT(Comment WHERE owner_type_id = 1), 'body weight entries': COUNT(BodyWeight)}
  //   batch: ImportBatch(source: 'fitnotes', exercises, days)
  throw UnimplementedError();
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

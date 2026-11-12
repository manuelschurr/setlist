import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/store.dart';
import 'package:sqlite3/sqlite3.dart';

final d1 = Day.parse('2026-11-09');
final d2 = Day.parse('2026-11-11');
final d3 = Day.parse('2026-11-12');

SetEntry done(int grams, int reps, {String note = ''}) => SetEntry(grams: grams, reps: reps, note: note, status: Done(DateTime(2026, 11, 9, 18)));

/// Every row of every table, each row as text and sorted, so two databases compare by content alone.
Map<String, List<String>> dump(String path) {
  final db = sqlite3.open(path);
  try {
    return {
      for (final table in ['exercise', 'workout', 'workout_slot', 'workout_set', 'app_day', 'setting']) table: [for (final row in db.select('SELECT * FROM $table')) '$row']..sort(),
    };
  } finally {
    db.close();
  }
}

void main() {
  late String path;
  late Store store;
  late Exercise squat;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('setlist_test_');
    path = '${dir.path}/setlist.sqlite';
    store = Store.open(path);
    addTearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });
    squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
  });

  group('days', () {
    test('saving the same day twice leaves the same rows', () {
      final w = Workout(day: d1, note: 'legs', slots: [Slot(squat, [done(100000, 5), const SetEntry(grams: 100000, reps: 5)])]);
      store.saveDay(w);
      final once = dump(path);
      store.saveDay(w);
      expect(dump(path), once);
      expect(once['workout_set'], hasLength(2));
      expect(store.loadDay(d1), w);
    });

    test('a day loads back with its order, notes, warm-ups, log times and imported sets', () {
      final plank = store.createExercise(name: 'Plank', kind: ExerciseKind.time);
      final run = store.createExercise(name: 'Run', kind: ExerciseKind.distanceTime);
      final w = Workout(day: d3, note: 'felt strong', slots: [
        Slot(plank, [SetEntry(seconds: 60, status: Done(DateTime(2026, 11, 12, 18, 30, 15, 250))), const SetEntry(seconds: 60, status: Done())]),
        Slot(squat, [SetEntry(grams: 60000, reps: 5, warmup: true, note: 'easy', status: Done(DateTime(2026, 11, 12, 18, 40))), const SetEntry(grams: 20412, reps: 5, note: 'belt'), const SetEntry(grams: -5000, reps: 8)]),
        Slot(run, [const SetEntry(metres: 5200, seconds: 1500)]),
      ]);
      store.saveDay(w);
      expect(store.loadDay(d3), w);
    });

    test('a day never saved loads as an empty day', () {
      expect(store.loadDay(d2), Workout(day: d2));
    });

    test('a day with no exercises and no note is deleted, and a note alone keeps a day', () {
      store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(100000, 5)])]));
      store.saveDay(Workout(day: d1));
      store.saveDay(Workout(day: d2, note: 'rest day'));
      expect(store.recentWorkouts(), [Workout(day: d2, note: 'rest day')]);
      expect(dump(path)['workout_set'], isEmpty);
    });

    test('a failed save throws StoreWriteFailed and keeps the rows from before', () {
      final w = Workout(day: d1, slots: [Slot(squat, [done(100000, 5)])]);
      store.saveDay(w);
      const ghost = Exercise(id: ExerciseId(999), name: 'Ghost', kind: ExerciseKind.reps);
      expect(() => store.saveDay(Workout(day: d1, slots: [Slot(ghost, [const SetEntry(reps: 5)])])), throwsA(isA<StoreWriteFailed>()));
      expect(() => store.saveDay(Workout(day: d1, slots: [Slot(squat, [const SetEntry(reps: -1)])])), throwsA(isA<StoreWriteFailed>()));
      expect(store.loadDay(d1), w);
      store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(105000, 5)])]));
      expect(store.loadDay(d1).slots.single.sets.single.grams, 105000);
    });

    test('a saved day shows its exercise as it is now', () {
      store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(100000, 5)])]));
      final renamed = Exercise(id: squat.id, name: 'Back squat', kind: ExerciseKind.weightReps, category: 'Legs', weightStepGrams: 1000, rest: const Duration(minutes: 3));
      store.updateExercise(renamed);
      expect(store.loadDay(d1).slots.single.exercise, renamed);
    });
  });

  group('history', () {
    test('last session skips days with only planned sets and days on or after the one asked about', () {
      store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(100000, 5, note: 'grindy'), done(100000, 4), const SetEntry(grams: 100000, reps: 5)])]));
      store.saveDay(Workout(day: d2, slots: [Slot(squat, [const SetEntry(grams: 102500, reps: 5)])]));
      store.saveDay(Workout(day: d3, slots: [Slot(squat, [done(105000, 5)])]));
      expect(store.lastSession(squat.id, before: d3), [done(100000, 5, note: 'grindy'), done(100000, 4)]);
      expect(store.lastSession(squat.id, before: Day.parse('2026-11-13')), [done(105000, 5)]);
      expect(store.lastSession(squat.id, before: d1), isEmpty);
    });

    test('recent workouts page newest first', () {
      final days = [for (final d in ['01', '02', '03', '04', '05']) Day.parse('2026-10-$d')];
      for (final day in days) {
        store.saveDay(Workout(day: day, slots: [Slot(squat, [done(100000, 5)])]));
      }
      List<Day> page(Day? before) => [for (final w in store.recentWorkouts(before: before, limit: 2)) w.day];
      expect(page(null), [days[4], days[3]]);
      expect(page(days[3]), [days[2], days[1]]);
      expect(page(days[1]), [days[0]]);
      expect(page(days[0]), isEmpty);
      expect(store.recentWorkouts(before: days[3], limit: 1).single, Workout(day: days[2], slots: [Slot(squat, [done(100000, 5)])]));
    });

    test('the exercise list puts the most recently done first, then the never-done ones by name', () {
      final bench = store.createExercise(name: 'bench', kind: ExerciseKind.weightReps);
      final row = store.createExercise(name: 'Row', kind: ExerciseKind.weightReps);
      final abWheel = store.createExercise(name: 'ab wheel', kind: ExerciseKind.reps);
      final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
      store.saveDay(Workout(day: d1, slots: [Slot(bench, [done(80000, 5)]), Slot(row, [done(60000, 8)])]));
      store.saveDay(Workout(day: d2, slots: [Slot(squat, [done(100000, 5)])]));
      store.saveDay(Workout(day: d3, slots: [Slot(row, [const SetEntry(grams: 60000, reps: 8)]), Slot(curl, [const SetEntry(grams: 12000, reps: 10)])]));
      final names = [for (final e in store.exercises()) e.name];
      expect(names.take(1), [squat.name]);
      expect(names.skip(1).take(2).toSet(), {bench.name, row.name});
      expect(names.skip(3), [abWheel.name, curl.name]);
    });
  });

  group('exercises', () {
    test('a name is taken whatever its case', () {
      final memory = Store.inMemory();
      addTearDown(memory.close);
      memory.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
      final front = memory.createExercise(name: 'Front squat', kind: ExerciseKind.weightReps);
      expect(() => memory.createExercise(name: 'SQUAT', kind: ExerciseKind.reps), throwsA(isA<DuplicateExerciseName>()));
      expect(() => memory.updateExercise(Exercise(id: front.id, name: 'squat', kind: front.kind)), throwsA(isA<DuplicateExerciseName>()));
      expect([for (final e in memory.exercises()) e.name]..sort(), ['Front squat', 'Squat']);
    });

    test('a new exercise takes the stored defaults unless it names its own', () {
      expect(store.loadDefaults(), (weightStepGrams: 2500, rest: const Duration(seconds: 120)));
      expect((squat.weightStepGrams, squat.rest), (2500, const Duration(seconds: 120)));
      store.importBatch(ImportBatch(source: 'fitnotes', exercises: const [], days: const [], defaultWeightStepGrams: 1000, defaultRest: const Duration(seconds: 60)));
      expect(store.loadDefaults(), (weightStepGrams: 1000, rest: const Duration(seconds: 60)));
      final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
      final row = store.createExercise(name: 'Row', kind: ExerciseKind.weightReps, weightStepGrams: 2000, rest: const Duration(seconds: 90));
      expect((curl.weightStepGrams, curl.rest), (1000, const Duration(seconds: 60)));
      expect((row.weightStepGrams, row.rest), (2000, const Duration(seconds: 90)));
      expect(store.exercises().toSet(), {squat, curl, row});
    });

    test('an edit saves every field', () {
      final edited = Exercise(id: squat.id, name: 'Box squat', kind: ExerciseKind.repsTime, category: 'Legs', weightStepGrams: 500, rest: const Duration(seconds: 45));
      store.updateExercise(edited);
      expect(store.exercises(), [edited]);
    });
  });

  group('import', () {
    final batch = ImportBatch(
      source: 'fitnotes',
      exercises: const [ImportedExercise(key: '7', name: 'squat', kind: ExerciseKind.weightReps), ImportedExercise(key: '8', name: 'Plank', kind: ExerciseKind.time)],
      days: [
        ImportedDay(day: d1, slots: [(exerciseKey: '7', sets: [const SetEntry(grams: 100000, reps: 5, note: 'from a comment', status: Done())])]),
        ImportedDay(day: d2, note: 'tired', slots: [(exerciseKey: '8', sets: [const SetEntry(seconds: 60, status: Done())])]),
      ],
      defaultWeightStepGrams: 1000,
      defaultRest: const Duration(seconds: 60),
    );

    test('running it twice writes the same rows', () {
      final first = store.importBatch(batch);
      final after = dump(path);
      final second = store.importBatch(batch);
      expect(dump(path), after);
      expect((first.exercisesCreated, first.exercisesLinked, first.daysWritten, first.setsWritten), (1, 1, 2, 2));
      expect((second.exercisesCreated, second.exercisesLinked, second.daysWritten, second.setsWritten), (0, 2, 2, 2));
      expect(store.loadDay(d1).slots.single.sets.single.note, 'from a comment');
    });

    test('a created exercise takes the batch defaults, and a linked one keeps the lifter\'s own', () {
      store.importBatch(batch);
      final plank = store.exercises().singleWhere((e) => e.name == 'Plank');
      expect((plank.weightStepGrams, plank.rest), (1000, const Duration(seconds: 60)));
      expect(store.exercises().singleWhere((e) => e.id == squat.id), squat);
    });

    test('never overwrites or resurrects a day the lifter saved in Setlist', () {
      store.importBatch(batch);
      final edited = Workout(day: d1, slots: [Slot(squat, [done(110000, 5)])]);
      store.saveDay(edited);
      store.saveDay(Workout(day: d2));
      final report = store.importBatch(batch);
      expect(store.loadDay(d1), edited);
      expect(store.loadDay(d2).isEmpty, isTrue);
      expect(report.skippedDays, [d1, d2]);
      expect(report.daysWritten, 0);
    });

    test('refreshes a day it wrote when a newer backup changes it', () {
      store.importBatch(batch);
      final newer = ImportBatch(source: 'fitnotes', exercises: batch.exercises, days: [
        ImportedDay(day: d1, slots: [(exerciseKey: '7', sets: [const SetEntry(grams: 105000, reps: 5, status: Done()), const SetEntry(grams: 105000, reps: 4, status: Done())])]),
      ]);
      final report = store.importBatch(newer);
      expect([for (final s in store.loadDay(d1).slots.single.sets) s.grams], [105000, 105000]);
      expect(report.skippedDays, isEmpty);
      expect(store.loadDay(d2).note, 'tired');
    });

    test('links an exercise by its import key after a rename, and by name only when no key holds it', () {
      store.importBatch(batch);
      store.updateExercise(Exercise(id: squat.id, name: 'Back squat', kind: ExerciseKind.weightReps));
      final again = store.importBatch(batch);
      expect(again.exercisesCreated, 0);
      expect(store.loadDay(d1).slots.single.exercise.name, 'Back squat');
      final other = store.importBatch(const ImportBatch(source: 'strong', exercises: [ImportedExercise(key: 'p', name: 'plank', kind: ExerciseKind.time)], days: []));
      expect(other.exercisesCreated, 1);
      expect([for (final e in store.exercises()) e.name]..sort(), ['Back squat', 'Plank', 'plank (strong)']);
    });

    test('a batch with an unknown exercise or an empty slot writes nothing', () {
      final before = dump(path);
      for (final bad in <ImportedSlot>[(exerciseKey: '99', sets: [const SetEntry(reps: 5, status: Done())]), (exerciseKey: '8', sets: [])]) {
        final broken = ImportBatch(source: 'fitnotes', exercises: batch.exercises, days: [batch.days.first, ImportedDay(day: d2, slots: [bad])], defaultRest: const Duration(seconds: 30));
        expect(() => store.importBatch(broken), throwsArgumentError, reason: bad.exerciseKey);
        expect(dump(path), before, reason: bad.exerciseKey);
      }
    });
  });

  group('file', () {
    test('docs/schema.sql is exactly the schema the migrations build', () {
      final golden = File('docs/schema.sql');
      final db = sqlite3.open(path);
      final statements = [for (final row in db.select('SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY rowid')) '${row['sql']};'];
      final text = '${['-- Setlist schema at user_version ${db.userVersion}, generated by test/store_test.dart from the migrations in lib/store.dart. Change those, then rerun the test with SETLIST_WRITE_SCHEMA=1 to rewrite this file.', ...statements].join('\n\n')}\n';
      db.close();
      if (Platform.environment['SETLIST_WRITE_SCHEMA'] == '1') golden.writeAsStringSync(text);
      expect(golden.readAsStringSync(), text);
    });

    test('a file from a newer build is refused before anything is written to it', () {
      final newer = '$path.newer';
      sqlite3.open(newer)
        ..userVersion = 1000
        ..close();
      expect(() => Store.open(newer), throwsA(isA<StoreTooNew>().having((e) => e.found, 'found', 1000)));
      final raw = sqlite3.open(newer);
      addTearDown(raw.close);
      expect(raw.userVersion, 1000);
      expect(raw.select('SELECT name FROM sqlite_master'), isEmpty);
      expect(raw.select('PRAGMA journal_mode').single.values.single, 'delete');
    });

    test('migrating a file that already holds data first copies it aside', () {
      final old = '$path.old';
      sqlite3.open(old)
        ..execute('CREATE TABLE keep (x INTEGER); INSERT INTO keep VALUES (42);')
        ..close();
      Store.open(old).close();
      final backup = sqlite3.open('$old.v0.bak');
      addTearDown(backup.close);
      expect(backup.userVersion, 0);
      expect(backup.select('SELECT x FROM keep').single['x'], 42);
    });

    test('a fresh file needs no copy, and reopening a current file keeps its data and copies nothing', () {
      final w = Workout(day: d1, slots: [Slot(squat, [done(100000, 5)])]);
      store.saveDay(w);
      store.close();
      store = Store.open(path);
      expect(store.loadDay(d1), w);
      expect(Directory(File(path).parent.path).listSync().where((f) => f.path.endsWith('.bak')), isEmpty);
    });

    test('a copy opens with the same history, and copying again replaces it', () {
      final copy = '$path.export';
      store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(100000, 5)])]));
      store.copyTo(copy);
      store.saveDay(Workout(day: d2, note: 'later'));
      store.copyTo(copy);
      final opened = Store.open(copy);
      addTearDown(opened.close);
      expect(opened.recentWorkouts(), store.recentWorkouts());
      expect(opened.exercises(), store.exercises());
    });
  });
}

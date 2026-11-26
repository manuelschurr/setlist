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
      for (final table in ['exercise', 'workout', 'workout_slot', 'workout_set', 'app_day', 'setting', 'plate']) table: [for (final row in db.select('SELECT * FROM $table')) '$row']..sort(),
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
      final w = Workout(day: d1, note: 'legs', entries: [Slot(squat, [done(100000, 5), const SetEntry(grams: 100000, reps: 5)])]);
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
      final w = Workout(day: d3, note: 'felt strong', entries: [
        Slot(plank, [SetEntry(seconds: 60, status: Done(DateTime(2026, 11, 12, 18, 30, 15, 250))), const SetEntry(seconds: 60, status: Done())]),
        Slot(squat, [SetEntry(grams: 60000, reps: 5, warmup: true, note: 'easy', status: Done(DateTime(2026, 11, 12, 18, 40))), const SetEntry(grams: 20412, reps: 5, note: 'belt'), const SetEntry(grams: -5000, reps: 8)]),
        Slot(run, [const SetEntry(metres: 5200, seconds: 1500)]),
      ]);
      store.saveDay(w);
      expect(store.loadDay(d3), w);
    });

    test('a day with supersets loads back with each superset in its place and round order, and saving it twice leaves the same rows', () {
      final bench = store.createExercise(name: 'Bench', kind: ExerciseKind.weightReps);
      final row = store.createExercise(name: 'Row', kind: ExerciseKind.weightReps);
      final press = store.createExercise(name: 'Press', kind: ExerciseKind.weightReps);
      final dip = store.createExercise(name: 'Dip', kind: ExerciseKind.reps);
      final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
      final w = Workout(day: d1, entries: [
        Superset([Slot(bench, [done(80000, 5), const SetEntry(grams: 80000, reps: 5)]), Slot(row, [const SetEntry(grams: 60000, reps: 8)])]),
        Slot(squat, [done(100000, 5)]),
        Superset([Slot(press, [const SetEntry(grams: 40000, reps: 8)]), Slot(dip, [const SetEntry(reps: 10)]), Slot(curl, [const SetEntry(grams: 12000, reps: 10)])]),
      ]);
      store.saveDay(w);
      final once = dump(path);
      store.saveDay(w);
      expect(dump(path), once);
      expect(store.loadDay(d1), w);
      expect(store.recentWorkouts(), [w]);
    });

    test('a day never saved loads as an empty day', () {
      expect(store.loadDay(d2), Workout(day: d2));
    });

    test('a day with no exercises and no note is deleted, and a note alone keeps a day', () {
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]));
      store.saveDay(Workout(day: d1));
      store.saveDay(Workout(day: d2, note: 'rest day'));
      expect(store.recentWorkouts(), [Workout(day: d2, note: 'rest day')]);
      expect(dump(path)['workout_set'], isEmpty);
    });

    test('a failed save throws StoreWriteFailed and keeps the rows from before', () {
      final w = Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]);
      store.saveDay(w);
      const ghost = Exercise(id: ExerciseId(999), name: 'Ghost', kind: ExerciseKind.reps, equipment: Equipment.none);
      expect(() => store.saveDay(Workout(day: d1, entries: [Slot(ghost, [const SetEntry(reps: 5)])])), throwsA(isA<StoreWriteFailed>()));
      expect(() => store.saveDay(Workout(day: d1, entries: [Slot(squat, [const SetEntry(reps: -1)])])), throwsA(isA<StoreWriteFailed>()));
      expect(store.loadDay(d1), w);
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(105000, 5)])]));
      expect(store.loadDay(d1).slots.single.sets.single.grams, 105000);
    });

    test('a saved day shows its exercise as it is now', () {
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]));
      final renamed = Exercise(id: squat.id, name: 'Back squat', kind: ExerciseKind.weightReps, equipment: Equipment.none, category: 'Legs', weightStepGrams: 1000, rest: const Duration(minutes: 3));
      store.updateExercise(renamed);
      expect(store.loadDay(d1).slots.single.exercise, renamed);
    });
  });

  group('history', () {
    test('last session skips days with only planned sets and days on or after the one asked about', () {
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(100000, 5, note: 'grindy'), done(100000, 4), const SetEntry(grams: 100000, reps: 5)])]));
      store.saveDay(Workout(day: d2, entries: [Slot(squat, [const SetEntry(grams: 102500, reps: 5)])]));
      store.saveDay(Workout(day: d3, entries: [Slot(squat, [done(105000, 5)])]));
      expect(store.lastSession(squat.id, before: d3), [done(100000, 5, note: 'grindy'), done(100000, 4)]);
      expect(store.lastSession(squat.id, before: Day.parse('2026-11-13')), [done(105000, 5)]);
      expect(store.lastSession(squat.id, before: d1), isEmpty);
    });

    test('exercise history lists the days with done sets newest first, each with only its done sets', () {
      final bench = store.createExercise(name: 'Bench', kind: ExerciseKind.weightReps);
      store.saveDay(Workout(day: d1, entries: [Slot(bench, [done(80000, 5)]), Slot(squat, [done(100000, 5, note: 'grindy'), const SetEntry(grams: 100000, reps: 5), done(100000, 4)])]));
      store.saveDay(Workout(day: d2, entries: [Slot(squat, [const SetEntry(grams: 102500, reps: 5)])]));
      store.saveDay(Workout(day: d3, entries: [Slot(squat, [done(105000, 5), done(105000, 3)])]));
      final history = store.exerciseHistory(squat.id);
      expect([for (final s in history) s.day], [d3, d1]);
      expect(history.first.sets, [done(105000, 5), done(105000, 3)]);
      expect(history.last.sets, [done(100000, 5, note: 'grindy'), done(100000, 4)]);
      expect([for (final s in store.exerciseHistory(squat.id, limit: 1)) s.day], [d3]);
      expect(store.exerciseHistory(store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps).id), isEmpty);
    });

    test('recent workouts page newest first', () {
      final days = [for (final d in ['01', '02', '03', '04', '05']) Day.parse('2026-10-$d')];
      for (final day in days) {
        store.saveDay(Workout(day: day, entries: [Slot(squat, [done(100000, 5)])]));
      }
      List<Day> page(Day? before) => [for (final w in store.recentWorkouts(before: before, limit: 2)) w.day];
      expect(page(null), [days[4], days[3]]);
      expect(page(days[3]), [days[2], days[1]]);
      expect(page(days[1]), [days[0]]);
      expect(page(days[0]), isEmpty);
      expect(store.recentWorkouts(before: days[3], limit: 1).single, Workout(day: days[2], entries: [Slot(squat, [done(100000, 5)])]));
    });

    test('the exercise list puts the most recently done first, then the never-done ones by name', () {
      final bench = store.createExercise(name: 'bench', kind: ExerciseKind.weightReps);
      final row = store.createExercise(name: 'Row', kind: ExerciseKind.weightReps);
      final abWheel = store.createExercise(name: 'ab wheel', kind: ExerciseKind.reps);
      final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
      store.saveDay(Workout(day: d1, entries: [Slot(bench, [done(80000, 5)]), Slot(row, [done(60000, 8)])]));
      store.saveDay(Workout(day: d2, entries: [Slot(squat, [done(100000, 5)])]));
      store.saveDay(Workout(day: d3, entries: [Slot(row, [const SetEntry(grams: 60000, reps: 8)]), Slot(curl, [const SetEntry(grams: 12000, reps: 10)])]));
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
      expect(() => memory.updateExercise(Exercise(id: front.id, name: 'squat', kind: front.kind, equipment: Equipment.none)), throwsA(isA<DuplicateExerciseName>()));
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
      final edited = Exercise(id: squat.id, name: 'Box squat', kind: ExerciseKind.repsTime, equipment: Equipment.none, category: 'Legs', weightStepGrams: 500, rest: const Duration(seconds: 45));
      store.updateExercise(edited);
      expect(store.exercises(), [edited]);
    });

    test('an exercise created with a barbell loads with its bar, in the catalog and in a day', () {
      final curl = store.createExercise(name: 'EZ-Bar Curl', kind: ExerciseKind.weightReps, equipment: const Barbell(7500));
      expect(curl.equipment, const Barbell(7500));
      expect(store.exercises().singleWhere((e) => e.id == curl.id).equipment, const Barbell(7500));
      store.saveDay(Workout(day: d1, entries: [Slot(curl, [done(27500, 10)])]));
      expect(store.loadDay(d1).slots.single.exercise, curl);
      expect(squat.equipment, Equipment.none);
    });

    test('an edit changes the equipment, the bar and the handle, and a later edit of only the name keeps them', () {
      Equipment stored() => store.exercises().single.equipment;
      for (final equipment in [Equipment.dumbbellPair, const DumbbellPair(handleGrams: 2500), const OneDumbbell(handleGrams: 2000), Equipment.oneDumbbell, const Barbell(15000), Equipment.none, const Barbell(10000)]) {
        store.updateExercise(Exercise(id: squat.id, name: 'Squat', kind: ExerciseKind.weightReps, equipment: equipment));
        expect(stored(), equipment);
      }
      store.updateExercise(Exercise(id: squat.id, name: 'Back squat', kind: ExerciseKind.weightReps, equipment: store.exercises().single.equipment));
      expect(stored(), const Barbell(10000));
      store.updateExercise(Exercise(id: squat.id, name: 'Back squat', kind: ExerciseKind.weightReps, equipment: const DumbbellPair(handleGrams: 2500)));
      store.updateExercise(Exercise(id: squat.id, name: 'Goblet squat', kind: ExerciseKind.weightReps, equipment: store.exercises().single.equipment));
      expect(stored(), const DumbbellPair(handleGrams: 2500));
    });

    test('an exercise created with an adjustable dumbbell loads with its handle, in the catalog and in a day', () {
      final curl = store.createExercise(name: 'Hammer Curl', kind: ExerciseKind.weightReps, equipment: const DumbbellPair(handleGrams: 2500));
      expect(store.exercises().singleWhere((e) => e.id == curl.id).equipment, const DumbbellPair(handleGrams: 2500));
      store.saveDay(Workout(day: d1, entries: [Slot(curl, [done(14000, 10)])]));
      expect(store.loadDay(d1).slots.single.exercise, curl);
    });

    test('a kind without a weight stores no equipment, so switching back to a weight shows none', () {
      store.updateExercise(Exercise(id: squat.id, name: 'Squat', kind: ExerciseKind.reps, equipment: const Barbell(20000)));
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      expect(raw.select('SELECT equipment, bar_g, handle_g FROM exercise').single.values, ['none', null, null]);
    });
  });

  group('plates', () {
    test('a new file owns no plates', () {
      expect(store.loadPlates(), Plates.none);
    });

    test('saved plates load back, survive a reopen, and a later save replaces them all', () {
      final home = Plates([500, 1000, 1250, 15000]);
      store.savePlates(home);
      expect(store.loadPlates(), home);
      store.close();
      store = Store.open(path);
      expect(store.loadPlates(), home);
      store.savePlates(Plates([2500]));
      expect(store.loadPlates(), Plates([2500]));
      store.savePlates(Plates.none);
      expect(store.loadPlates(), Plates.none);
    });

    test('an import leaves the plates alone', () {
      store.savePlates(Plates([1250]));
      store.importBatch(const ImportBatch(source: 'fitnotes', exercises: [ImportedExercise(key: '7', name: 'Curl', kind: ExerciseKind.weightReps)], days: []));
      expect(store.loadPlates(), Plates([1250]));
    });
  });

  group('import', () {
    final batch = ImportBatch(
      source: 'fitnotes',
      exercises: const [ImportedExercise(key: '7', name: 'squat', kind: ExerciseKind.weightReps), ImportedExercise(key: '8', name: 'Plank', kind: ExerciseKind.time)],
      days: [
        ImportedDay(day: d1, entries: [[(exerciseKey: '7', sets: [const SetEntry(grams: 100000, reps: 5, note: 'from a comment', status: Done())])]]),
        ImportedDay(day: d2, note: 'tired', entries: [[(exerciseKey: '8', sets: [const SetEntry(seconds: 60, status: Done())])]]),
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
      expect(plank.equipment, Equipment.none);
    });

    test('importing again keeps the equipment the lifter set on a linked exercise', () {
      store.importBatch(batch);
      for (final equipment in [const Barbell(15000), const DumbbellPair(handleGrams: 2500)]) {
        store.updateExercise(Exercise(id: squat.id, name: 'Squat', kind: ExerciseKind.weightReps, equipment: equipment));
        store.importBatch(batch);
        expect(store.exercises().singleWhere((e) => e.id == squat.id).equipment, equipment);
      }
    });

    test('never overwrites or resurrects a day the lifter saved in Setlist', () {
      store.importBatch(batch);
      final edited = Workout(day: d1, entries: [Slot(squat, [done(110000, 5)])]);
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
        ImportedDay(day: d1, entries: [[(exerciseKey: '7', sets: [const SetEntry(grams: 105000, reps: 5, status: Done()), const SetEntry(grams: 105000, reps: 4, status: Done())])]]),
      ]);
      final report = store.importBatch(newer);
      expect([for (final s in store.loadDay(d1).slots.single.sets) s.grams], [105000, 105000]);
      expect(report.skippedDays, isEmpty);
      expect(store.loadDay(d2).note, 'tired');
    });

    test('links an exercise by its import key after a rename, and by name only when no key holds it', () {
      store.importBatch(batch);
      store.updateExercise(Exercise(id: squat.id, name: 'Back squat', kind: ExerciseKind.weightReps, equipment: Equipment.none));
      final again = store.importBatch(batch);
      expect(again.exercisesCreated, 0);
      expect(store.loadDay(d1).slots.single.exercise.name, 'Back squat');
      final other = store.importBatch(const ImportBatch(source: 'strong', exercises: [ImportedExercise(key: 'p', name: 'plank', kind: ExerciseKind.time)], days: []));
      expect(other.exercisesCreated, 1);
      expect([for (final e in store.exercises()) e.name]..sort(), ['Back squat', 'Plank', 'plank (strong)']);
    });

    test('a batch with an unknown exercise, an empty slot or an empty entry writes nothing', () {
      final before = dump(path);
      final plank = (exerciseKey: '8', sets: [const SetEntry(seconds: 60, status: Done())]);
      for (final (bad, why) in <(List<List<ImportedSlot>>, String)>[
        ([[(exerciseKey: '99', sets: [const SetEntry(reps: 5, status: Done())])]], 'unknown exercise'),
        ([[(exerciseKey: '8', sets: [])]], 'empty slot'),
        ([[plank], []], 'empty entry'),
      ]) {
        final broken = ImportBatch(source: 'fitnotes', exercises: batch.exercises, days: [batch.days.first, ImportedDay(day: d2, entries: bad)], defaultRest: const Duration(seconds: 30));
        expect(() => store.importBatch(broken), throwsArgumentError, reason: why);
        expect(dump(path), before, reason: why);
      }
    });

    test('a superset in the batch arrives as a superset', () {
      final paired = ImportBatch(source: 'fitnotes', exercises: batch.exercises, days: [
        ImportedDay(day: d3, entries: [
          [(exerciseKey: '8', sets: [const SetEntry(seconds: 60, status: Done())]), (exerciseKey: '7', sets: [const SetEntry(grams: 100000, reps: 5, status: Done())])],
        ]),
      ]);
      store.importBatch(paired);
      final plank = store.exercises().singleWhere((e) => e.name == 'Plank');
      expect(store.loadDay(d3).entries, [
        Superset([Slot(plank, [const SetEntry(seconds: 60, status: Done())]), Slot(squat, [const SetEntry(grams: 100000, reps: 5, status: Done())])]),
      ]);
    });

    test('a batch that holds one day twice writes nothing', () {
      final before = dump(path);
      final twice = ImportBatch(source: 'fitnotes', exercises: batch.exercises, days: [batch.days.first, batch.days.first]);
      expect(() => store.importBatch(twice), throwsArgumentError);
      expect(dump(path), before);
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

    test('a v1 file with data migrates its days as plain exercises, keeps a v1 copy, and ends with the schema a new file has', () {
      final v1 = '$path.v1';
      sqlite3.open(v1)
        ..execute(File('test/schema_v1.sql').readAsStringSync())
        ..execute('''
INSERT INTO exercise (id, name, kind, weight_step_g, rest_s) VALUES (1, 'Squat', 'weightReps', 2500, 120), (2, 'Bench', 'weightReps', 2500, 90);
INSERT INTO workout (day, note) VALUES ('2026-11-09', 'legs');
INSERT INTO workout_slot (day, exercise_id, position) VALUES ('2026-11-09', 2, 0), ('2026-11-09', 1, 1);
INSERT INTO workout_set (day, exercise_id, set_index, weight_g, reps, done) VALUES ('2026-11-09', 2, 0, 80000, 5, 1), ('2026-11-09', 1, 0, 100000, 5, 0), ('2026-11-09', 1, 1, 100000, 5, 0);
INSERT INTO app_day (day) VALUES ('2026-11-09');
PRAGMA user_version = 1;
''')
        ..close();

      final migrated = Store.open(v1);
      addTearDown(migrated.close);
      const bench = Exercise(id: ExerciseId(2), name: 'Bench', kind: ExerciseKind.weightReps, equipment: Equipment.none, rest: Duration(seconds: 90));
      const squatV1 = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Equipment.none);
      expect(migrated.loadDay(d1), Workout(day: d1, note: 'legs', entries: [Slot(bench, [const SetEntry(grams: 80000, reps: 5, status: Done())]), Slot(squatV1, [const SetEntry(grams: 100000, reps: 5), const SetEntry(grams: 100000, reps: 5)])]));
      final paired = Workout(day: d2, entries: [Superset([Slot(squatV1, [const SetEntry(grams: 100000, reps: 5)]), Slot(bench, [const SetEntry(grams: 80000, reps: 5)])])]);
      migrated.saveDay(paired);
      expect(migrated.loadDay(d2), paired);

      List<String> schema(String file) {
        final db = sqlite3.open(file, mode: OpenMode.readOnly);
        try {
          return [for (final row in db.select('SELECT type, name, sql FROM sqlite_master ORDER BY rowid')) '$row', 'user_version ${db.userVersion}'];
        } finally {
          db.close();
        }
      }

      expect(schema(v1), schema(path));
      final copy = sqlite3.open('$v1.v1.bak', mode: OpenMode.readOnly);
      addTearDown(copy.close);
      expect(copy.userVersion, 1);
      expect([for (final row in copy.select('SELECT exercise_id FROM workout_slot ORDER BY position')) row['exercise_id']], [2, 1]);
    });

    test('a v2 file with data migrates every exercise to no equipment with its id, keeps a v2 copy, and ends with the schema a new file has', () {
      final v2 = '$path.v2';
      sqlite3.open(v2)
        ..execute(File('test/schema_v2.sql').readAsStringSync())
        ..execute('''
INSERT INTO exercise (id, name, kind, category, weight_step_g, rest_s, import_key) VALUES (3, 'Squat', 'weightReps', 'Legs', 2500, 120, NULL), (7, 'Bench', 'weightReps', NULL, 1000, 90, 'fitnotes:12'), (12, 'Plank', 'time', NULL, 2500, 60, NULL);
INSERT INTO workout (day, note) VALUES ('2026-11-09', 'push');
INSERT INTO workout_slot (day, exercise_id, position, joined) VALUES ('2026-11-09', 12, 0, 0), ('2026-11-09', 7, 1, 0), ('2026-11-09', 3, 2, 1);
INSERT INTO workout_set (day, exercise_id, set_index, weight_g, reps, seconds, done) VALUES ('2026-11-09', 12, 0, 0, 0, 60, 1), ('2026-11-09', 7, 0, 80000, 5, 0, 1), ('2026-11-09', 3, 0, 100000, 5, 0, 0);
INSERT INTO app_day (day) VALUES ('2026-11-09');
PRAGMA user_version = 2;
''')
        ..close();

      final migrated = Store.open(v2);
      addTearDown(migrated.close);
      const squatV2 = Exercise(id: ExerciseId(3), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Equipment.none, category: 'Legs');
      const benchV2 = Exercise(id: ExerciseId(7), name: 'Bench', kind: ExerciseKind.weightReps, equipment: Equipment.none, weightStepGrams: 1000, rest: Duration(seconds: 90));
      const plank = Exercise(id: ExerciseId(12), name: 'Plank', kind: ExerciseKind.time, equipment: Equipment.none, rest: Duration(seconds: 60));
      expect(migrated.exercises().toSet(), {squatV2, benchV2, plank});
      expect(
        migrated.loadDay(d1),
        Workout(day: d1, note: 'push', entries: [
          Slot(plank, [const SetEntry(seconds: 60, status: Done())]),
          Superset([Slot(benchV2, [const SetEntry(grams: 80000, reps: 5, status: Done())]), Slot(squatV2, [const SetEntry(grams: 100000, reps: 5)])]),
        ]),
      );
      final relinked = migrated.importBatch(const ImportBatch(source: 'fitnotes', exercises: [ImportedExercise(key: '12', name: 'Bench press', kind: ExerciseKind.weightReps)], days: []));
      expect((relinked.exercisesCreated, relinked.exercisesLinked), (0, 1));

      List<String> schema(String file) {
        final db = sqlite3.open(file, mode: OpenMode.readOnly);
        try {
          return [for (final row in db.select('SELECT type, name, sql FROM sqlite_master ORDER BY rowid')) '$row', 'user_version ${db.userVersion}'];
        } finally {
          db.close();
        }
      }

      expect(schema(v2), schema(path));
      final copy = sqlite3.open('$v2.v2.bak', mode: OpenMode.readOnly);
      addTearDown(copy.close);
      expect(copy.userVersion, 2);
      expect([for (final row in copy.select('SELECT id FROM exercise ORDER BY id')) row['id']], [3, 7, 12]);
    });

    test('a v3 file with data keeps every exercise with its id, equipment and bar, adds no handle, keeps a v3 copy, and ends with the schema a new file has', () {
      final v3 = '$path.v3';
      sqlite3.open(v3)
        ..execute(File('test/schema_v3.sql').readAsStringSync())
        ..execute('''
INSERT INTO exercise (id, name, kind, category, weight_step_g, rest_s, import_key, equipment, bar_g) VALUES (3, 'Squat', 'weightReps', 'Legs', 2500, 120, NULL, 'barbell', 20000), (7, 'Hammer Curl', 'weightReps', NULL, 1000, 90, 'fitnotes:12', 'dumbbellPair', NULL), (9, 'Row', 'weightReps', NULL, 1000, 90, NULL, 'oneDumbbell', NULL), (12, 'Plank', 'time', NULL, 2500, 60, NULL, 'none', NULL);
INSERT INTO workout (day, note) VALUES ('2026-11-09', 'pull');
INSERT INTO workout_slot (day, exercise_id, position, joined) VALUES ('2026-11-09', 12, 0, 0), ('2026-11-09', 7, 1, 0), ('2026-11-09', 3, 2, 1);
INSERT INTO workout_set (day, exercise_id, set_index, weight_g, reps, seconds, done) VALUES ('2026-11-09', 12, 0, 0, 0, 60, 1), ('2026-11-09', 7, 0, 14000, 10, 0, 1), ('2026-11-09', 3, 0, 100000, 5, 0, 0);
INSERT INTO app_day (day) VALUES ('2026-11-09');
PRAGMA user_version = 3;
''')
        ..close();

      final migrated = Store.open(v3);
      addTearDown(migrated.close);
      const squatV3 = Exercise(id: ExerciseId(3), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Barbell(20000), category: 'Legs');
      const curl = Exercise(id: ExerciseId(7), name: 'Hammer Curl', kind: ExerciseKind.weightReps, equipment: Equipment.dumbbellPair, weightStepGrams: 1000, rest: Duration(seconds: 90));
      const row = Exercise(id: ExerciseId(9), name: 'Row', kind: ExerciseKind.weightReps, equipment: Equipment.oneDumbbell, weightStepGrams: 1000, rest: Duration(seconds: 90));
      const plank = Exercise(id: ExerciseId(12), name: 'Plank', kind: ExerciseKind.time, equipment: Equipment.none, rest: Duration(seconds: 60));
      expect(migrated.exercises().toSet(), {squatV3, curl, row, plank});
      expect(migrated.loadPlates(), Plates.none);
      expect(
        migrated.loadDay(d1),
        Workout(day: d1, note: 'pull', entries: [
          Slot(plank, [const SetEntry(seconds: 60, status: Done())]),
          Superset([Slot(curl, [const SetEntry(grams: 14000, reps: 10, status: Done())]), Slot(squatV3, [const SetEntry(grams: 100000, reps: 5)])]),
        ]),
      );
      final relinked = migrated.importBatch(const ImportBatch(source: 'fitnotes', exercises: [ImportedExercise(key: '12', name: 'Curl', kind: ExerciseKind.weightReps)], days: []));
      expect((relinked.exercisesCreated, relinked.exercisesLinked), (0, 1));

      List<String> schema(String file) {
        final db = sqlite3.open(file, mode: OpenMode.readOnly);
        try {
          return [for (final row in db.select('SELECT type, name, sql FROM sqlite_master ORDER BY rowid')) '$row', 'user_version ${db.userVersion}'];
        } finally {
          db.close();
        }
      }

      expect(schema(v3), schema(path));
      final copy = sqlite3.open('$v3.v3.bak', mode: OpenMode.readOnly);
      addTearDown(copy.close);
      expect(copy.userVersion, 3);
      expect([for (final row in copy.select('SELECT id FROM exercise ORDER BY id')) row['id']], [3, 7, 9, 12]);
    });

    test('a v4 file keeps every plate size it counted, drops the counts, keeps its exercises and a v4 copy, and ends with the schema a new file has', () {
      final v4 = '$path.v4';
      sqlite3.open(v4)
        ..execute(File('test/schema_v4.sql').readAsStringSync())
        ..execute('''
INSERT INTO exercise (id, name, kind, category, weight_step_g, rest_s, import_key, equipment, bar_g, handle_g) VALUES (3, 'Squat', 'weightReps', 'Legs', 2500, 120, NULL, 'barbell', 20000, NULL), (7, 'Hammer Curl', 'weightReps', NULL, 1000, 90, NULL, 'dumbbellPair', NULL, 2500);
INSERT INTO plate (weight_g, pieces) VALUES (500, 4), (1250, 2), (15000, 1);
PRAGMA user_version = 4;
''')
        ..close();

      final migrated = Store.open(v4);
      addTearDown(migrated.close);
      expect(migrated.loadPlates(), Plates([500, 1250, 15000]));
      expect(migrated.exercises().map((e) => e.equipment).toSet(), {const Barbell(20000), const DumbbellPair(handleGrams: 2500)});

      List<String> schema(String file) {
        final db = sqlite3.open(file, mode: OpenMode.readOnly);
        try {
          return [for (final row in db.select('SELECT type, name, sql FROM sqlite_master ORDER BY rowid')) '$row', 'user_version ${db.userVersion}'];
        } finally {
          db.close();
        }
      }

      expect(schema(v4), schema(path));
      final copy = sqlite3.open('$v4.v4.bak', mode: OpenMode.readOnly);
      addTearDown(copy.close);
      expect(copy.userVersion, 4);
      expect([for (final row in copy.select('SELECT weight_g, pieces FROM plate ORDER BY weight_g')) row.values], [[500, 4], [1250, 2], [15000, 1]]);
    });

    test('a plate size is stored only above 0, and once', () {
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      raw.execute('INSERT INTO plate (weight_g) VALUES (500)');
      for (final insert in ['INSERT INTO plate (weight_g) VALUES (0)', 'INSERT INTO plate (weight_g) VALUES (-500)', 'INSERT INTO plate (weight_g) VALUES (500)']) {
        expect(() => raw.execute(insert), throwsA(isA<SqliteException>()), reason: insert);
      }
    });

    test('a handle weight is stored only for a dumbbell, and only above 0', () {
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      for (final update in ['UPDATE exercise SET handle_g = 2500', "UPDATE exercise SET equipment = 'barbell', bar_g = 20000, handle_g = 2500", "UPDATE exercise SET equipment = 'dumbbellPair', handle_g = 0"]) {
        expect(() => raw.execute(update), throwsA(isA<SqliteException>()), reason: update);
      }
      raw.execute("UPDATE exercise SET equipment = 'oneDumbbell', handle_g = 2500");
      expect(store.exercises().single.equipment, const OneDumbbell(handleGrams: 2500));
      raw.execute("UPDATE exercise SET equipment = 'dumbbellPair', handle_g = NULL");
      expect(store.exercises().single.equipment, Equipment.dumbbellPair);
    });

    test('a bar weight is stored exactly for a barbell, and only above 0', () {
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      for (final update in ["UPDATE exercise SET equipment = 'barbell'", "UPDATE exercise SET equipment = 'dumbbellPair', bar_g = 20000", "UPDATE exercise SET equipment = 'barbell', bar_g = 0", "UPDATE exercise SET bar_g = 20000"]) {
        expect(() => raw.execute(update), throwsA(isA<SqliteException>()), reason: update);
      }
      raw.execute("UPDATE exercise SET equipment = 'barbell', bar_g = 15000");
      expect(store.exercises().single.equipment, const Barbell(15000));
    });

    test('a slot cannot be stored joined at position 0, or with any flag but 0 and 1', () {
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]));
      final raw = sqlite3.open(path);
      addTearDown(raw.close);
      for (final update in ['UPDATE workout_slot SET joined = 1 WHERE position = 0', 'UPDATE workout_slot SET joined = 2']) {
        expect(() => raw.execute(update), throwsA(isA<SqliteException>()), reason: update);
      }
    });

    test('a fresh file needs no copy, and reopening a current file keeps its data and copies nothing', () {
      final w = Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]);
      store.saveDay(w);
      store.close();
      store = Store.open(path);
      expect(store.loadDay(d1), w);
      expect(Directory(File(path).parent.path).listSync().where((f) => f.path.endsWith('.bak')), isEmpty);
    });

    test('a copy opens with the same history, and copying again replaces it', () {
      final copy = '$path.export';
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]));
      store.copyTo(copy);
      store.saveDay(Workout(day: d2, note: 'later'));
      store.copyTo(copy);
      final opened = Store.open(copy);
      addTearDown(opened.close);
      expect(opened.recentWorkouts(), store.recentWorkouts());
      expect(opened.exercises(), store.exercises());
    });

    test('a copy that SQLite or the file system refuses fails as a store write', () {
      final folder = File(path).parent.path;
      expect(() => store.copyTo('$folder/missing/copy.sqlite'), throwsA(isA<StoreWriteFailed>().having((e) => e.cause, 'cause', isA<SqliteException>())));
      Directory('$folder/taken').createSync();
      File('$folder/taken/file').writeAsStringSync('x');
      expect(() => store.copyTo('$folder/taken'), throwsA(isA<StoreWriteFailed>().having((e) => e.cause, 'cause', isA<FileSystemException>())));
    });

    List<String> beforeRestore() => [for (final f in Directory(File(path).parent.path).listSync()) if (f.path.contains('.before-restore-')) f.path];

    test('restoring a copy brings its history back and keeps the database from before', () {
      final exported = Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]);
      store.saveDay(exported);
      final copy = '$path.export';
      store.copyTo(copy);
      store.saveDay(Workout(day: d2, note: 'after the export'));
      store.close();
      File('$path-wal').writeAsStringSync('stale');
      File('$path-shm').writeAsStringSync('stale');

      Store.replaceWith(copy, dbPath: path);
      expect([File(copy).existsSync(), File('$path-wal').existsSync(), File('$path-shm').existsSync()], [false, false, false]);
      store = Store.open(path);
      expect(store.recentWorkouts(), [exported]);
      final previous = Store.open(beforeRestore().single);
      addTearDown(previous.close);
      expect(previous.loadDay(d2).note, 'after the export');
    });

    test('restore refuses a file that is not a Setlist database this build can open, and changes nothing', () {
      store.saveDay(Workout(day: d1, entries: [Slot(squat, [done(100000, 5)])]));
      final newer = '$path.newer';
      store.copyTo(newer);
      sqlite3.open(newer)
        ..userVersion = 1000
        ..close();
      final fitNotes = '$path.fitnotes';
      sqlite3.open(fitNotes)
        ..execute('CREATE TABLE training_log (_id INTEGER PRIMARY KEY); PRAGMA user_version = 22;')
        ..close();
      final text = '$path.txt';
      File(text).writeAsStringSync('not a database at all, just some text that is long enough to have a header');
      store.close();
      final before = dump(path);

      for (final (file, says) in [(newer, 'newer version'), (fitNotes, 'not a Setlist backup'), (text, 'not a Setlist backup'), ('$path.missing', 'not a Setlist backup')]) {
        expect(() => Store.replaceWith(file, dbPath: path), throwsA(isA<NotASetlistBackup>().having((e) => e.message, 'message', contains(says))), reason: file);
      }
      expect(dump(path), before);
      expect(beforeRestore(), isEmpty);
      store = Store.open(path);
    });
  });
}

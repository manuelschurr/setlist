import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/store.dart';

void main() {
  final d1 = Day.parse('2026-11-09');
  final d2 = Day.parse('2026-11-11');
  final d3 = Day.parse('2026-11-12');
  SetEntry done(int grams, int reps) => SetEntry(grams: grams, reps: reps, status: Done(DateTime(2026, 11, 9, 18)));

  late Store store;
  late Exercise squat;
  setUp(() {
    store = Store.inMemory();
    squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
  });
  tearDown(() => store.close());

  test('saving the same day twice leaves the same day', () {
    final w = Workout(day: d1, note: 'legs', slots: [Slot(squat, [done(100000, 5), const SetEntry(grams: 100000, reps: 5)])]);
    store.saveDay(w);
    store.saveDay(w);
    expect(store.loadDay(d1), w);
  });

  test('a day with no exercises and no note is deleted', () {
    store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(100000, 5)])]));
    store.saveDay(Workout(day: d1));
    expect(store.recentWorkouts(), isEmpty);
  });

  test('last session skips days with only planned sets and days on or after the one asked about', () {
    store.saveDay(Workout(day: d1, slots: [Slot(squat, [done(100000, 5), done(100000, 4)])]));
    store.saveDay(Workout(day: d2, slots: [Slot(squat, [const SetEntry(grams: 102500, reps: 5)])]));
    store.saveDay(Workout(day: d3, slots: [Slot(squat, [done(105000, 5)])]));
    expect(store.lastSession(squat.id, before: d3), [done(100000, 5), done(100000, 4)]);
  });

  group('import', () {
    final batch = ImportBatch(
      source: 'fitnotes',
      exercises: const [ImportedExercise(key: '7', name: 'squat', kind: ExerciseKind.weightReps), ImportedExercise(key: '8', name: 'Plank', kind: ExerciseKind.time)],
      days: [
        ImportedDay(day: d1, slots: [(exerciseKey: '7', sets: [const SetEntry(grams: 100000, reps: 5, status: Done())])]),
        ImportedDay(day: d2, note: 'tired', slots: [(exerciseKey: '8', sets: [const SetEntry(seconds: 60, status: Done())])]),
      ],
    );

    test('running it twice converges on the same history', () {
      final first = store.importBatch(batch);
      final after = store.recentWorkouts();
      final second = store.importBatch(batch);
      expect(store.recentWorkouts(), after);
      expect((first.setsWritten, first.exercisesLinked, first.exercisesCreated), (2, 1, 1));
      expect(second.exercisesCreated, 0);
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
    });
  });

  // TODO: migrate an empty file through every entry of _migrations, build a second database by executing schema.sql, and compare `SELECT type, name, sql FROM sqlite_master ORDER BY name` between them. A changed old migration or a forgotten new one fails here.
}

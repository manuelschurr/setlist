import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';

const squat = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps);
const bench = Exercise(id: ExerciseId(2), name: 'Bench press', kind: ExerciseKind.weightReps);
final at = DateTime(2026, 11, 12, 18, 30);

SetEntry kg(num weight, int reps, {bool done = false, bool warmup = false}) => SetEntry(grams: (weight * 1000).round(), reps: reps, warmup: warmup, status: done ? Done(at) : const Planned());

DayState open(List<Slot> slots) => DayState.open(Workout(day: Day.parse('2026-11-12'), slots: slots));

SetRef ref(Exercise e, int index) => (exercise: e.id, index: index);

List<num> weights(DayState s, Exercise e) => [for (final x in s.workout.slotOf(e.id)!.sets) x.grams / 1000];

List<int> reps(DayState s, Exercise e) => [for (final x in s.workout.slotOf(e.id)!.sets) x.reps];

void main() {
  group('cascade', () {
    test('one plus tap on set 1 turns a copied 3 x 5 at 100 kg into 3 x 5 at 102.5 kg', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5), kg(100, 5)])]);
      final next = reduce(s, SetField(ref(squat, 0), Field.weight, Field.weight.stepped(squat, 100000, up: true)));
      expect(weights(next, squat), [102.5, 102.5, 102.5]);
      expect(reps(next, squat), [5, 5, 5]);
    });

    test('warm-up and back-off sets keep their own weight', () {
      final s = open([Slot(squat, [kg(60, 5, warmup: true), kg(100, 5), kg(100, 5), kg(100, 5), kg(80, 8)])]);
      final next = reduce(s, SetField(ref(squat, 1), Field.weight, 105000));
      expect(weights(next, squat), [60, 105, 105, 105, 80]);
    });

    test('done sets never change by cascade', () {
      final s = open([Slot(squat, [kg(100, 5, done: true), kg(100, 5), kg(100, 5, done: true), kg(100, 5)])]);
      final next = reduce(s, SetField(ref(squat, 0), Field.weight, 105000));
      expect(weights(next, squat), [105, 105, 100, 105]);
    });

    test('earlier sets do not follow', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5), kg(100, 5)])]);
      final next = reduce(s, SetField(ref(squat, 1), Field.weight, 105000));
      expect(weights(next, squat), [100, 105, 105]);
    });

    test('each field cascades on its own', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5), kg(100, 8)])]);
      final next = reduce(s, SetField(ref(squat, 0), Field.reps, 6));
      expect(reps(next, squat), [6, 6, 8]);
      expect(weights(next, squat), [100, 100, 100]);
    });

    test('setting the value a set already holds changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
      expect(identical(reduce(s, SetField(ref(squat, 0), Field.weight, 100000)).workout, s.workout), isTrue);
    });
  });

  group('focus', () {
    test('opens on the first planned set in workout order', () {
      final s = open([Slot(squat, [kg(100, 5, done: true)]), Slot(bench, [kg(80, 5, done: true), kg(80, 5)])]);
      expect(s.focus, ref(bench, 1));
    });

    test('logging moves to the next planned set of the same exercise', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
      expect(reduce(s, LogSet(ref(squat, 0), at: at)).focus, ref(squat, 1));
    });

    test('logging the last set of an exercise moves to the next unfinished exercise, with no dialog state', () {
      final s = open([Slot(squat, [kg(100, 5, done: true), kg(100, 5)]), Slot(bench, [kg(80, 5), kg(80, 5)])]);
      expect(reduce(s, LogSet(ref(squat, 1), at: at)).focus, ref(bench, 0));
    });

    test('an exercise skipped earlier comes back next', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      s = reduce(s, FocusSet(ref(bench, 0)));
      s = reduce(s, LogSet(ref(bench, 0), at: at));
      expect(s.focus, ref(squat, 0));
    });

    test('logging the last planned set leaves nothing focused, so the panel shows the summary', () {
      final s = open([Slot(squat, [kg(100, 5, done: true), kg(100, 5)])]);
      expect(reduce(s, LogSet(ref(squat, 1), at: at)).focus, isNull);
    });

    test('checking the circle on another row keeps the panel on its set', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      final next = reduce(s, LogSet(ref(bench, 0), at: at));
      expect(next.focus, ref(squat, 0));
      expect(next.workout.setAt(ref(bench, 0))!.isDone, isTrue);
    });

    test('dragging a card keeps the focus on the same set', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5), kg(80, 5)])]);
      s = reduce(s, FocusSet(ref(bench, 1)));
      s = reduce(s, const MoveExercise(1, 0));
      expect(s.workout.slots.first.exercise, bench);
      expect(s.focus, ref(bench, 1));
    });
  });

  group('add and copy', () {
    test('adding an exercise plans its last session', () {
      final s = open([]);
      final next = reduce(s, AddExercise(squat, lastSession: [kg(100, 5, done: true), kg(100, 3, done: true)]));
      expect(next.workout.slotOf(squat.id)!.sets, [kg(100, 5), kg(100, 3)]);
      expect(next.focus, ref(squat, 0));
    });

    test('adding an exercise never done plans one empty set', () {
      final next = reduce(open([]), const AddExercise(squat, lastSession: []));
      expect(next.workout.slotOf(squat.id)!.sets, [const SetEntry()]);
    });

    test('adding an exercise the day already has leaves the day as it was', () {
      final s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      final next = reduce(s, const AddExercise(bench, lastSession: []));
      expect(identical(next.workout, s.workout), isTrue);
      expect(next.focus, ref(bench, 0));
    });

    test('copying a day appends only the exercises the day lacks, every set planned', () {
      final s = open([Slot(squat, [kg(100, 5)])]);
      final past = Workout(day: Day.parse('2026-11-09'), slots: [Slot(squat, [kg(90, 5, done: true)]), Slot(bench, [kg(80, 5, done: true), kg(80, 5, done: true)])]);
      final next = reduce(s, CopyDay(past));
      expect(next.workout.slots.map((x) => x.exercise), [squat, bench]);
      expect(weights(next, squat), [100]);
      expect(next.workout.slotOf(bench.id)!.sets, [kg(80, 5), kg(80, 5)]);
    });
  });
}

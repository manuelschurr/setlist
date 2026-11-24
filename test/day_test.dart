import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';

const squat = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Equipment.none);
const bench = Exercise(id: ExerciseId(2), name: 'Bench press', kind: ExerciseKind.weightReps, equipment: Equipment.none);
const row = Exercise(id: ExerciseId(3), name: 'Row', kind: ExerciseKind.weightReps, equipment: Equipment.none);
const press = Exercise(id: ExerciseId(5), name: 'Overhead press', kind: ExerciseKind.weightReps, equipment: Equipment.none);
const dip = Exercise(id: ExerciseId(6), name: 'Dip', kind: ExerciseKind.reps, equipment: Equipment.none);
final today = Day.parse('2026-11-12');
final at = DateTime(2026, 11, 12, 18, 30);

SetEntry kg(num weight, int reps, {bool done = false, bool warmup = false, String note = ''}) => SetEntry(grams: (weight * 1000).round(), reps: reps, warmup: warmup, note: note, status: done ? Done(at) : const Planned());

DayState open(List<Entry> entries) => DayState.open(Workout(day: today, entries: entries));

SetRef ref(Exercise e, int index) => (exercise: e.id, index: index);

List<num> weights(DayState s, Exercise e) => [for (final x in s.workout.slotOf(e.id)!.sets) x.grams / 1000];

List<int> reps(DayState s, Exercise e) => [for (final x in s.workout.slotOf(e.id)!.sets) x.reps];

/// The day's arrangement as exercise names rather than ids, so a failure reads as names.
List<List<String>> arrangement(DayState s) => [
  for (final entry in s.workout.entries) [for (final slot in entry.slots) slot.exercise.name],
];

List<List<String>> named(List<List<Exercise>> groups) => [
  for (final group in groups) [for (final e in group) e.name],
];

Layout ids(List<List<Exercise>> groups) => [
  for (final group in groups) [for (final e in group) e.id],
];

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

    test('other exercises do not follow', () {
      final s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(100, 5)])]);
      final next = reduce(s, SetField(ref(squat, 0), Field.weight, 105000));
      expect(weights(next, bench), [100]);
    });

    test('setting the value a set already holds changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
      expect(identical(reduce(s, SetField(ref(squat, 0), Field.weight, 100000)), s), isTrue);
    });
  });

  group('focus', () {
    test('opens on the first planned set in workout order', () {
      final s = open([Slot(squat, [kg(100, 5, done: true)]), Slot(bench, [kg(80, 5, done: true), kg(80, 5)])]);
      expect(s.focus, ref(bench, 1));
    });

    test('opens on nothing when no set is planned', () {
      expect(open([Slot(squat, [kg(100, 5, done: true)])]).focus, isNull);
      expect(open([]).focus, isNull);
    });

    test('logging moves to the next planned set of the same exercise', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
      final next = reduce(s, LogSet(ref(squat, 0), at: at));
      expect(next.focus, ref(squat, 1));
      expect(next.workout.setAt(ref(squat, 0))!.status, Done(at));
    });

    test('logging the last set wraps to a set skipped earlier in the same exercise before leaving it', () {
      var s = open([Slot(bench, [kg(80, 5)]), Slot(squat, [kg(100, 5, done: true), kg(100, 5), kg(100, 5)])]);
      s = reduce(s, FocusSet(ref(squat, 2)));
      s = reduce(s, LogSet(ref(squat, 2), at: at));
      expect(s.focus, ref(squat, 1));
    });

    test('logging the last set of an exercise moves to the next unfinished exercise, with no dialog state', () {
      final s = open([Slot(squat, [kg(100, 5, done: true), kg(100, 5)]), Slot(bench, [kg(80, 5), kg(80, 5)])]);
      expect(reduce(s, LogSet(ref(squat, 1), at: at)).focus, ref(bench, 0));
    });

    test('an exercise skipped earlier comes back next', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])]);
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

    test('logging a corrected done set keeps its time and moves on, like a Next set button', () {
      var s = open([Slot(squat, [kg(100, 5, done: true), kg(100, 5)])]);
      s = reduce(s, FocusSet(ref(squat, 0)));
      final next = reduce(s, LogSet(ref(squat, 0), at: at.add(const Duration(minutes: 5))));
      expect(identical(next.workout, s.workout), isTrue);
      expect(next.workout.setAt(ref(squat, 0))!.status, Done(at));
      expect(next.focus, ref(squat, 1));
    });

    test('a focus tap on another set changes only the focus', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
      final next = reduce(s, FocusSet(ref(squat, 1)));
      expect(next.focus, ref(squat, 1));
      expect(identical(next.workout, s.workout), isTrue);
    });

    test('unlogging a set makes it planned again, keeps its note and takes the focus', () {
      final s = open([Slot(squat, [kg(100, 5, done: true, note: 'grindy'), kg(100, 5)])]);
      final next = reduce(s, UnlogSet(ref(squat, 0)));
      expect(next.workout.setAt(ref(squat, 0)), kg(100, 5, note: 'grindy'));
      expect(next.focus, ref(squat, 0));
    });
  });

  group('add, copy, reorder and remove', () {
    test('adding an exercise plans its last session without its notes and focuses it', () {
      final s = open([Slot(bench, [kg(80, 5)])]);
      final next = reduce(s, AddExercise(squat, lastSession: [kg(100, 5, done: true, note: 'belt'), kg(100, 3, done: true)]));
      expect(next.workout.slots.map((x) => x.exercise), [bench, squat]);
      expect(next.workout.slotOf(squat.id)!.sets, [kg(100, 5), kg(100, 3)]);
      expect(next.focus, ref(squat, 0));
    });

    test('adding an exercise never done plans one empty set', () {
      final next = reduce(open([]), const AddExercise(squat, lastSession: []));
      expect(next.workout.slotOf(squat.id)!.sets, [const SetEntry()]);
    });

    test('adding an exercise the day already has leaves the day as it was and scrolls to its first planned set', () {
      final s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5, done: true), kg(80, 5)])]);
      final next = reduce(s, const AddExercise(bench, lastSession: []));
      expect(identical(next.workout, s.workout), isTrue);
      expect(next.focus, ref(bench, 1));
    });

    test('adding a finished exercise the day already has scrolls to its first set', () {
      final s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5, done: true)])]);
      expect(reduce(s, const AddExercise(bench, lastSession: [])).focus, ref(bench, 0));
    });

    test('copying a day appends only the exercises the day lacks, every set planned and without notes', () {
      final s = open([Slot(squat, [kg(100, 5)])]);
      final past = Workout(day: Day.parse('2026-11-09'), note: 'heavy', entries: [Slot(squat, [kg(90, 5, done: true)]), Slot(bench, [kg(80, 5, done: true, note: 'pause'), kg(80, 5, done: true)])]);
      final next = reduce(s, CopyDay(past));
      expect(next.workout.slots.map((x) => x.exercise), [squat, bench]);
      expect(weights(next, squat), [100]);
      expect(next.workout.slotOf(bench.id)!.sets, [kg(80, 5), kg(80, 5)]);
      expect(next.workout.note, '');
      expect(next.focus, ref(squat, 0));
    });

    test('copying into an empty day focuses the first copied set', () {
      final past = Workout(day: Day.parse('2026-11-09'), entries: [Slot(bench, [kg(80, 5, done: true)])]);
      expect(reduce(open([]), CopyDay(past)).focus, ref(bench, 0));
    });

    test('copying a day whose exercises are all here changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5)])]);
      final past = Workout(day: Day.parse('2026-11-09'), entries: [Slot(squat, [kg(90, 5, done: true)])]);
      expect(identical(reduce(s, CopyDay(past)), s), isTrue);
    });

    test('arranging puts the exercises in the order and grouping asked for and keeps the focus on the same set', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)])]);
      s = reduce(s, FocusSet(ref(bench, 1)));
      s = reduce(s, Arrange(ids([[bench], [squat], [row]])));
      expect(arrangement(s), named([[bench], [squat], [row]]));
      expect(s.focus, ref(bench, 1));
      s = reduce(s, Arrange(ids([[squat], [row, bench]])));
      expect(arrangement(s), named([[squat], [row, bench]]));
      expect(s.workout.entries.last, isA<Superset>());
      expect(s.focus, ref(bench, 1));
      expect(weights(s, bench), [80, 80]);
    });

    test('an arrangement the day already has returns the same state', () {
      final s = open([Slot(squat, [kg(100, 5)]), Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])])]);
      expect(identical(reduce(s, Arrange(ids([[squat], [bench, row]]))), s), isTrue);
    });

    test('an arrangement that does not name exactly the day exercises, each once, changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      for (final layout in [
        ids([[squat]]),
        ids([[squat], [bench], [row]]),
        ids([[squat], [squat]]),
        ids([[squat, bench], []]),
        ids([[bench], [row]]),
        <List<ExerciseId>>[],
      ]) {
        expect(identical(reduce(s, Arrange(layout)), s), isTrue, reason: '$layout');
      }
    });

    test('adding an exercise adds a plain one at the end, after a superset too', () {
      final s = open([Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])])]);
      expect(arrangement(reduce(s, const AddExercise(squat, lastSession: []))), named([[bench, row], [squat]]));
    });

    test('adding a set copies the last set as a planned working set without its note and focuses it', () {
      final s = open([Slot(squat, [kg(60, 5, warmup: true, done: true, note: 'easy')])]);
      final next = reduce(s, AddSet(squat.id));
      expect(next.workout.slotOf(squat.id)!.sets.last, kg(60, 5));
      expect(next.focus, ref(squat, 1));
    });

    test('removing the focused set focuses the planned set that takes its place', () {
      final s = open([Slot(squat, [kg(100, 5), kg(105, 5), kg(110, 5)])]);
      final next = reduce(s, RemoveSet(ref(squat, 0)));
      expect(weights(next, squat), [105, 110]);
      expect(next.focus, ref(squat, 0));
    });

    test('removing the focused last set wraps to a planned set earlier in the exercise', () {
      var s = open([Slot(bench, [kg(80, 5)]), Slot(squat, [kg(100, 5), kg(100, 5, done: true), kg(100, 5)])]);
      s = reduce(s, FocusSet(ref(squat, 2)));
      expect(reduce(s, RemoveSet(ref(squat, 2))).focus, ref(squat, 0));
    });

    test('a focus later in the same exercise shifts down with its set', () {
      var s = open([Slot(squat, [kg(100, 5), kg(105, 5), kg(110, 5)])]);
      s = reduce(s, FocusSet(ref(squat, 2)));
      final next = reduce(s, RemoveSet(ref(squat, 0)));
      expect(next.focus, ref(squat, 1));
      expect(next.workout.setAt(next.focus!)!.grams, 110000);
    });

    test('removing the only set removes the exercise and refocuses from the top', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      s = reduce(s, FocusSet(ref(bench, 0)));
      final next = reduce(s, RemoveSet(ref(bench, 0)));
      expect(next.workout.slots.map((x) => x.exercise), [squat]);
      expect(next.focus, ref(squat, 0));
    });

    test('removing an exercise that holds the focus refocuses from the top; one that does not keeps it', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      expect(reduce(s, RemoveExercise(squat.id)).focus, ref(bench, 0));
      s = reduce(s, FocusSet(ref(bench, 0)));
      expect(reduce(s, RemoveExercise(squat.id)).focus, ref(bench, 0));
    });

    test('a set note sits on one set and never cascades', () {
      final s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
      final next = reduce(s, SetSetNote(ref(squat, 0), 'left knee'));
      expect(next.workout.slotOf(squat.id)!.sets.map((x) => x.note), ['left knee', '']);
    });

    test('editing an exercise refreshes the copy its slot holds', () {
      final s = open([Slot(squat, [kg(100, 5)])]);
      const renamed = Exercise(id: ExerciseId(1), name: 'Back squat', kind: ExerciseKind.weightReps, equipment: Equipment.none, weightStepGrams: 1000);
      expect(reduce(s, const UpdateExercise(renamed)).workout.slots.single.exercise, renamed);
      expect(identical(reduce(s, const UpdateExercise(squat)), s), isTrue);
    });

    test('the day note changes only when it differs', () {
      final s = open([]);
      expect(reduce(s, const SetNote('deload')).workout.note, 'deload');
      expect(identical(reduce(s, const SetNote('')), s), isTrue);
    });
  });

  test('every command that names a set or exercise the day lacks returns the state unchanged', () {
    var s = open([Slot(squat, [kg(100, 5), kg(100, 5)])]);
    s = reduce(s, FocusSet(ref(squat, 1)));
    final stale = <Command>[
      FocusSet(ref(bench, 0)),
      FocusSet(ref(squat, 2)),
      FocusSet(ref(squat, -1)),
      SetField(ref(bench, 0), Field.weight, 1),
      SetField(ref(squat, 5), Field.reps, 1),
      SetWarmup(ref(bench, 0), warmup: true),
      SetSetNote(ref(squat, 9), 'x'),
      LogSet(ref(bench, 0), at: at),
      LogSet(ref(squat, 2), at: at),
      UnlogSet(ref(bench, 0)),
      AddSet(bench.id),
      RemoveSet(ref(bench, 0)),
      RemoveSet(ref(squat, 2)),
      RemoveExercise(bench.id),
      Arrange(ids([[bench]])),
      const Arrange([]),
      SupersetWith(bench.id, squat.id),
      SupersetWith(squat.id, bench.id),
      SupersetWith(squat.id, squat.id),
      const UpdateExercise(bench),
    ];
    for (final command in stale) {
      expect(identical(reduce(s, command), s), isTrue, reason: '${command.runtimeType} on a missing target');
    }
  });

  group('supersets in the day', () {
    test('copying a day brings its supersets, without the exercises the day already has, and one left alone arrives plain', () {
      final s = open([Slot(bench, [kg(85, 5)]), Slot(dip, [const SetEntry(reps: 10)])]);
      final past = Workout(day: Day.parse('2026-11-09'), entries: [
        Superset([Slot(squat, [kg(100, 5, done: true)]), Slot(bench, [kg(80, 5, done: true)])]),
        Superset([Slot(row, [kg(60, 8, done: true)]), Slot(press, [kg(40, 8, done: true)]), Slot(dip, [const SetEntry(reps: 12, status: Done())])]),
      ]);
      final next = reduce(s, CopyDay(past));
      expect(arrangement(next), named([[bench], [dip], [squat], [row, press]]));
      expect(next.workout.entries.last, Superset([Slot(row, [kg(60, 8)]), Slot(press, [kg(40, 8)])]));
      expect(weights(next, bench), [85]);
      expect(reps(next, dip), [10]);
    });

    test('copying into an empty day brings a superset whole', () {
      final past = Workout(day: Day.parse('2026-11-09'), entries: [Superset([Slot(bench, [kg(80, 5, done: true)]), Slot(row, [kg(60, 8, done: true)])])]);
      expect(arrangement(reduce(open([]), CopyDay(past))), named([[bench, row]]));
    });

    test('removing an exercise takes it out of its superset, and a pair becomes the plain exercise left', () {
      final pair = open([Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])]), Slot(squat, [kg(100, 5)])]);
      final next = reduce(pair, RemoveExercise(bench.id));
      expect(arrangement(next), named([[row], [squat]]));
      expect(next.workout.entries.first, isA<Slot>());
      final three = open([Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)]), Slot(press, [kg(40, 8)])])]);
      expect(arrangement(reduce(three, RemoveExercise(row.id))), named([[bench, press]]));
    });

    test('removing the last set of an exercise in a pair leaves the other as a plain exercise', () {
      final s = open([Slot(squat, [kg(100, 5)]), Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8), kg(60, 8)])])]);
      final next = reduce(s, RemoveSet(ref(bench, 0)));
      expect(arrangement(next), named([[squat], [row]]));
      expect(next.workout.entries.last, Slot(row, [kg(60, 8), kg(60, 8)]));
      expect(arrangement(reduce(s, RemoveSet(ref(row, 1)))), named([[squat], [bench, row]]));
    });

    test('set edits, logs, added sets and exercise edits inside a superset keep it together', () {
      final s = open([Slot(squat, [kg(100, 5)]), Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)])])]);
      final cascaded = reduce(s, SetField(ref(bench, 0), Field.weight, 82500));
      expect(weights(cascaded, bench), [82.5, 82.5]);
      const renamed = Exercise(id: ExerciseId(3), name: 'Barbell row', kind: ExerciseKind.weightReps, equipment: Equipment.none);
      for (final next in [
        cascaded,
        reduce(s, SetWarmup(ref(row, 0), warmup: true)),
        reduce(s, SetSetNote(ref(row, 0), 'strap')),
        reduce(s, LogSet(ref(row, 0), at: at)),
        reduce(reduce(s, LogSet(ref(row, 0), at: at)), UnlogSet(ref(row, 0))),
        reduce(s, AddSet(row.id)),
        reduce(s, const UpdateExercise(renamed)),
      ]) {
        expect(next.workout.layout, ids([[squat], [bench, row]]));
        expect(next.workout.entries.last, isA<Superset>());
      }
    });
  });

  group('superset with', () {
    test('two plain exercises start a superset, the added one right after the anchor', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])]);
      s = reduce(s, FocusSet(ref(bench, 0)));
      final next = reduce(s, SupersetWith(squat.id, row.id));
      expect(arrangement(next), named([[squat, row], [bench]]));
      expect(next.focus, ref(bench, 0));
    });

    test('an exercise joins the anchor superset right after the anchor', () {
      final s = open([Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])]), Slot(squat, [kg(100, 5)])]);
      expect(arrangement(reduce(s, SupersetWith(bench.id, squat.id))), named([[bench, squat, row]]));
      expect(arrangement(reduce(s, SupersetWith(row.id, squat.id))), named([[bench, row, squat]]));
      expect(arrangement(reduce(s, SupersetWith(squat.id, bench.id))), named([[row], [squat, bench]]), reason: 'leaving a pair makes the one left plain');
    });

    test('an exercise taken from another superset leaves it, and a pair it leaves dissolves', () {
      final pairs = open([Superset([Slot(squat, [kg(100, 5)]), Slot(press, [kg(40, 8)])]), Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)])])]);
      final next = reduce(pairs, SupersetWith(bench.id, press.id));
      expect(arrangement(next), named([[squat], [bench, press, row]]));
      expect(next.workout.entries.first, isA<Slot>());
      final three = open([Superset([Slot(squat, [kg(100, 5)]), Slot(press, [kg(40, 8)]), Slot(dip, [const SetEntry(reps: 10)])]), Slot(bench, [kg(80, 5)])]);
      expect(arrangement(reduce(three, SupersetWith(bench.id, press.id))), named([[squat, dip], [bench, press]]));
    });

    test('the same exercise, one already in the anchor superset, or one the day lacks changes nothing', () {
      final s = open([Superset([Slot(bench, [kg(80, 5)]), Slot(row, [kg(60, 8)]), Slot(press, [kg(40, 8)])]), Slot(squat, [kg(100, 5)])]);
      for (final command in [SupersetWith(bench.id, bench.id), SupersetWith(bench.id, press.id), SupersetWith(press.id, bench.id), SupersetWith(squat.id, dip.id), SupersetWith(dip.id, squat.id)]) {
        expect(identical(reduce(s, command), s), isTrue, reason: '${command.anchor} with ${command.added}');
      }
    });
  });

  group('focus in a superset', () {
    /// Logs the focused set [count] times and returns the exercise and set index the focus visited after each log.
    List<SetRef?> logFocused(DayState s, int count) {
      final visited = <SetRef?>[];
      for (var i = 0; i < count; i++) {
        s = reduce(s, LogSet(s.focus!, at: at));
        visited.add(s.focus);
      }
      return visited;
    }

    test('logging alternates between the exercises of the round, set by set', () {
      final s = open([Superset([Slot(bench, [kg(80, 5), kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8), kg(60, 8), kg(60, 8)])])]);
      expect(s.focus, ref(bench, 0));
      expect(logFocused(s, 6), [ref(row, 0), ref(bench, 1), ref(row, 1), ref(bench, 2), ref(row, 2), null]);
    });

    test('the round wraps back to the first exercise and skips one with nothing planned', () {
      final s = open([Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)]), Slot(press, [kg(40, 8), kg(40, 8)])])]);
      expect(logFocused(s, 4), [ref(row, 0), ref(press, 0), ref(bench, 1), ref(press, 1)]);
    });

    test('when only the logged exercise has planned sets left, the focus stays on it as on a plain exercise', () {
      final s = open([Superset([Slot(bench, [kg(80, 5), kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)])]), Slot(squat, [kg(100, 5)])]);
      expect(logFocused(s, 4), [ref(row, 0), ref(bench, 1), ref(bench, 2), ref(squat, 0)]);
    });

    test('with uneven set counts the round ends early, and a finished superset hands over to the first planned set from the top', () {
      var s = open([Slot(squat, [kg(100, 5)]), Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)])])]);
      s = reduce(s, FocusSet(ref(bench, 0)));
      expect(logFocused(s, 4), [ref(row, 0), ref(bench, 1), ref(squat, 0), null]);
    });

    test('checking the circle on another row of the superset leaves the panel where it is', () {
      final s = open([Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8), kg(60, 8)])])]);
      final next = reduce(s, LogSet(ref(row, 0), at: at));
      expect(next.focus, ref(bench, 0));
      expect(next.workout.setAt(ref(row, 0))!.isDone, isTrue);
    });

    test('the panel asks the same rule the log follows, for a planned set and for a corrected done one', () {
      var s = open([Slot(squat, [kg(100, 5)]), Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)]), Slot(press, [kg(40, 8), kg(40, 8)])])]);
      while (s.focus != null) {
        final focus = s.focus!;
        final next = reduce(s, LogSet(focus, at: at));
        expect(focusAfterLog(s.workout, focus), next.focus, reason: 'from $focus');
        expect(focusAfterLog(next.workout, focus), next.focus, reason: 'again from $focus once it is done');
        s = next;
      }
      s = reduce(open([Superset([Slot(bench, [kg(80, 5, done: true), kg(80, 5)]), Slot(row, [kg(60, 8)])])]), FocusSet(ref(bench, 0)));
      expect(focusAfterLog(s.workout, ref(bench, 0)), ref(row, 0));
      expect(reduce(s, LogSet(ref(bench, 0), at: at)).focus, ref(row, 0));
    });
  });

  group('rest in a superset', () {
    const quickRow = Exercise(id: ExerciseId(3), name: 'Row', kind: ExerciseKind.weightReps, equipment: Equipment.none, rest: Duration(seconds: 60));
    const slowPress = Exercise(id: ExerciseId(5), name: 'Overhead press', kind: ExerciseKind.weightReps, equipment: Equipment.none, rest: Duration(minutes: 3));

    test('no countdown while a later exercise of the round still has a planned set', () {
      var s = open([Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(quickRow, [kg(60, 8), kg(60, 8)])])]);
      s = reduce(s, LogSet(ref(bench, 0), at: at));
      expect(s.workout.restAt(at.add(const Duration(seconds: 1))), isNull);
    });

    test('the end of the round starts the countdown, which lasts the longest rest of the superset and names the exercise just logged', () {
      var s = open([Superset([Slot(slowPress, [kg(40, 8), kg(40, 8)]), Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(quickRow, [kg(60, 8), kg(60, 8)])])]);
      s = reduce(s, LogSet(ref(slowPress, 0), at: at));
      s = reduce(s, LogSet(ref(bench, 0), at: at.add(const Duration(minutes: 1))));
      expect(s.workout.restAt(at.add(const Duration(minutes: 1, seconds: 1))), isNull);
      final roundEnd = at.add(const Duration(minutes: 2));
      s = reduce(s, LogSet(ref(quickRow, 0), at: roundEnd));
      final rest = s.workout.restAt(roundEnd.add(const Duration(seconds: 1)));
      expect(rest?.exercise, quickRow);
      expect(rest?.endsAt, roundEnd.add(slowPress.rest));
    });

    test('with uneven set counts the countdown starts after an exercise whose later partners are finished', () {
      var s = open([Superset([Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(quickRow, [kg(60, 8)])]), Slot(squat, [kg(100, 5)])]);
      s = reduce(s, LogSet(ref(bench, 0), at: at));
      s = reduce(s, LogSet(ref(quickRow, 0), at: at.add(const Duration(minutes: 1))));
      final last = at.add(const Duration(minutes: 3));
      s = reduce(s, LogSet(ref(bench, 1), at: last));
      expect(s.workout.restAt(last), (exercise: bench, endsAt: last.add(bench.rest)));
    });

    test('a plain exercise rests by its own time, whatever supersets the day holds', () {
      var s = open([Slot(quickRow, [kg(60, 8), kg(60, 8)]), Superset([Slot(slowPress, [kg(40, 8)]), Slot(bench, [kg(80, 5)])])]);
      s = reduce(s, LogSet(ref(quickRow, 0), at: at));
      expect(s.workout.restAt(at), (exercise: quickRow, endsAt: at.add(quickRow.rest)));
    });
  });

  group('dragging in the list', () {
    Slot one(Exercise e) => Slot(e, [kg(50, 5)]);
    Workout day(List<Entry> entries) => Workout(day: today, entries: entries);

    /// The arrangement after the drop, applied the way the screen does, or null when the drop asks for nothing.
    List<List<String>>? drop(Workout w, int from, int to) {
      final layout = layoutAfterDrop(w, from, to);
      return layout == null ? null : arrangement(reduce(DayState.open(w), Arrange(layout)));
    }

    // Rows: 0 Squat, 1 top, 2 Bench, 3 Row, 4 bottom, 5 Press.
    final framed = day([one(squat), Superset([one(bench), one(row)]), one(press)]);

    test('a superset is a top row, its exercise rows and a bottom row, and a plain exercise is one row', () {
      final pair = framed.entries[1] as Superset;
      expect(listRows(framed), [ExerciseRow(squat.id), SupersetTop(pair), ExerciseRow(bench.id), ExerciseRow(row.id), SupersetBottom(pair), ExerciseRow(press.id)]);
    });

    test('without supersets a drop moves one card, and a drop where it started asks for nothing', () {
      final plain = day([one(squat), one(bench), one(row)]);
      expect(drop(plain, 0, 2), named([[bench], [row], [squat]]));
      expect(drop(plain, 2, 0), named([[row], [squat], [bench]]));
      expect(drop(plain, 1, 1), isNull);
    });

    test('an exercise dropped between a top and a bottom row joins that superset at that spot', () {
      expect(drop(framed, 5, 3), named([[squat], [bench, press, row]]));
      expect(drop(framed, 5, 2), named([[squat], [press, bench, row]]), reason: 'right below the top row is the first of the round');
      expect(drop(framed, 5, 4), named([[squat], [bench, row, press]]), reason: 'right above the bottom row is the last of the round');
      expect(drop(framed, 0, 3), named([[bench, row, squat], [press]]));
    });

    test('an exercise dropped outside every frame is plain, right at either edge too', () {
      expect(drop(framed, 5, 1), named([[squat], [press], [bench, row]]), reason: 'right above the top row');
      expect(drop(framed, 0, 4), named([[bench, row], [squat], [press]]), reason: 'right below the bottom row');
    });

    test('dragging an exercise out of a pair dissolves it, and within a superset changes the round order', () {
      expect(drop(framed, 2, 0), named([[bench], [squat], [row], [press]]));
      expect(drop(framed, 3, 5), named([[squat], [bench], [press], [row]]));
      expect(drop(framed, 2, 3), named([[squat], [row, bench], [press]]));
      expect(drop(framed, 2, 2), isNull);
    });

    test('an exercise dragged from one superset into another leaves a pair behind as a plain exercise', () {
      // Rows: 0 Press, 1 top, 2 Squat, 3 Dip, 4 bottom, 5 top, 6 Bench, 7 Row, 8 bottom.
      final two = day([one(press), Superset([one(squat), one(dip)]), Superset([one(bench), one(row)])]);
      expect(drop(two, 3, 6), named([[press], [squat], [bench, dip, row]]));
    });

    test('a top row moves its whole superset to the gap it was dropped in', () {
      expect(drop(framed, 1, 0), named([[bench, row], [squat], [press]]));
      expect(drop(framed, 1, 5), named([[squat], [press], [bench, row]]));
    });

    test('a top row dropped inside its own span or right next to it asks for nothing', () {
      for (final to in [1, 2, 3, 4]) {
        expect(drop(framed, 1, to), isNull, reason: 'gap $to');
      }
    });

    test('a top row dropped inside another superset lands right above it', () {
      // Rows: 0 Press, 1 top, 2 Squat, 3 Dip, 4 bottom, 5 top, 6 Bench, 7 Row, 8 bottom.
      final two = day([one(press), Superset([one(squat), one(dip)]), Superset([one(bench), one(row)])]);
      for (final to in [1, 2, 3, 4]) {
        expect(drop(two, 5, to), named([[press], [bench, row], [squat, dip]]), reason: 'gap $to');
      }
      expect(drop(two, 1, 6), isNull, reason: 'right above the superset below is where it already is');
      expect(drop(two, 1, 8), named([[press], [bench, row], [squat, dip]]));
    });

    test('a bottom row never moves, and indexes outside the list ask for nothing', () {
      expect(drop(framed, 4, 0), isNull);
      expect(drop(framed, -1, 0), isNull);
      expect(drop(framed, 6, 0), isNull);
      expect(drop(framed, 0, 6), isNull);
      expect(drop(framed, 0, -1), isNull);
    });
  });

  group('last time', () {
    test('an added warm-up today does not shift the working sets', () {
      final last = [kg(100, 5, done: true), kg(100, 5, done: true), kg(95, 5, done: true)];
      final plan = [kg(60, 5, warmup: true), kg(100, 5), kg(100, 5), kg(100, 5)];
      expect(alignLastTime(plan, last), [null, last[0], last[1], last[2]]);
    });

    test('warm-ups pair with warm-ups by order, and extra sets get nothing', () {
      final last = [kg(40, 5, warmup: true, done: true), kg(60, 3, warmup: true, done: true), kg(100, 5, done: true)];
      final plan = [kg(40, 5, warmup: true), kg(100, 5), kg(60, 3, warmup: true), kg(100, 5)];
      expect(alignLastTime(plan, last), [last[0], last[2], last[1], null]);
      expect(alignLastTime(plan, []), [null, null, null, null]);
    });
  });

  group('values', () {
    test('weight shows kg with at most two decimals and no trailing zeros', () {
      expect(Field.weight.format(20412), '20.41');
      expect(Field.weight.format(100000), '100');
      expect(Field.weight.format(102500), '102.5');
      expect(Field.weight.format(1250), '1.25');
      expect(Field.weight.format(-10000), '-10');
      expect(Field.weight.format(0), '0');
    });

    test('weight parses a comma or a dot into grams', () {
      expect(Field.weight.parse('20,41'), 20410);
      expect(Field.weight.parse('20.41'), 20410);
      expect(Field.weight.parse(' 102.5 '), 102500);
      expect(Field.weight.parse('100'), 100000);
      expect(Field.weight.parse(',5'), 500);
      expect(Field.weight.parse('-12.5'), -12500);
      expect(Field.weight.parse('20.4117'), 20412);
      for (final bad in ['', '-', '.', 'abc', '1.2.3', '1,2,3', '1e3', '5 kg']) {
        expect(Field.weight.parse(bad), isNull, reason: bad);
      }
    });

    test('a shown weight parses back to the same text, and grams on a 10 g grid survive the trip exactly', () {
      expect(Field.weight.format(Field.weight.parse(Field.weight.format(20412))!), '20.41');
      for (final grams in [0, 10, 500, 1250, 20410, 100000, 102500, -2500]) {
        expect(Field.weight.parse(Field.weight.format(grams)), grams, reason: '$grams g');
      }
    });

    test('reps are whole non-negative counts', () {
      expect(Field.reps.format(5), '5');
      expect(Field.reps.parse('12'), 12);
      for (final bad in ['-1', '5.5', '', 'x']) {
        expect(Field.reps.parse(bad), isNull, reason: bad);
      }
    });

    test('distance shows metres below a kilometre and km from there', () {
      expect(Field.distance.format(400), '400 m');
      expect(Field.distance.format(999), '999 m');
      expect(Field.distance.format(1000), '1 km');
      expect(Field.distance.format(5200), '5.2 km');
      expect(Field.distance.parse('5,2 km'), 5200);
      expect(Field.distance.parse('5.2km'), 5200);
      expect(Field.distance.parse('400 m'), 400);
      expect(Field.distance.parse('400'), 400);
      for (final metres in [0, 1, 400, 999, 1000, 1001, 5200, 42195]) {
        expect(Field.distance.parse(Field.distance.format(metres)), metres, reason: '$metres m');
      }
      for (final bad in ['-5', 'km', '5 miles', '']) {
        expect(Field.distance.parse(bad), isNull, reason: bad);
      }
    });

    test('time shows m:ss and parses m:ss or plain seconds', () {
      expect(Field.time.format(90), '1:30');
      expect(Field.time.format(5), '0:05');
      expect(Field.time.format(3600), '60:00');
      expect(Field.time.parse('1:30'), 90);
      expect(Field.time.parse('90'), 90);
      for (final seconds in [0, 5, 59, 60, 90, 3600]) {
        expect(Field.time.parse(Field.time.format(seconds)), seconds, reason: '$seconds s');
      }
      for (final bad in ['1:60', '1:5', '-5', '1.5', '']) {
        expect(Field.time.parse(bad), isNull, reason: bad);
      }
    });

    test('a stepper tap moves weight by the exercise increment and stops reps, distance and time at zero', () {
      const dumbbell = Exercise(id: ExerciseId(9), name: 'Curl', kind: ExerciseKind.weightReps, equipment: Equipment.none, weightStepGrams: 1000);
      expect(Field.weight.stepped(dumbbell, 12000, up: true), 13000);
      expect(Field.weight.stepped(dumbbell, 0, up: false), -1000);
      expect(Field.reps.stepped(dumbbell, 5, up: false), 4);
      expect(Field.reps.stepped(dumbbell, 0, up: false), 0);
      expect(Field.distance.stepped(dumbbell, 50, up: false), 0);
      expect(Field.distance.stepped(dumbbell, 400, up: true), 500);
      expect(Field.time.stepped(dumbbell, 3, up: false), 0);
      expect(Field.time.stepped(dumbbell, 60, up: true), 65);
    });

    test('a set describes the fields its kind shows', () {
      expect(kg(102.5, 5).describe(ExerciseKind.weightReps), '102.5 × 5');
      expect(const SetEntry(seconds: 90).describe(ExerciseKind.time), '1:30');
    });
  });

  group('rest', () {
    const short = Exercise(id: ExerciseId(4), name: 'Curl', kind: ExerciseKind.weightReps, equipment: Equipment.none, rest: Duration(seconds: 60));

    test('counts down from the latest log by that exercise rest, then ends', () {
      var s = open([Slot(squat, [kg(100, 5), kg(100, 5)]), Slot(short, [kg(10, 10), kg(10, 10)])]);
      s = reduce(s, LogSet(ref(squat, 0), at: at));
      s = reduce(s, LogSet(ref(short, 0), at: at.add(const Duration(seconds: 30))));
      final rest = s.workout.restAt(at.add(const Duration(seconds: 40)));
      expect(rest?.exercise, short);
      expect(rest?.endsAt, at.add(const Duration(seconds: 90)));
      expect(s.workout.restAt(at.add(const Duration(seconds: 90))), isNull);
    });

    test('a rest that spans midnight keeps counting into the next day', () {
      final lateNight = DateTime(2026, 11, 12, 23, 59);
      final logged = reduce(open([Slot(squat, [kg(100, 5), kg(100, 5)])]), LogSet(ref(squat, 0), at: lateNight));
      final rest = logged.workout.restAt(DateTime(2026, 11, 13, 0, 0, 30));
      expect(rest?.exercise, squat);
      expect(rest?.endsAt, lateNight.add(squat.rest));
    });

    test('nothing counts down before any log, after an import without times, or when nothing is planned', () {
      final logged = reduce(open([Slot(squat, [kg(100, 5), kg(100, 5)])]), LogSet(ref(squat, 0), at: at));
      expect(open([Slot(squat, [kg(100, 5)])]).workout.restAt(at), isNull);
      expect(open([Slot(squat, [const SetEntry(status: Done()), kg(100, 5)])]).workout.restAt(at), isNull);
      final finished = reduce(logged, LogSet(ref(squat, 1), at: at));
      expect(finished.workout.restAt(at.add(const Duration(seconds: 1))), isNull);
    });

    test('undoing a log by unlogging it ends its countdown', () {
      final logged = reduce(open([Slot(squat, [kg(100, 5), kg(100, 5)])]), LogSet(ref(squat, 0), at: at));
      expect(logged.workout.restAt(at), isNotNull);
      expect(reduce(logged, UnlogSet(ref(squat, 0))).workout.restAt(at), isNull);
    });
  });

  test('summary counts done sets, working-set volume and the time from first to last log', () {
    final w = Workout(day: today, entries: [
      Slot(squat, [SetEntry(grams: 60000, reps: 5, warmup: true, status: Done(at)), SetEntry(grams: 100000, reps: 5, status: Done(at.add(const Duration(minutes: 3)))), kg(100, 5)]),
      Slot(bench, [SetEntry(grams: 80000, reps: 5, status: Done(at.add(const Duration(minutes: 20))))]),
    ]);
    expect(w.summary, (doneSets: 3, volumeGrams: 100000 * 5 + 80000 * 5, elapsed: const Duration(minutes: 20)));
    expect(Workout(day: today).summary, (doneSets: 0, volumeGrams: 0, elapsed: null));
  });

  test('the top set is the heaviest done working set, then the most reps', () {
    final slot = Slot(squat, [kg(140, 1, warmup: true, done: true), kg(100, 5, done: true), kg(100, 6, done: true), kg(120, 1), kg(90, 8, done: true)]);
    expect(slot.topSet, kg(100, 6, done: true));
    expect(Slot(squat, [kg(100, 5)]).topSet, isNull);
  });

  test('a day is a real calendar date', () {
    expect(Day.parse('2026-11-12').iso, '2026-11-12');
    expect(Day.parse('2024-02-29').date, DateTime(2024, 2, 29));
    for (final bad in ['2026-02-30', '2025-02-29', '2026-13-01', '2026-1-1', '20261112', '']) {
      expect(() => Day.parse(bad), throwsFormatException, reason: bad);
    }
    expect(Day.of(DateTime(2026, 1, 5, 23, 59)), Day.parse('2026-01-05'));
    expect(Day.parse('2026-11-09').isBefore(today), isTrue);
  });

  test('a day holds each exercise once, a slot is never empty and a superset holds at least two exercises', () {
    expect(() => Workout(day: today, entries: [Slot(squat, [kg(100, 5)]), Slot(squat, [kg(90, 5)])]), throwsArgumentError);
    expect(() => Workout(day: today, entries: [Slot(squat, [kg(100, 5)]), Superset([Slot(bench, [kg(80, 5)]), Slot(squat, [kg(90, 5)])])]), throwsArgumentError);
    expect(() => Slot(squat, []), throwsArgumentError);
    expect(() => Superset([Slot(squat, [kg(100, 5)])]), throwsArgumentError);
    expect(() => Superset([]), throwsArgumentError);
  });

  group('equipment', () {
    test('a barbell splits the total into the bar and what goes on each side', () {
      const bar = Barbell(20000);
      expect(bar.breakdown(60000), '20 kg a side · 20 kg bar');
      expect(bar.breakdown(62500), '21.25 kg a side · 20 kg bar');
      expect(bar.breakdown(102500), '41.25 kg a side · 20 kg bar');
      expect(bar.breakdown(20000), 'just the 20 kg bar');
      expect(bar.breakdown(15000), 'less than the 20 kg bar');
      expect(const Barbell(7500).breakdown(27500), '10 kg a side · 7.5 kg bar');
    });

    test('odd gram halves show the half the formatter would round the exact half to', () {
      expect(const Barbell(20000).breakdown(40015), '10.01 kg a side · 20 kg bar');
      expect(const Barbell(20000).breakdown(40009), '10 kg a side · 20 kg bar');
      expect(Equipment.dumbbellPair.breakdown(12345), '6.17 kg each');
      expect(Equipment.dumbbellPair.breakdown(12350), '6.18 kg each');
      for (var grams = 1; grams <= 50000; grams++) {
        final exactHalfRoundedTo10g = (grams + 10) ~/ 20 * 10;
        expect(Equipment.dumbbellPair.breakdown(grams), '${Field.weight.format(exactHalfRoundedTo10g)} kg each', reason: '$grams g');
      }
    });

    test('a pair shows each dumbbell', () {
      expect(Equipment.dumbbellPair.breakdown(12000), '6 kg each');
      expect(Equipment.dumbbellPair.breakdown(5000), '2.5 kg each');
    });

    test('a total of 0 or less keeps the line of a pair or barbell but leaves it blank', () {
      for (final grams in [0, -5000]) {
        expect(Equipment.dumbbellPair.breakdown(grams), '', reason: '$grams g');
        expect(const Barbell(20000).breakdown(grams), '', reason: '$grams g');
      }
    });

    test('an adjustable pair splits each dumbbell into its plates and the handle', () {
      const pair = DumbbellPair(handleGrams: 2500);
      expect(pair.breakdown(14000), '7 kg each (4.5 + 2.5 kg)');
      expect(pair.breakdown(47000), '23.5 kg each (21 + 2.5 kg)');
      expect(pair.breakdown(14250), '7.13 kg each (4.63 + 2.5 kg)');
      expect(pair.breakdown(5000), 'just the 2.5 kg handles');
      expect(pair.breakdown(4000), 'less than the 2.5 kg handles');
      expect(const DumbbellPair(handleGrams: 2000).breakdown(12000), '6 kg each (4 + 2 kg)');
    });

    test('one adjustable dumbbell splits into its plates and the handle', () {
      const one = OneDumbbell(handleGrams: 2500);
      expect(one.breakdown(7000), '4.5 kg + 2.5 kg handle');
      expect(one.breakdown(2500), 'just the 2.5 kg handle');
      expect(one.breakdown(2000), 'less than the 2.5 kg handle');
    });

    test('a total of 0 or less keeps the line of an adjustable dumbbell but leaves it blank', () {
      for (final grams in [0, -5000]) {
        expect(const DumbbellPair(handleGrams: 2500).breakdown(grams), '', reason: '$grams g');
        expect(const OneDumbbell(handleGrams: 2500).breakdown(grams), '', reason: '$grams g');
      }
    });

    test('the handle is part of the equipment, and a pair and one dumbbell on the same handle differ', () {
      expect(const DumbbellPair(handleGrams: 2500), const DumbbellPair(handleGrams: 2500));
      expect(const DumbbellPair(handleGrams: 2500), isNot(Equipment.dumbbellPair));
      expect(const DumbbellPair(handleGrams: 2500), isNot(const DumbbellPair(handleGrams: 2000)));
      expect(const DumbbellPair(handleGrams: 2500), isNot(const OneDumbbell(handleGrams: 2500)));
      expect(Equipment.dumbbellPair, isNot(Equipment.oneDumbbell));
    });

    test('no equipment and one fixed dumbbell never have a line, whatever the total', () {
      for (final grams in [-5000, 0, 6000, 100000]) {
        expect(Equipment.none.breakdown(grams), isNull, reason: '$grams g');
        expect(Equipment.oneDumbbell.breakdown(grams), isNull, reason: '$grams g');
      }
    });

    test('the choices hold every kind of equipment once', () {
      String kindOf(Equipment e) => switch (e) {
        NoEquipment() => 'none',
        Barbell() => 'barbell',
        DumbbellPair() => 'pair',
        OneDumbbell() => 'one',
      };
      final choices = Equipment.choices(barGrams: 20000);
      expect(choices.map(kindOf).toSet(), {'none', 'barbell', 'pair', 'one'});
      expect(choices.map((e) => e.name).toSet(), hasLength(4));
      expect(choices.map((e) => e.label).toSet(), hasLength(4));
    });

    test('a stored name parses back, a bar only on a barbell and a handle only on a dumbbell, each above 0', () {
      for (final e in [...Equipment.choices(barGrams: 15000), ...Equipment.choices(barGrams: 15000, handleGrams: 2500)]) {
        expect(Equipment.named(e.name, barGrams: e is Barbell ? e.barGrams : null, handleGrams: e is Dumbbell ? e.handleGrams : null), e);
      }
      expect(Equipment.named('oneDumbbell', handleGrams: 2500), const OneDumbbell(handleGrams: 2500));
      expect(() => Equipment.named('kettlebell'), throwsFormatException);
      expect(() => Equipment.named('barbell'), throwsFormatException);
      expect(() => Equipment.named('barbell', barGrams: 0), throwsFormatException);
      expect(() => Equipment.named('dumbbellPair', barGrams: 20000), throwsFormatException);
      expect(() => Equipment.named('dumbbellPair', handleGrams: 0), throwsFormatException);
      expect(() => Equipment.named('barbell', barGrams: 20000, handleGrams: 2500), throwsFormatException);
      expect(() => Equipment.named('none', handleGrams: 2500), throwsFormatException);
    });

    test('a kind without a weight has no equipment, whatever was set', () {
      const plank = Exercise(id: ExerciseId(9), name: 'Plank', kind: ExerciseKind.time, equipment: Barbell(20000));
      expect(plank.equipment, Equipment.none);
      expect(plank, const Exercise(id: ExerciseId(9), name: 'Plank', kind: ExerciseKind.time, equipment: Equipment.none));
    });

    test('an edit of only the equipment, the bar or the handle refreshes the slot, and the same equipment changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5)])]);
      const pair = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Equipment.dumbbellPair);
      expect(reduce(s, const UpdateExercise(pair)).workout.slots.single.exercise.equipment, Equipment.dumbbellPair);
      const barbell = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Barbell(20000));
      final loaded = open([Slot(barbell, [kg(100, 5)])]);
      const lighter = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps, equipment: Barbell(15000));
      expect(reduce(loaded, const UpdateExercise(lighter)).workout.slots.single.exercise.equipment, const Barbell(15000));
      expect(identical(reduce(loaded, const UpdateExercise(barbell)), loaded), isTrue);
      const adjustable = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps, equipment: DumbbellPair(handleGrams: 2500));
      expect(reduce(reduce(s, const UpdateExercise(pair)), const UpdateExercise(adjustable)).workout.slots.single.exercise.equipment, const DumbbellPair(handleGrams: 2500));
    });
  });
}

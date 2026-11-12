import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';

const squat = Exercise(id: ExerciseId(1), name: 'Squat', kind: ExerciseKind.weightReps);
const bench = Exercise(id: ExerciseId(2), name: 'Bench press', kind: ExerciseKind.weightReps);
const row = Exercise(id: ExerciseId(3), name: 'Row', kind: ExerciseKind.weightReps);
final today = Day.parse('2026-11-12');
final at = DateTime(2026, 11, 12, 18, 30);

SetEntry kg(num weight, int reps, {bool done = false, bool warmup = false, String note = ''}) => SetEntry(grams: (weight * 1000).round(), reps: reps, warmup: warmup, note: note, status: done ? Done(at) : const Planned());

DayState open(List<Slot> slots) => DayState.open(Workout(day: today, slots: slots));

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
      final past = Workout(day: Day.parse('2026-11-09'), note: 'heavy', slots: [Slot(squat, [kg(90, 5, done: true)]), Slot(bench, [kg(80, 5, done: true, note: 'pause'), kg(80, 5, done: true)])]);
      final next = reduce(s, CopyDay(past));
      expect(next.workout.slots.map((x) => x.exercise), [squat, bench]);
      expect(weights(next, squat), [100]);
      expect(next.workout.slotOf(bench.id)!.sets, [kg(80, 5), kg(80, 5)]);
      expect(next.workout.note, '');
      expect(next.focus, ref(squat, 0));
    });

    test('copying into an empty day focuses the first copied set', () {
      final past = Workout(day: Day.parse('2026-11-09'), slots: [Slot(bench, [kg(80, 5, done: true)])]);
      expect(reduce(open([]), CopyDay(past)).focus, ref(bench, 0));
    });

    test('copying a day whose exercises are all here changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5)])]);
      final past = Workout(day: Day.parse('2026-11-09'), slots: [Slot(squat, [kg(90, 5, done: true)])]);
      expect(identical(reduce(s, CopyDay(past)), s), isTrue);
    });

    test('dragging a card moves it in one step and keeps the focus on the same set', () {
      var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5), kg(80, 5)]), Slot(row, [kg(60, 8)])]);
      s = reduce(s, FocusSet(ref(bench, 1)));
      s = reduce(s, const MoveExercise(1, 0));
      expect(s.workout.slots.map((x) => x.exercise), [bench, squat, row]);
      expect(s.focus, ref(bench, 1));
      s = reduce(s, const MoveExercise(0, 2));
      expect(s.workout.slots.map((x) => x.exercise), [squat, row, bench]);
    });

    test('a drag that ends where it started changes nothing', () {
      final s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
      expect(identical(reduce(s, const MoveExercise(1, 1)), s), isTrue);
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
      const renamed = Exercise(id: ExerciseId(1), name: 'Back squat', kind: ExerciseKind.weightReps, weightStepGrams: 1000);
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
      const MoveExercise(0, 1),
      const MoveExercise(-1, 0),
      const UpdateExercise(bench),
    ];
    for (final command in stale) {
      expect(identical(reduce(s, command), s), isTrue, reason: '${command.runtimeType} on a missing target');
    }
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
      const dumbbell = Exercise(id: ExerciseId(9), name: 'Curl', kind: ExerciseKind.weightReps, weightStepGrams: 1000);
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
    const short = Exercise(id: ExerciseId(4), name: 'Curl', kind: ExerciseKind.weightReps, rest: Duration(seconds: 60));

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
    final w = Workout(day: today, slots: [
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

  test('a day holds each exercise once and a slot is never empty', () {
    expect(() => Workout(day: today, slots: [Slot(squat, [kg(100, 5)]), Slot(squat, [kg(90, 5)])]), throwsArgumentError);
    expect(() => Slot(squat, []), throwsArgumentError);
  });
}

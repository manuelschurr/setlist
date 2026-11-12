/// The day aggregate and every rule that changes it.
///
/// A [Workout] is one calendar day, holding a note and an ordered list of [Slot]s, each one exercise with its ordered sets. [reduce] is the only way to change a day, and it is a pure function from [DayState] to [DayState]. The cascade and focus rules are therefore unit-tested without Flutter or SQLite, and undo is keeping the previous value.
///
/// This file imports only dart:core, so `flutter test test/day_test.dart` runs it on the VPS with no device.
library;

/// A local calendar day, the key of a [Workout]. Wraps `YYYY-MM-DD`, which sorts in date order and is how both Setlist rows and FitNotes backups store days.
extension type const Day._(String iso) implements Object {
  /// Parses `YYYY-MM-DD` and throws [FormatException] for anything that is not a real calendar date, so every [Day] downstream is valid.
  factory Day.parse(String text) {
    // TODO: require ^\d{4}-\d{2}-\d{2}$, then require DateTime.utc(y, m, d) to give back the same y, m, d, which rejects 2026-02-30.
    throw UnimplementedError();
  }

  /// The local calendar day of [time]. A session that runs past midnight stays on the day its screen opened, because the screen holds its [Day] and never asks the clock again.
  factory Day.of(DateTime time) => throw UnimplementedError();

  bool isBefore(Day other) => iso.compareTo(other.iso) < 0;
}

/// The database id of an exercise. Inside a day it is also the identity of the exercise's [Slot], because an exercise appears at most once per day.
extension type const ExerciseId(int value) implements Object {}

/// Points at one set of a day by its exercise's slot and its position in that slot. It is a natural key, so dragging a card never invalidates it.
typedef SetRef = ({ExerciseId exercise, int index});

/// One measured quantity of a set. Every value is an integer in a fixed base unit, so the cascade compares with exact equality, and no caller outside this enum knows the units.
enum Field {
  /// Grams. Negative values are allowed for assisted lifts.
  weight,

  /// Repetitions.
  reps,

  /// Metres.
  distance,

  /// Seconds.
  time;

  int read(SetEntry set) => switch (this) {
    weight => set.grams,
    reps => set.reps,
    distance => set.metres,
    time => set.seconds,
  };

  SetEntry write(SetEntry set, int value) => switch (this) {
    weight => set.copyWith(grams: value),
    reps => set.copyWith(reps: value),
    distance => set.copyWith(metres: value),
    time => set.copyWith(seconds: value),
  };

  /// The value one stepper tap moves [value] to. Weight steps by the exercise's own increment, reps by 1, distance by 100 m, time by 5 s. Reps, distance and time stop at zero.
  int stepped(Exercise exercise, int value, {required bool up}) => throw UnimplementedError();

  /// Display text for a value: `102.5` for weight in kg, `5`, `5.2 km` or `400 m`, `1:30`.
  String format(int value) => throw UnimplementedError();

  /// Parses what the lifter typed into the base unit, or null when it is not a value for this field. Accepts a comma as the decimal separator. The inverse of [format].
  int? parse(String text) => throw UnimplementedError();
}

/// Which fields an exercise records. The ten combinations match FitNotes' exercise types, so an import loses nothing. The list order is the order of the steppers in the panel and of the values in a row.
enum ExerciseKind {
  weightReps([Field.weight, Field.reps]),
  distanceTime([Field.distance, Field.time]),
  weightDistance([Field.weight, Field.distance]),
  weightTime([Field.weight, Field.time]),
  repsDistance([Field.reps, Field.distance]),
  repsTime([Field.reps, Field.time]),
  weight([Field.weight]),
  reps([Field.reps]),
  distance([Field.distance]),
  time([Field.time]);

  const ExerciseKind(this.fields);

  final List<Field> fields;
}

/// Whether a set has been done. Sealed so a planned set cannot carry a log time.
sealed class SetStatus {
  const SetStatus();
}

final class Planned extends SetStatus {
  const Planned();

  @override
  bool operator ==(Object other) => other is Planned;

  @override
  int get hashCode => 0;
}

final class Done extends SetStatus {
  const Done([this.at]);

  /// When the lifter logged it. Null only for imported sets, because a FitNotes backup keeps no time per set.
  final DateTime? at;

  @override
  bool operator ==(Object other) => other is Done && other.at == at;

  @override
  int get hashCode => at.hashCode;
}

/// One set. Holds every field in its base unit; the exercise's kind decides which ones the row and the panel show. Fields the kind does not use stay 0, as in FitNotes.
final class SetEntry {
  const SetEntry({this.grams = 0, this.reps = 0, this.metres = 0, this.seconds = 0, this.warmup = false, this.status = const Planned()});

  final int grams;
  final int reps;
  final int metres;
  final int seconds;
  final bool warmup;
  final SetStatus status;

  bool get isDone => status is Done;
  bool get isPlanned => status is Planned;

  /// The same values as a planned set. Copying a day and adding an exercise from its last session both produce this.
  SetEntry get asPlanned => isPlanned ? this : copyWith(status: const Planned());

  SetEntry copyWith({int? grams, int? reps, int? metres, int? seconds, bool? warmup, SetStatus? status}) => SetEntry(grams: grams ?? this.grams, reps: reps ?? this.reps, metres: metres ?? this.metres, seconds: seconds ?? this.seconds, warmup: warmup ?? this.warmup, status: status ?? this.status);

  /// The values the kind shows, such as `100 × 5`. Used for the muted "last time" text and the collapsed card header.
  String describe(ExerciseKind kind) => kind.fields.map((f) => f.format(f.read(this))).join(' × ');

  @override
  bool operator ==(Object other) => other is SetEntry && other.grams == grams && other.reps == reps && other.metres == metres && other.seconds == seconds && other.warmup == warmup && other.status == status;

  @override
  int get hashCode => Object.hash(grams, reps, metres, seconds, warmup, status);
}

/// An exercise as a day sees it. A [Slot] holds a copy; the exercise table in the store owns the original, and [UpdateExercise] refreshes the copy after an edit.
final class Exercise {
  const Exercise({required this.id, required this.name, required this.kind, this.category, this.weightStepGrams = 2500, this.rest = const Duration(minutes: 2)});

  final ExerciseId id;
  final String name;
  final ExerciseKind kind;
  final String? category;
  final int weightStepGrams;
  final Duration rest;

  @override
  bool operator ==(Object other) => other is Exercise && other.id == id && other.name == name && other.kind == kind && other.category == category && other.weightStepGrams == weightStepGrams && other.rest == rest;

  @override
  int get hashCode => Object.hash(id, name, kind, category, weightStepGrams, rest);
}

/// One exercise in a day with its ordered sets. List position is the set number. Never empty. The constructor throws on an empty list, and removing the last set removes the slot.
final class Slot {
  Slot(this.exercise, List<SetEntry> sets) : sets = List.unmodifiable(sets) {
    if (sets.isEmpty) throw ArgumentError.value(sets, 'sets', 'a slot has at least one set');
  }

  final Exercise exercise;
  final List<SetEntry> sets;

  /// Every set is done. A finished card collapses to its header.
  bool get finished => sets.every((s) => s.isDone);

  int get doneCount => sets.where((s) => s.isDone).length;

  /// The best done working set, for the collapsed header and the history list. Compares the kind's fields in order, larger first. Warm-ups never count. Null when no working set is done.
  SetEntry? get topSet => throw UnimplementedError();

  @override
  bool operator ==(Object other) => other is Slot && other.exercise == exercise && _sameList(other.sets, sets);

  @override
  int get hashCode => Object.hash(exercise, Object.hashAll(sets));
}

/// The countdown after a logged set, with its exercise and the time it ends.
typedef Rest = ({Exercise exercise, DateTime endsAt});

/// What the panel shows when no planned set remains. Volume is the sum of grams × reps over done working sets.
typedef Summary = ({int doneSets, int volumeGrams, Duration? elapsed});

/// One calendar day of training, the aggregate. List order of [slots] is the order on screen, so reordering is a list move.
final class Workout {
  /// Throws [ArgumentError] when two slots hold the same exercise. The store and the importer both build workouts through here, so no path produces a day with a duplicate.
  Workout({required this.day, this.note = '', List<Slot> slots = const []}) : slots = List.unmodifiable(slots) {
    final seen = <ExerciseId>{};
    for (final slot in slots) {
      if (!seen.add(slot.exercise.id)) throw ArgumentError.value(slot.exercise.name, 'slots', 'an exercise appears at most once per day');
    }
  }

  final Day day;
  final String note;
  final List<Slot> slots;

  /// The store deletes an empty day instead of saving it.
  bool get isEmpty => slots.isEmpty && note.isEmpty;

  int indexOf(ExerciseId exercise) => slots.indexWhere((s) => s.exercise.id == exercise);

  Slot? slotOf(ExerciseId exercise) {
    final i = indexOf(exercise);
    return i < 0 ? null : slots[i];
  }

  SetEntry? setAt(SetRef ref) {
    final sets = slotOf(ref.exercise)?.sets;
    return sets == null || ref.index < 0 || ref.index >= sets.length ? null : sets[ref.index];
  }

  /// Every set in workout order, slot by slot and set by set.
  Iterable<SetRef> get refs sync* {
    for (final slot in slots) {
      for (var i = 0; i < slot.sets.length; i++) {
        yield (exercise: slot.exercise.id, index: i);
      }
    }
  }

  /// The rest countdown at [now], derived from the log times, never stored. Undo, app restarts and edits during rest therefore need no timer state.
  Rest? restAt(DateTime now) {
    // TODO(rest):
    //   if (Day.of(now) != day) return null                      // logging on a past day starts no countdown
    //   if (!refs.any((r) => setAt(r)!.isPlanned)) return null    // the workout is over; the panel shows the summary
    //   latest = the Done set with the greatest non-null `at`, with its slot's exercise; null when none
    //   endsAt = latest.at + exercise.rest
    //   return endsAt.isAfter(now) ? (exercise: exercise, endsAt: endsAt) : null
    throw UnimplementedError();
  }

  Summary get summary => throw UnimplementedError();

  @override
  bool operator ==(Object other) => other is Workout && other.day == day && other.note == note && _sameList(other.slots, slots);

  @override
  int get hashCode => Object.hash(day, note, Object.hashAll(slots));
}

/// What the workout screen shows, which is the day and the set the panel edits. Only [DayState.open] and [reduce] build one, and both keep [focus] pointing at a set that exists.
final class DayState {
  DayState._(this.workout, this.focus) : assert(focus == null || workout.setAt(focus) != null);

  /// Focus goes to the first planned set in workout order, or null when none is planned.
  factory DayState.open(Workout workout) => DayState._(workout, _firstPlanned(workout));

  final Workout workout;

  /// The set the panel edits. Null means no planned set remains and the panel shows the summary. It may point at a done set the lifter tapped to correct.
  final SetRef? focus;
}

/// Everything the lifter can do to a day. Sealed, so [reduce] and every switch over commands in the UI fail to compile when a command is added and not handled.
sealed class Command {
  const Command();
}

/// Tapping a set row. Focus moves to [ref]; the workout does not change.
final class FocusSet extends Command {
  const FocusSet(this.ref);
  final SetRef ref;
}

/// A stepper tap or a typed value. Runs the cascade. Focus stays.
final class SetField extends Command {
  const SetField(this.ref, this.field, this.value);
  final SetRef ref;
  final Field field;
  final int value;
}

final class SetWarmup extends Command {
  const SetWarmup(this.ref, {required this.warmup});
  final SetRef ref;
  final bool warmup;
}

/// The panel's Log button, or a row's check circle. [at] comes from the caller so [reduce] stays pure.
final class LogSet extends Command {
  const LogSet(this.ref, {required this.at});
  final SetRef ref;
  final DateTime at;
}

/// A row's check circle on a done set. The set becomes planned and takes the focus.
final class UnlogSet extends Command {
  const UnlogSet(this.ref);
  final SetRef ref;
}

/// Appends a planned copy of the exercise's last set and focuses it.
final class AddSet extends Command {
  const AddSet(this.exercise);
  final ExerciseId exercise;
}

/// Removes a set. Removing the only set of a slot removes the exercise.
final class RemoveSet extends Command {
  const RemoveSet(this.ref);
  final SetRef ref;
}

/// Adds an exercise from the picker. [lastSession] is what the store's previous-session lookup returned, so [reduce] needs no database.
final class AddExercise extends Command {
  const AddExercise(this.exercise, {required this.lastSession});
  final Exercise exercise;
  final List<SetEntry> lastSession;
}

final class RemoveExercise extends Command {
  const RemoveExercise(this.exercise);
  final ExerciseId exercise;
}

/// Dragging a card. [to] is the index the card ends up at, counted after it is removed from [from]. The screen converts Flutter's reorder index to this.
final class MoveExercise extends Command {
  const MoveExercise(this.from, this.to);
  final int from;
  final int to;
}

/// Appends each exercise of [source] that this day does not have yet, with all its sets copied as planned.
final class CopyDay extends Command {
  const CopyDay(this.source);
  final Workout source;
}

final class SetNote extends Command {
  const SetNote(this.note);
  final String note;
}

/// Refreshes a slot's copy of an exercise after the lifter edits its name, increment or rest.
final class UpdateExercise extends Command {
  const UpdateExercise(this.exercise);
  final Exercise exercise;
}

/// Applies [command] to [state]. It is pure, so the same inputs always give the same output.
///
/// Returns the identical [Workout] instance whenever the command does not change the day (a focus tap, a value set to what it already was, adding an exercise the day already has). The screen relies on that to skip the save and keep the undo offer. A command that names a set or an exercise the day does not hold returns [state] unchanged.
DayState reduce(DayState state, Command command) {
  final w = state.workout;
  return switch (command) {
    FocusSet(:final ref) => w.setAt(ref) == null ? state : DayState._(w, ref),
    SetField(:final ref, :final field, :final value) => DayState._(_cascade(w, ref, field, value), state.focus),
    SetWarmup(:final ref, :final warmup) => DayState._(_replaceSet(w, ref, (s) => s.copyWith(warmup: warmup)), state.focus),
    LogSet(:final ref, :final at) => _log(state, ref, at),
    UnlogSet(:final ref) => w.setAt(ref) == null ? state : DayState._(_replaceSet(w, ref, (s) => s.asPlanned), ref),
    AddSet(:final exercise) => _addSet(state, exercise),
    RemoveSet(:final ref) => _removeSet(state, ref),
    AddExercise(:final exercise, :final lastSession) => _addExercise(state, exercise, lastSession),
    RemoveExercise(:final exercise) => _removeExercise(state, exercise),
    MoveExercise(:final from, :final to) => DayState._(_move(w, from, to), state.focus),
    CopyDay(:final source) => _copyDay(state, source),
    SetNote(:final note) => note == w.note ? state : DayState._(Workout(day: w.day, note: note, slots: w.slots), state.focus),
    UpdateExercise(:final exercise) => DayState._(_updateExercise(w, exercise), state.focus),
  };
}

/// The cascade. Sets [field] of the set at [ref] to [value], and sets [value] on every later set of the same exercise that is still planned and whose [field] held the edited set's old value. Done sets never change by cascade. Sets with another value are left alone, so warm-ups and back-off sets survive an edit to the working sets. The edited set itself may be done, so correcting a logged set still updates the planned ones after it. Returns [w] itself when nothing changes.
Workout _cascade(Workout w, SetRef ref, Field field, int value) {
  // TODO(cascade):
  //   i = w.indexOf(ref.exercise); if (i < 0) return w
  //   sets = w.slots[i].sets; if (ref.index >= sets.length) return w
  //   old = field.read(sets[ref.index]); if (old == value) return w
  //   next = [...sets]
  //   next[ref.index] = field.write(sets[ref.index], value)
  //   for j in ref.index + 1 ..< sets.length:
  //     if (sets[j].isPlanned && field.read(sets[j]) == old) next[j] = field.write(sets[j], value)
  //   return _withSlot(w, i, Slot(w.slots[i].exercise, next))
  // Compare against `sets` (before the edit), never `next`, so one edit is exactly one sweep.
  throw UnimplementedError();
}

/// Marks the set at [ref] done at [at], then moves focus.
///
/// Focus moves only when the logged set held the focus, or when the focus was on no planned set. It then goes to the next planned set after [ref] in the same exercise, else to the first planned set from the top of the workout (an exercise skipped for a busy rack comes back next), else to null and the panel shows the summary. Checking the circle on some other row leaves the panel where it is. Logging a set that is already done keeps its original time and still moves focus; that is the panel's "Next set" button on a corrected set.
DayState _log(DayState state, SetRef ref, DateTime at) {
  // TODO(focus-after-log):
  //   w = state.workout; target = w.setAt(ref); if (target == null) return state
  //   logged = target.isDone ? w : _replaceSet(w, ref, (s) => s.copyWith(status: Done(at)))
  //   current = state.focus
  //   advance = current == null || current == ref || !w.setAt(current)!.isPlanned
  //   if (!advance) return DayState._(logged, current)
  //   return DayState._(logged, _nextPlannedAfter(logged, ref) ?? _firstPlanned(logged))
  throw UnimplementedError();
}

/// Appends [exercise] with planned copies of [lastSession] (one empty set when it was never done) and focuses its first set. When the day already has the exercise, the workout stays identical and focus moves to that slot's first planned set, or its first set when all are done, so the screen scrolls there.
DayState _addExercise(DayState state, Exercise exercise, List<SetEntry> lastSession) => throw UnimplementedError();

/// Appends each slot of [source] whose exercise this day lacks, with every set as [SetEntry.asPlanned]. The note is not copied. Focus stays unless it was null, then goes to the first planned set.
DayState _copyDay(DayState state, Workout source) {
  // TODO(copy-day):
  //   have = {for (s in w.slots) s.exercise.id}
  //   added = [for (s in source.slots) if (!have.contains(s.exercise.id)) Slot(s.exercise, [for (x in s.sets) x.asPlanned])]
  //   if (added.isEmpty) return state
  //   next = Workout(day: w.day, note: w.note, slots: [...w.slots, ...added])
  //   return DayState._(next, state.focus ?? _firstPlanned(next))
  throw UnimplementedError();
}

/// Removes the set at [ref]; the only set of a slot removes the slot. When the removed set held the focus, focus goes to the planned set now at that position, else the next planned one, else the first planned from the top. A focus later in the same slot shifts down by one.
DayState _removeSet(DayState state, SetRef ref) => throw UnimplementedError();

/// Removes the slot. When the focus was in it, focus goes to the first planned set.
DayState _removeExercise(DayState state, ExerciseId exercise) => throw UnimplementedError();

/// Appends a planned copy of the slot's last set (same values, not a warm-up) and focuses it.
DayState _addSet(DayState state, ExerciseId exercise) => throw UnimplementedError();

/// Moves the slot at [from] so it ends at [to]. Returns [w] itself when [from] == [to].
Workout _move(Workout w, int from, int to) => throw UnimplementedError();

/// Replaces the slot's copy of the exercise with the same id. Returns [w] itself when the day lacks it or it is unchanged.
Workout _updateExercise(Workout w, Exercise exercise) => throw UnimplementedError();

/// Applies [change] to one set. Returns [w] itself when [ref] is missing or [change] gives an equal set.
Workout _replaceSet(Workout w, SetRef ref, SetEntry Function(SetEntry) change) => throw UnimplementedError();

Workout _withSlot(Workout w, int index, Slot slot) => Workout(day: w.day, note: w.note, slots: [...w.slots]..[index] = slot);

SetRef? _firstPlanned(Workout w) {
  for (final ref in w.refs) {
    if (w.setAt(ref)!.isPlanned) return ref;
  }
  return null;
}

SetRef? _nextPlannedAfter(Workout w, SetRef ref) {
  final sets = w.slotOf(ref.exercise)!.sets;
  for (var i = ref.index + 1; i < sets.length; i++) {
    if (sets[i].isPlanned) return (exercise: ref.exercise, index: i);
  }
  return null;
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

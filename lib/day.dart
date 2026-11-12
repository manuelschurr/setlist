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
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
    if (match != null) {
      final [year, month, day] = [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
      final date = DateTime.utc(year, month, day);
      if (date.year == year && date.month == month && date.day == day) return Day._(text);
    }
    throw FormatException('not a calendar day in the form YYYY-MM-DD', text);
  }

  /// The local calendar day of [time]. A session that runs past midnight stays on the day its screen opened, because the screen holds its [Day] and never asks the clock again.
  factory Day.of(DateTime time) {
    final local = time.toLocal();
    return Day._('${local.year.toString().padLeft(4, '0')}-${_twoDigits(local.month)}-${_twoDigits(local.day)}');
  }

  /// Local midnight at the start of this day, for showing its weekday and date.
  DateTime get date => DateTime(int.parse(iso.substring(0, 4)), int.parse(iso.substring(5, 7)), int.parse(iso.substring(8)));

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
  int stepped(Exercise exercise, int value, {required bool up}) {
    final step = switch (this) {
      weight => exercise.weightStepGrams,
      reps => 1,
      distance => 100,
      time => 5,
    };
    final next = up ? value + step : value - step;
    return this == weight || next >= 0 ? next : 0;
  }

  /// Display text for a value. Weight is kg with at most two decimals and no trailing zeros (`20.41`, `100`, `102.5`), so a converted 20412 g reads cleanly while storage stays exact. Reps is the count. Distance is `400 m` below a kilometre and `5.2 km` from there. Time is `m:ss`.
  String format(int value) => switch (this) {
    weight => _thousandths(value, decimals: 2),
    reps => '$value',
    distance => value < 1000 ? '$value m' : '${_thousandths(value, decimals: 3)} km',
    time => '${value ~/ 60}:${_twoDigits(value % 60)}',
  };

  /// Parses what the lifter typed into the base unit, or null when it is not a value for this field. The inverse of [format]: a comma works as the decimal separator, distance takes an optional `m` or `km` (bare numbers are metres), and time takes `m:ss` or plain seconds. Only weight may be negative.
  int? parse(String text) {
    final input = text.trim().replaceAll(',', '.');
    switch (this) {
      case weight:
        return _parseThousandths(input);
      case reps:
        return RegExp(r'^\d+$').hasMatch(input) ? int.tryParse(input) : null;
      case distance:
        final match = RegExp(r'^(.*?)\s*(km|m)?$', caseSensitive: false).firstMatch(input)!;
        final number = _parseThousandths(match[1]!);
        if (number == null || number < 0) return null;
        return match[2]?.toLowerCase() == 'km' ? number : (number + 500) ~/ 1000;
      case time:
        final clock = RegExp(r'^(\d+):([0-5]\d)$').firstMatch(input);
        if (clock != null) return int.parse(clock[1]!) * 60 + int.parse(clock[2]!);
        return RegExp(r'^\d+$').hasMatch(input) ? int.tryParse(input) : null;
    }
  }
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
  const SetEntry({this.grams = 0, this.reps = 0, this.metres = 0, this.seconds = 0, this.warmup = false, this.note = '', this.status = const Planned()});

  final int grams;
  final int reps;
  final int metres;
  final int seconds;
  final bool warmup;

  /// The lifter's note on this one set, shown under its values. Empty when there is none.
  final String note;
  final SetStatus status;

  bool get isDone => status is Done;
  bool get isPlanned => status is Planned;

  /// What this set becomes in a new plan: the same values and warm-up flag, planned, and no note, because a note describes the session it was written in. Copying a day and adding an exercise from its last session both produce this.
  SetEntry get asPlan => SetEntry(grams: grams, reps: reps, metres: metres, seconds: seconds, warmup: warmup);

  SetEntry copyWith({int? grams, int? reps, int? metres, int? seconds, bool? warmup, String? note, SetStatus? status}) => SetEntry(grams: grams ?? this.grams, reps: reps ?? this.reps, metres: metres ?? this.metres, seconds: seconds ?? this.seconds, warmup: warmup ?? this.warmup, note: note ?? this.note, status: status ?? this.status);

  /// The values the kind shows, such as `100 × 5`. Used for the muted "last time" text and the collapsed card header.
  String describe(ExerciseKind kind) => kind.fields.map((f) => f.format(f.read(this))).join(' × ');

  @override
  bool operator ==(Object other) => other is SetEntry && other.grams == grams && other.reps == reps && other.metres == metres && other.seconds == seconds && other.warmup == warmup && other.note == note && other.status == status;

  @override
  int get hashCode => Object.hash(grams, reps, metres, seconds, warmup, note, status);
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

  /// The best done working set, for the collapsed header and the history list. Compares the kind's fields in order, larger first, and the earlier set wins a tie. Warm-ups never count. Null when no working set is done.
  SetEntry? get topSet {
    SetEntry? best;
    for (final set in sets) {
      if (set.isDone && !set.warmup && (best == null || _compareFields(exercise.kind, set, best) > 0)) best = set;
    }
    return best;
  }

  @override
  bool operator ==(Object other) => other is Slot && other.exercise == exercise && _sameList(other.sets, sets);

  @override
  int get hashCode => Object.hash(exercise, Object.hashAll(sets));
}

/// The countdown after a logged set, with its exercise and the time it ends.
typedef Rest = ({Exercise exercise, DateTime endsAt});

/// What the panel shows when no planned set remains. [doneSets] counts warm-ups too. Volume is the sum of grams × reps over done working sets. [elapsed] runs from the first log time to the last, null when no set carries one.
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
  ///
  /// It runs from the latest log time plus that set's exercise rest, whatever the calendar day of [now], so a rest that spans midnight keeps counting. It is null once it has ended and when no planned set remains (the panel shows the summary instead).
  Rest? restAt(DateTime now) {
    if (_firstPlanned(this) == null) return null;
    ({DateTime at, Exercise exercise})? latest;
    for (final slot in slots) {
      for (final set in slot.sets) {
        if (set.status case Done(:final at?) when latest == null || at.isAfter(latest.at)) latest = (at: at, exercise: slot.exercise);
      }
    }
    if (latest == null) return null;
    final endsAt = latest.at.add(latest.exercise.rest);
    return endsAt.isAfter(now) ? (exercise: latest.exercise, endsAt: endsAt) : null;
  }

  Summary get summary {
    var doneSets = 0;
    var volumeGrams = 0;
    DateTime? first;
    DateTime? last;
    for (final slot in slots) {
      for (final set in slot.sets) {
        if (set.status case Done(:final at)) {
          doneSets++;
          if (!set.warmup) volumeGrams += set.grams * set.reps;
          if (at != null) {
            if (first == null || at.isBefore(first)) first = at;
            if (last == null || at.isAfter(last)) last = at;
          }
        }
      }
    }
    return (doneSets: doneSets, volumeGrams: volumeGrams, elapsed: first == null || last == null ? null : last.difference(first));
  }

  @override
  bool operator ==(Object other) => other is Workout && other.day == day && other.note == note && _sameList(other.slots, slots);

  @override
  int get hashCode => Object.hash(day, note, Object.hashAll(slots));
}

/// What the lifter did last time on each set of [today], one entry per set, for the muted text under each row. Warm-ups pair with warm-ups and working sets with working sets, each by its order among its own kind, so adding a warm-up today does not shift every working set's comparison by one. A set with no counterpart gets null.
List<SetEntry?> alignLastTime(List<SetEntry> today, List<SetEntry> lastSession) {
  final warmups = lastSession.where((s) => s.warmup).iterator;
  final working = lastSession.where((s) => !s.warmup).iterator;
  SetEntry? take(Iterator<SetEntry> pool) => pool.moveNext() ? pool.current : null;
  return [for (final set in today) take(set.warmup ? warmups : working)];
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

/// The note on one set. It never cascades.
final class SetSetNote extends Command {
  const SetSetNote(this.ref, this.note);
  final SetRef ref;
  final String note;
}

/// The panel's Log button, or a row's check circle. [at] comes from the caller so [reduce] stays pure.
final class LogSet extends Command {
  const LogSet(this.ref, {required this.at});
  final SetRef ref;
  final DateTime at;
}

/// A row's check circle on a done set. The set becomes planned, keeps its values and note, and takes the focus.
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

/// The note on the whole day.
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
/// Returns the identical [Workout] instance whenever the command does not change the day (a focus tap, a value set to what it already was, adding an exercise the day already has). The screen relies on that to skip the save and keep the undo offer. A command that names a set or an exercise the day does not hold, such as one from an undo snapshot or a stale callback, returns [state] itself.
DayState reduce(DayState state, Command command) {
  final w = state.workout;
  return switch (command) {
    FocusSet(:final ref) => w.setAt(ref) == null ? state : _next(state, w, ref),
    SetField(:final ref, :final field, :final value) => _next(state, _cascade(w, ref, field, value), state.focus),
    SetWarmup(:final ref, :final warmup) => _next(state, _replaceSet(w, ref, (s) => s.copyWith(warmup: warmup)), state.focus),
    SetSetNote(:final ref, :final note) => _next(state, _replaceSet(w, ref, (s) => s.copyWith(note: note)), state.focus),
    LogSet(:final ref, :final at) => _log(state, ref, at),
    UnlogSet(:final ref) => w.setAt(ref) == null ? state : _next(state, _replaceSet(w, ref, (s) => s.copyWith(status: const Planned())), ref),
    AddSet(:final exercise) => _addSet(state, exercise),
    RemoveSet(:final ref) => _removeSet(state, ref),
    AddExercise(:final exercise, :final lastSession) => _addExercise(state, exercise, lastSession),
    RemoveExercise(:final exercise) => _removeExercise(state, exercise),
    MoveExercise(:final from, :final to) => _next(state, _move(w, from, to), state.focus),
    CopyDay(:final source) => _copyDay(state, source),
    SetNote(:final note) => note == w.note ? state : _next(state, Workout(day: w.day, note: note, slots: w.slots), state.focus),
    UpdateExercise(:final exercise) => _next(state, _updateExercise(w, exercise), state.focus),
  };
}

/// [state] itself when neither the workout instance nor the focus changed, so a no-op command hands back exactly what it got.
DayState _next(DayState state, Workout workout, SetRef? focus) => identical(workout, state.workout) && focus == state.focus ? state : DayState._(workout, focus);

/// The cascade. Sets [field] of the set at [ref] to [value], and sets [value] on every later set of the same exercise that is still planned and whose [field] held the edited set's old value. Done sets never change by cascade. Sets with another value are left alone, so warm-ups and back-off sets survive an edit to the working sets. The edited set itself may be done, so correcting a logged set still updates the planned ones after it. Returns [w] itself when nothing changes.
Workout _cascade(Workout w, SetRef ref, Field field, int value) {
  final edited = w.setAt(ref);
  if (edited == null) return w;
  final old = field.read(edited);
  if (old == value) return w;
  final i = w.indexOf(ref.exercise);
  final sets = w.slots[i].sets;
  final next = [...sets];
  next[ref.index] = field.write(edited, value);
  for (var j = ref.index + 1; j < sets.length; j++) {
    if (sets[j].isPlanned && field.read(sets[j]) == old) next[j] = field.write(sets[j], value);
  }
  return _withSlot(w, i, Slot(w.slots[i].exercise, next));
}

/// Marks the set at [ref] done at [at], then moves focus.
///
/// Focus moves only when the logged set held the focus, or when the focus was on no planned set. It then goes to the next planned set after [ref] in the same exercise, else to the first planned set of that exercise (one skipped within it), else to the first planned set from the top of the workout (an exercise skipped for a busy rack comes back next), else to null and the panel shows the summary. Checking the circle on some other row leaves the panel where it is. Logging a set that is already done keeps its original time and still moves focus; that is the panel's "Next set" button on a corrected set.
DayState _log(DayState state, SetRef ref, DateTime at) {
  final w = state.workout;
  final target = w.setAt(ref);
  if (target == null) return state;
  final logged = target.isDone ? w : _replaceSet(w, ref, (s) => s.copyWith(status: Done(at)));
  final current = state.focus;
  final advance = current == null || current == ref || w.setAt(current)?.isPlanned != true;
  return _next(state, logged, advance ? _plannedFrom(logged, ref.exercise, ref.index + 1) : current);
}

/// Appends [exercise] with planned copies of [lastSession] (one empty set when it was never done) and focuses its first set. When the day already has the exercise, the workout stays identical and focus moves to that slot's first planned set, or its first set when all are done, so the screen scrolls there.
DayState _addExercise(DayState state, Exercise exercise, List<SetEntry> lastSession) {
  final w = state.workout;
  final existing = w.slotOf(exercise.id);
  if (existing != null) {
    final planned = existing.sets.indexWhere((s) => s.isPlanned);
    return _next(state, w, (exercise: exercise.id, index: planned < 0 ? 0 : planned));
  }
  final sets = lastSession.isEmpty ? const [SetEntry()] : [for (final s in lastSession) s.asPlan];
  return DayState._(Workout(day: w.day, note: w.note, slots: [...w.slots, Slot(exercise, sets)]), (exercise: exercise.id, index: 0));
}

/// Appends each slot of [source] whose exercise this day lacks, with every set as [SetEntry.asPlan]. The note is not copied. Focus stays unless it was null, then goes to the first planned set.
DayState _copyDay(DayState state, Workout source) {
  final w = state.workout;
  final added = [
    for (final slot in source.slots)
      if (w.indexOf(slot.exercise.id) < 0) Slot(slot.exercise, [for (final s in slot.sets) s.asPlan]),
  ];
  if (added.isEmpty) return state;
  final next = Workout(day: w.day, note: w.note, slots: [...w.slots, ...added]);
  return DayState._(next, state.focus ?? _firstPlanned(next));
}

/// Removes the set at [ref]; the only set of a slot removes the slot. When the removed set held the focus, focus goes to the planned set now at that position or after it in the same exercise, else the first planned set of that exercise, else the first planned set from the top. A focus later in the same slot shifts down by one.
DayState _removeSet(DayState state, SetRef ref) {
  final w = state.workout;
  if (w.setAt(ref) == null) return state;
  final i = w.indexOf(ref.exercise);
  final slot = w.slots[i];
  if (slot.sets.length == 1) return _removeExercise(state, ref.exercise);
  final next = _withSlot(w, i, Slot(slot.exercise, [...slot.sets]..removeAt(ref.index)));
  final focus = state.focus;
  if (focus == ref) return DayState._(next, _plannedFrom(next, ref.exercise, ref.index));
  if (focus != null && focus.exercise == ref.exercise && focus.index > ref.index) return DayState._(next, (exercise: focus.exercise, index: focus.index - 1));
  return DayState._(next, focus);
}

/// Removes the slot. When the focus was in it, focus goes to the first planned set.
DayState _removeExercise(DayState state, ExerciseId exercise) {
  final w = state.workout;
  final i = w.indexOf(exercise);
  if (i < 0) return state;
  final next = Workout(day: w.day, note: w.note, slots: [...w.slots]..removeAt(i));
  return DayState._(next, state.focus?.exercise == exercise ? _firstPlanned(next) : state.focus);
}

/// Appends a planned copy of the slot's last set (same values, not a warm-up, no note) and focuses it.
DayState _addSet(DayState state, ExerciseId exercise) {
  final w = state.workout;
  final i = w.indexOf(exercise);
  if (i < 0) return state;
  final slot = w.slots[i];
  final copy = slot.sets.last.asPlan.copyWith(warmup: false);
  return DayState._(_withSlot(w, i, Slot(slot.exercise, [...slot.sets, copy])), (exercise: exercise, index: slot.sets.length));
}

/// Moves the slot at [from] so it ends at [to]. Returns [w] itself when [from] == [to] or either is out of range.
Workout _move(Workout w, int from, int to) {
  final n = w.slots.length;
  if (from == to || from < 0 || from >= n || to < 0 || to >= n) return w;
  final slots = [...w.slots];
  slots.insert(to, slots.removeAt(from));
  return Workout(day: w.day, note: w.note, slots: slots);
}

/// Replaces the slot's copy of the exercise with the same id. Returns [w] itself when the day lacks it or it is unchanged.
Workout _updateExercise(Workout w, Exercise exercise) {
  final i = w.indexOf(exercise.id);
  if (i < 0 || w.slots[i].exercise == exercise) return w;
  return _withSlot(w, i, Slot(exercise, w.slots[i].sets));
}

/// Applies [change] to one set. Returns [w] itself when [ref] is missing or [change] gives an equal set.
Workout _replaceSet(Workout w, SetRef ref, SetEntry Function(SetEntry) change) {
  final before = w.setAt(ref);
  if (before == null) return w;
  final after = change(before);
  if (after == before) return w;
  final i = w.indexOf(ref.exercise);
  return _withSlot(w, i, Slot(w.slots[i].exercise, [...w.slots[i].sets]..[ref.index] = after));
}

Workout _withSlot(Workout w, int index, Slot slot) => Workout(day: w.day, note: w.note, slots: [...w.slots]..[index] = slot);

SetRef? _firstPlanned(Workout w) {
  for (final slot in w.slots) {
    final i = slot.sets.indexWhere((s) => s.isPlanned);
    if (i >= 0) return (exercise: slot.exercise.id, index: i);
  }
  return null;
}

/// The first planned set of [exercise] at or after [start], wrapping to the start of that exercise, else the first planned set of the workout.
SetRef? _plannedFrom(Workout w, ExerciseId exercise, int start) {
  final sets = w.slotOf(exercise)?.sets ?? const <SetEntry>[];
  for (var k = 0; k < sets.length; k++) {
    final i = (start + k) % sets.length;
    if (sets[i].isPlanned) return (exercise: exercise, index: i);
  }
  return _firstPlanned(w);
}

int _compareFields(ExerciseKind kind, SetEntry a, SetEntry b) {
  for (final field in kind.fields) {
    final c = field.read(a).compareTo(field.read(b));
    if (c != 0) return c;
  }
  return 0;
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// [value] in thousandths as a decimal with at most [decimals] places and no trailing zeros, rounding half away from zero.
String _thousandths(int value, {required int decimals}) {
  var unit = 1;
  for (var i = decimals; i < 3; i++) {
    unit *= 10;
  }
  final scaled = (value.abs() + unit ~/ 2) ~/ unit;
  final perWhole = 1000 ~/ unit;
  final fraction = (scaled % perWhole).toString().padLeft(decimals, '0').replaceFirst(RegExp(r'0+$'), '');
  final sign = value < 0 && scaled > 0 ? '-' : '';
  return '$sign${scaled ~/ perWhole}${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Parses a decimal with a dot into thousandths, rounding past the third place. Integer arithmetic only, so `20.41` is exactly 20410.
int? _parseThousandths(String text) {
  final match = RegExp(r'^(-?)(\d*)(?:\.(\d*))?$').firstMatch(text);
  if (match == null) return null;
  final whole = match[2]!;
  final fraction = match[3] ?? '';
  if (whole.isEmpty && fraction.isEmpty) return null;
  final wholeValue = whole.isEmpty ? 0 : int.tryParse(whole);
  if (wholeValue == null) return null;
  final padded = fraction.padRight(4, '0');
  final thousandths = wholeValue * 1000 + int.parse(padded.substring(0, 3)) + (padded.codeUnitAt(3) >= 0x35 ? 1 : 0);
  return match[1]!.isEmpty ? thousandths : -thousandths;
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

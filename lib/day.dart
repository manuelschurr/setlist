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

  factory Day.of(DateTime time) {
    final local = time.toLocal();
    return Day._('${local.year.toString().padLeft(4, '0')}-${_twoDigits(local.month)}-${_twoDigits(local.day)}');
  }

  DateTime get date => DateTime(int.parse(iso.substring(0, 4)), int.parse(iso.substring(5, 7)), int.parse(iso.substring(8)));

  bool isBefore(Day other) => iso.compareTo(other.iso) < 0;
}

extension type const ExerciseId(int value) implements Object {}

/// Points at one set of a day by its exercise's slot and its position in that slot. It is a natural key, so dragging a card never invalidates it.
typedef SetRef = ({ExerciseId exercise, int index});

/// One measured quantity of a set. Every value is an integer in a fixed base unit, so the cascade compares with exact equality, and no caller outside this enum knows the units.
enum Field {
  /// Grams. Negative values are allowed for assisted lifts.
  weight,

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

  String format(int value) => switch (this) {
    weight => _thousandths(value, decimals: 2),
    reps => '$value',
    distance => value < 1000 ? '$value m' : '${_thousandths(value, decimals: 3)} km',
    time => '${value ~/ 60}:${_twoDigits(value % 60)}',
  };

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

  final String note;
  final SetStatus status;

  bool get isDone => status is Done;
  bool get isPlanned => status is Planned;

  /// What this set becomes in a new plan: the same values and warm-up flag, planned, and no note, because a note describes the session it was written in. Copying a day and adding an exercise from its last session both produce this.
  SetEntry get asPlan => SetEntry(grams: grams, reps: reps, metres: metres, seconds: seconds, warmup: warmup);

  SetEntry copyWith({int? grams, int? reps, int? metres, int? seconds, bool? warmup, String? note, SetStatus? status}) => SetEntry(grams: grams ?? this.grams, reps: reps ?? this.reps, metres: metres ?? this.metres, seconds: seconds ?? this.seconds, warmup: warmup ?? this.warmup, note: note ?? this.note, status: status ?? this.status);

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

/// One item of a day's list: a plain exercise or a superset.
sealed class Entry {
  /// The entry's exercises in round order, so a day's slots in order are its entries flattened.
  List<Slot> get slots;
}

/// One exercise in a day with its ordered sets. Directly in [Workout.entries] it is a plain exercise; inside a [Superset] it is one exercise of the round.
final class Slot extends Entry {
  Slot(this.exercise, List<SetEntry> sets) : sets = List.unmodifiable(sets) {
    if (sets.isEmpty) throw ArgumentError.value(sets, 'sets', 'a slot has at least one set');
  }

  final Exercise exercise;
  final List<SetEntry> sets;

  @override
  late final List<Slot> slots = List.unmodifiable([this]);

  bool get finished => sets.every((s) => s.isDone);

  int get doneCount => sets.where((s) => s.isDone).length;

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

/// Two or more exercises done in turn, one set of each per round. A superset of one cannot be built, so every operation that leaves one exercise makes it a plain [Slot].
final class Superset extends Entry {
  Superset(List<Slot> slots) : slots = List.unmodifiable(slots) {
    if (slots.length < 2) throw ArgumentError.value(slots.length, 'slots', 'a superset holds at least two exercises');
  }

  @override
  final List<Slot> slots;

  @override
  bool operator ==(Object other) => other is Superset && _sameList(other.slots, slots);

  @override
  int get hashCode => Object.hashAll(slots);
}

/// A day's arrangement: one inner list per entry, with its exercises in order. One exercise is a plain slot, two or more a superset.
typedef Layout = List<List<ExerciseId>>;

typedef Rest = ({Exercise exercise, DateTime endsAt});

typedef Summary = ({int doneSets, int volumeGrams, Duration? elapsed});

final class Workout {
  Workout({required this.day, this.note = '', List<Entry> entries = const []}) : entries = List.unmodifiable(entries), slots = List.unmodifiable([for (final entry in entries) ...entry.slots]) {
    final seen = <ExerciseId>{};
    for (final slot in slots) {
      if (!seen.add(slot.exercise.id)) throw ArgumentError.value(slot.exercise.name, 'entries', 'an exercise appears at most once per day');
    }
  }

  final Day day;
  final String note;
  final List<Entry> entries;

  /// [entries] flattened: every exercise of the day in workout order.
  final List<Slot> slots;

  bool get isEmpty => slots.isEmpty && note.isEmpty;

  Layout get layout => [
    for (final entry in entries) [for (final slot in entry.slots) slot.exercise.id],
  ];

  Slot? slotOf(ExerciseId exercise) => slots.where((s) => s.exercise.id == exercise).firstOrNull;

  /// The entry that holds [exercise]: its own [Slot] when it is a plain exercise, else its [Superset].
  Entry? entryOf(ExerciseId exercise) => entries.where((e) => e.slots.any((s) => s.exercise.id == exercise)).firstOrNull;

  SetEntry? setAt(SetRef ref) {
    final sets = slotOf(ref.exercise)?.sets;
    return sets == null || ref.index < 0 || ref.index >= sets.length ? null : sets[ref.index];
  }

  Iterable<SetRef> get refs sync* {
    for (final slot in slots) {
      for (var i = 0; i < slot.sets.length; i++) {
        yield (exercise: slot.exercise.id, index: i);
      }
    }
  }

  /// The rest countdown at [now], derived from the log times, never stored. Undo, app restarts and edits during rest therefore need no timer state. It follows the latest log. In a superset there is none while an exercise after the logged one in the round still has a planned set, because the round is not over, and otherwise it lasts the longest rest of the superset's exercises. [Rest.exercise] is always the exercise of the latest log, which the notification names.
  Rest? restAt(DateTime now) {
    if (_firstPlanned(this) == null) return null;
    ({DateTime at, Slot slot})? latest;
    for (final slot in slots) {
      for (final set in slot.sets) {
        if (set.status case Done(:final at?) when latest == null || at.isAfter(latest.at)) latest = (at: at, slot: slot);
      }
    }
    if (latest == null) return null;
    final exercise = latest.slot.exercise;
    final round = entryOf(exercise.id)!.slots;
    final later = round.skip(round.indexWhere((s) => s.exercise.id == exercise.id) + 1);
    if (later.any((s) => s.sets.any((set) => set.isPlanned))) return null;
    final rest = round.map((s) => s.exercise.rest).reduce((a, b) => a > b ? a : b);
    final endsAt = latest.at.add(rest);
    return endsAt.isAfter(now) ? (exercise: exercise, endsAt: endsAt) : null;
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
  bool operator ==(Object other) => other is Workout && other.day == day && other.note == note && _sameList(other.entries, entries);

  @override
  int get hashCode => Object.hash(day, note, Object.hashAll(entries));
}

/// What the lifter did last time on each set of [today], one entry per set, for the muted text under each row. Warm-ups pair with warm-ups and working sets with working sets, each by its order among its own kind, so adding a warm-up today does not shift every working set's comparison by one. A set with no counterpart gets null.
List<SetEntry?> alignLastTime(List<SetEntry> today, List<SetEntry> lastSession) {
  final warmups = lastSession.where((s) => s.warmup).iterator;
  final working = lastSession.where((s) => !s.warmup).iterator;
  SetEntry? take(Iterator<SetEntry> pool) => pool.moveNext() ? pool.current : null;
  return [for (final set in today) take(set.warmup ? warmups : working)];
}

final class DayState {
  DayState._(this.workout, this.focus) : assert(focus == null || workout.setAt(focus) != null);

  factory DayState.open(Workout workout) => DayState._(workout, _firstPlanned(workout));

  final Workout workout;

  /// The set the panel edits. Null means no planned set remains and the panel shows the summary. It may point at a done set the lifter tapped to correct.
  final SetRef? focus;
}

sealed class Command {
  const Command();
}

final class FocusSet extends Command {
  const FocusSet(this.ref);
  final SetRef ref;
}

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

final class SetSetNote extends Command {
  const SetSetNote(this.ref, this.note);
  final SetRef ref;
  final String note;
}

final class LogSet extends Command {
  const LogSet(this.ref, {required this.at});
  final SetRef ref;
  final DateTime at;
}

final class UnlogSet extends Command {
  const UnlogSet(this.ref);
  final SetRef ref;
}

final class AddSet extends Command {
  const AddSet(this.exercise);
  final ExerciseId exercise;
}

final class RemoveSet extends Command {
  const RemoveSet(this.ref);
  final SetRef ref;
}

final class AddExercise extends Command {
  const AddExercise(this.exercise, {required this.lastSession});
  final Exercise exercise;
  final List<SetEntry> lastSession;
}

final class RemoveExercise extends Command {
  const RemoveExercise(this.exercise);
  final ExerciseId exercise;
}

/// Puts the day's exercises in [layout]'s order and grouping. Applies only when [layout] names exactly the day's exercises, each once, with no empty inner list, so a layout from a stale drag changes nothing. The focus stays on its set.
final class Arrange extends Command {
  const Arrange(this.layout);
  final Layout layout;
}

/// The card menu's "Superset with…". [added] moves to right after [anchor] and joins [anchor]'s superset, or the two start a new one. A superset [added] leaves with one exercise becomes that plain exercise. Changes nothing when either is not in the day, when they are the same, or when [added] is already in [anchor]'s superset. The focus stays on its set.
final class SupersetWith extends Command {
  const SupersetWith(this.anchor, this.added);
  final ExerciseId anchor;
  final ExerciseId added;
}

final class CopyDay extends Command {
  const CopyDay(this.source);
  final Workout source;
}

final class SetNote extends Command {
  const SetNote(this.note);
  final String note;
}

final class UpdateExercise extends Command {
  const UpdateExercise(this.exercise);
  final Exercise exercise;
}

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
    Arrange(:final layout) => _next(state, _arrange(w, layout), state.focus),
    SupersetWith(:final anchor, :final added) => _next(state, _supersetWith(w, anchor, added), state.focus),
    CopyDay(:final source) => _copyDay(state, source),
    SetNote(:final note) => note == w.note ? state : _next(state, Workout(day: w.day, note: note, entries: w.entries), state.focus),
    UpdateExercise(:final exercise) => _next(state, _updateExercise(w, exercise), state.focus),
  };
}

DayState _next(DayState state, Workout workout, SetRef? focus) => identical(workout, state.workout) && focus == state.focus ? state : DayState._(workout, focus);

/// The cascade. Sets [field] of the set at [ref] to [value], and sets [value] on every later set of the same exercise that is still planned and whose [field] held the edited set's old value. Done sets never change by cascade. Sets with another value are left alone, so warm-ups and back-off sets survive an edit to the working sets. The edited set itself may be done, so correcting a logged set still updates the planned ones after it. Returns [w] itself when nothing changes.
Workout _cascade(Workout w, SetRef ref, Field field, int value) {
  final slot = w.slotOf(ref.exercise);
  final edited = w.setAt(ref);
  if (slot == null || edited == null) return w;
  final old = field.read(edited);
  if (old == value) return w;
  final next = [...slot.sets];
  next[ref.index] = field.write(edited, value);
  for (var j = ref.index + 1; j < next.length; j++) {
    if (next[j].isPlanned && field.read(next[j]) == old) next[j] = field.write(next[j], value);
  }
  return _withSlot(w, Slot(slot.exercise, next));
}

/// Focus moves only when the logged set held the focus, or when the focus was on no planned set, and then to [focusAfterLog]. Checking the circle on some other row leaves the panel where it is. Logging a set that is already done keeps its original time and still moves focus; that is the panel's "Next set" button on a corrected set.
DayState _log(DayState state, SetRef ref, DateTime at) {
  final w = state.workout;
  final target = w.setAt(ref);
  if (target == null) return state;
  final logged = target.isDone ? w : _replaceSet(w, ref, (s) => s.copyWith(status: Done(at)));
  final current = state.focus;
  final advance = current == null || current == ref || w.setAt(current)?.isPlanned != true;
  return _next(state, logged, advance ? focusAfterLog(logged, ref) : current);
}

/// Where the focus goes when the set at [ref] is logged in [workout], whether that set is still planned or already done. Logging moves the focus here, and the panel names the exercise it will land on, so the two never disagree.
///
/// In a superset it goes to the next exercise of the round after [ref]'s, wrapping to the first, that has a planned set, and there to its first planned set. When no other exercise of the superset has one, and for a plain exercise, it goes to the next planned set after [ref] in its own exercise, else to the first planned set of that exercise (one skipped within it), else to the first planned set from the top of the workout (an exercise skipped for a busy rack comes back next), else to null and the panel shows the summary.
SetRef? focusAfterLog(Workout workout, SetRef ref) {
  final logged = _replaceSet(workout, ref, (s) => s.isDone ? s : s.copyWith(status: const Done()));
  final round = logged.entryOf(ref.exercise)?.slots ?? const <Slot>[];
  final at = round.indexWhere((s) => s.exercise.id == ref.exercise);
  for (var k = 1; k < round.length; k++) {
    final slot = round[(at + k) % round.length];
    final planned = slot.sets.indexWhere((s) => s.isPlanned);
    if (planned >= 0) return (exercise: slot.exercise.id, index: planned);
  }
  return _plannedFrom(logged, ref.exercise, ref.index + 1);
}

DayState _addExercise(DayState state, Exercise exercise, List<SetEntry> lastSession) {
  final w = state.workout;
  final existing = w.slotOf(exercise.id);
  if (existing != null) {
    final planned = existing.sets.indexWhere((s) => s.isPlanned);
    return _next(state, w, (exercise: exercise.id, index: planned < 0 ? 0 : planned));
  }
  final sets = lastSession.isEmpty ? const [SetEntry()] : [for (final s in lastSession) s.asPlan];
  return DayState._(Workout(day: w.day, note: w.note, entries: [...w.entries, Slot(exercise, sets)]), (exercise: exercise.id, index: 0));
}

/// Appends each entry of [source] with the exercises the day lacks, every set planned. A superset arrives without the exercises the day already has, which stay where they are, and one left with a single exercise arrives as a plain one.
DayState _copyDay(DayState state, Workout source) {
  final w = state.workout;
  final added = [
    for (final entry in source.entries)
      [
        for (final slot in entry.slots)
          if (w.slotOf(slot.exercise.id) == null) Slot(slot.exercise, [for (final s in slot.sets) s.asPlan]),
      ],
  ];
  if (added.every((group) => group.isEmpty)) return state;
  final next = _withGroups(w, [for (final entry in w.entries) entry.slots, ...added]);
  return DayState._(next, state.focus ?? _firstPlanned(next));
}

DayState _removeSet(DayState state, SetRef ref) {
  final w = state.workout;
  final slot = w.slotOf(ref.exercise);
  if (slot == null || w.setAt(ref) == null) return state;
  if (slot.sets.length == 1) return _removeExercise(state, ref.exercise);
  final next = _withSlot(w, Slot(slot.exercise, [...slot.sets]..removeAt(ref.index)));
  final focus = state.focus;
  if (focus == ref) return DayState._(next, _plannedFrom(next, ref.exercise, ref.index));
  if (focus != null && focus.exercise == ref.exercise && focus.index > ref.index) return DayState._(next, (exercise: focus.exercise, index: focus.index - 1));
  return DayState._(next, focus);
}

/// Removing an exercise also takes it out of its superset, and a superset of two becomes the plain exercise left.
DayState _removeExercise(DayState state, ExerciseId exercise) {
  final w = state.workout;
  if (w.slotOf(exercise) == null) return state;
  final next = _mapSlots(w, (s) => s.exercise.id == exercise ? null : s);
  return DayState._(next, state.focus?.exercise == exercise ? _firstPlanned(next) : state.focus);
}

DayState _addSet(DayState state, ExerciseId exercise) {
  final w = state.workout;
  final slot = w.slotOf(exercise);
  if (slot == null) return state;
  final copy = slot.sets.last.asPlan.copyWith(warmup: false);
  return DayState._(_withSlot(w, Slot(slot.exercise, [...slot.sets, copy])), (exercise: exercise, index: slot.sets.length));
}

/// Returns [w] itself when [layout] is not an arrangement of exactly the day's exercises, or is the one the day already has.
Workout _arrange(Workout w, Layout layout) {
  final slots = {for (final slot in w.slots) slot.exercise.id: slot};
  final named = [for (final group in layout) ...group];
  if (layout.any((group) => group.isEmpty) || named.length != slots.length || !named.every(slots.containsKey) || named.toSet().length != named.length) return w;
  final next = _withGroups(w, [
    for (final group in layout) [for (final id in group) slots[id]!],
  ]);
  return next == w ? w : next;
}

Workout _supersetWith(Workout w, ExerciseId anchor, ExerciseId added) {
  final home = w.entryOf(anchor);
  final moving = w.slotOf(added);
  if (home == null || moving == null || home.slots.any((s) => s.exercise.id == added)) return w;
  return _withGroups(w, [
    for (final entry in w.entries)
      [
        for (final slot in entry.slots)
          if (slot.exercise.id == anchor) ...[slot, moving] else if (slot.exercise.id != added) slot,
      ],
  ]);
}

Workout _updateExercise(Workout w, Exercise exercise) {
  final slot = w.slotOf(exercise.id);
  if (slot == null || slot.exercise == exercise) return w;
  return _withSlot(w, Slot(exercise, slot.sets));
}

Workout _replaceSet(Workout w, SetRef ref, SetEntry Function(SetEntry) change) {
  final slot = w.slotOf(ref.exercise);
  final before = w.setAt(ref);
  if (slot == null || before == null) return w;
  final after = change(before);
  if (after == before) return w;
  return _withSlot(w, Slot(slot.exercise, [...slot.sets]..[ref.index] = after));
}

/// Puts [slot] in place of the slot of the same exercise, in the same entry.
Workout _withSlot(Workout w, Slot slot) => _mapSlots(w, (s) => s.exercise.id == slot.exercise.id ? slot : s);

/// Passes every slot through [change] and keeps each entry's grouping. A null drops the slot, and a superset left with one slot becomes that plain slot.
Workout _mapSlots(Workout w, Slot? Function(Slot) change) => _withGroups(w, [
  for (final entry in w.entries) [for (final slot in entry.slots) ?change(slot)],
]);

/// Builds the entries from [groups] in order: one slot is a plain exercise, two or more a superset, and an empty group is dropped.
Workout _withGroups(Workout w, Iterable<List<Slot>> groups) => Workout(
  day: w.day,
  note: w.note,
  entries: [
    for (final group in groups)
      if (group.length == 1) group.single else if (group.length > 1) Superset(group),
  ],
);

SetRef? _firstPlanned(Workout w) {
  for (final slot in w.slots) {
    final i = slot.sets.indexWhere((s) => s.isPlanned);
    if (i >= 0) return (exercise: slot.exercise.id, index: i);
  }
  return null;
}

SetRef? _plannedFrom(Workout w, ExerciseId exercise, int start) {
  final sets = w.slotOf(exercise)?.sets ?? const <SetEntry>[];
  for (var k = 0; k < sets.length; k++) {
    final i = (start + k) % sets.length;
    if (sets[i].isPlanned) return (exercise: exercise, index: i);
  }
  return _firstPlanned(w);
}

/// One row of the workout list as the screen draws it, in one flat list: a superset is its [SupersetTop], an [ExerciseRow] per exercise and its [SupersetBottom], and a plain exercise is one [ExerciseRow].
sealed class ListRow {
  const ListRow();
}

/// A superset's header strip. Dragging it moves the whole superset.
final class SupersetTop extends ListRow {
  const SupersetTop(this.superset);
  final Superset superset;

  @override
  bool operator ==(Object other) => other is SupersetTop && other.superset == superset;

  @override
  int get hashCode => Object.hash(SupersetTop, superset);
}

final class ExerciseRow extends ListRow {
  const ExerciseRow(this.exercise);
  final ExerciseId exercise;

  @override
  bool operator ==(Object other) => other is ExerciseRow && other.exercise == exercise;

  @override
  int get hashCode => Object.hash(ExerciseRow, exercise);
}

/// The end of a superset's frame. It is never dragged.
final class SupersetBottom extends ListRow {
  const SupersetBottom(this.superset);
  final Superset superset;

  @override
  bool operator ==(Object other) => other is SupersetBottom && other.superset == superset;

  @override
  int get hashCode => Object.hash(SupersetBottom, superset);
}

List<ListRow> listRows(Workout workout) => [
  for (final entry in workout.entries)
    ...switch (entry) {
      Slot() => [ExerciseRow(entry.exercise.id)],
      Superset() => [SupersetTop(entry), for (final slot in entry.slots) ExerciseRow(slot.exercise.id), SupersetBottom(entry)],
    },
];

/// The layout a drag in the [listRows] list asks for, or null when the drop changes nothing, so the screen dispatches nothing. [from] and [to] are what `onReorderItem` reports: [to] is the index the row ends at, counted after it was removed from [from].
///
/// An exercise row ends inside a superset when it lands between that superset's top and bottom rows, and plain otherwise, and a superset it leaves with one exercise dissolves. A top row moves its whole superset to the gap it was dropped in. While it is dragged the screen keeps the superset's other rows in the list at zero height, so [to] counts them, and a gap inside that span or right next to it is no move. A gap inside another superset's span puts it right above that superset. A bottom row never moves.
Layout? layoutAfterDrop(Workout workout, int from, int to) {
  final rows = listRows(workout);
  if (from < 0 || from >= rows.length || to < 0 || to >= rows.length) return null;
  final List<ListRow> dropped;
  switch (rows[from]) {
    case SupersetBottom():
      return null;
    case final ExerciseRow row:
      dropped = [...rows]..removeAt(from);
      dropped.insert(to, row);
    case SupersetTop(:final superset):
      final end = from + superset.slots.length + 2;
      if (to >= from && to < end) return null;
      final span = rows.sublist(from, end);
      dropped = [...rows]..removeRange(from, end);
      final gap = to < from ? to : to - (span.length - 1);
      int? enclosing;
      for (final (i, row) in dropped.take(gap).indexed) {
        if (row is SupersetTop) enclosing = i;
        if (row is SupersetBottom) enclosing = null;
      }
      dropped.insertAll(enclosing ?? gap, span);
  }
  final layout = _layoutOf(dropped);
  return identical(_arrange(workout, layout), workout) ? null : layout;
}

Layout _layoutOf(List<ListRow> rows) {
  final layout = <List<ExerciseId>>[];
  List<ExerciseId>? frame;
  for (final row in rows) {
    switch (row) {
      case SupersetTop():
        layout.add(frame = []);
      case ExerciseRow(:final exercise):
        frame == null ? layout.add([exercise]) : frame.add(exercise);
      case SupersetBottom():
        frame = null;
    }
  }
  return layout..removeWhere((group) => group.isEmpty);
}

int _compareFields(ExerciseKind kind, SetEntry a, SetEntry b) {
  for (final field in kind.fields) {
    final c = field.read(a).compareTo(field.read(b));
    if (c != 0) return c;
  }
  return 0;
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

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

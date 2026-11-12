/// The workout screen, with the day's list above and the docked panel below.
///
/// [_WorkoutScreenState] is the only owner of the live day. It holds one [DayState] and changes it only in [_WorkoutScreenState._dispatch], which runs [reduce], saves the whole day when it changed, offers undo, and syncs the rest alarm. Every widget below it is stateless apart from the countdown text and receives the state and a `ValueChanged<Command>`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'day.dart';
import 'exercise_picker.dart';
import 'history_screen.dart';
import 'rest_alarm.dart';
import 'store.dart';

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key, required this.store, required this.alarm, required this.day});

  final Store store;
  final RestAlarm alarm;
  final Day day;

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> with WidgetsBindingObserver {
  late DayState _state = DayState.open(widget.store.loadDay(widget.day));

  /// The state before the last change that offered undo. Cleared by the next change to the workout, so the snackbar's Undo never reverts anything but the change it names. Focus taps keep it, since restoring would only move the focus back.
  DayState? _undoTo;

  /// The last save threw. The next change, or the app going to the background, saves the whole day again, which converges because the save is a replace.
  bool _unsaved = false;

  /// Cards the lifter expanded after they finished. Only consulted while a card is finished.
  final Set<ExerciseId> _expanded = {};

  /// Previous-session lookups, one per exercise for the life of the screen. Serve both the muted "last time" text and the plan for [AddExercise].
  final Map<ExerciseId, List<SetEntry>> _lastTime = {};

  final Map<ExerciseId, GlobalKey> _cardKeys = {};

  late final List<Workout> _recent = widget.store.recentWorkouts(before: widget.day, limit: 10);

  List<SetEntry> _lastTimeOf(ExerciseId id) => _lastTime.putIfAbsent(id, () => widget.store.lastSession(id, before: widget.day));

  void _dispatch(Command command) {
    final before = _state;
    final after = reduce(before, command);
    setState(() => _state = after);
    if (!identical(after.workout, before.workout)) {
      _persist(after.workout);
      final label = _undoLabel(command);
      _undoTo = label == null ? null : before;
      final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
      if (label != null) {
        messenger.showSnackBar(SnackBar(content: Text(label), action: SnackBarAction(label: 'Undo', onPressed: _undo)));
      }
      if (command is LogSet && after.workout.slotOf(command.ref.exercise)!.finished) _expanded.remove(command.ref.exercise);
    }
    final focus = after.focus;
    if (focus != null && focus.exercise != before.focus?.exercise) _reveal(focus.exercise);
  }

  void _undo() {
    final to = _undoTo;
    if (to == null) return;
    _undoTo = null;
    setState(() => _state = to);
    _persist(to.workout);
  }

  void _persist(Workout workout) {
    try {
      widget.store.saveDay(workout);
      _unsaved = false;
    } on StoreWriteFailed {
      _unsaved = true;
      // TODO: show a MaterialBanner "Not saved. Retrying on the next change." until a save succeeds.
    }
    widget.alarm.show(workout.restAt(DateTime.now()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _unsaved) _persist(_state.workout);
    if (state == AppLifecycleState.resumed) widget.alarm.show(_state.workout.restAt(DateTime.now()));
  }

  /// Snackbar text for the changes that offer undo. Exhaustive with no wildcard, so a new command does not compile until someone decides here.
  String? _undoLabel(Command command) => switch (command) {
    LogSet() => 'Set logged',
    RemoveSet() => 'Set removed',
    RemoveExercise() => 'Exercise removed',
    CopyDay() => 'Workout copied',
    FocusSet() || SetField() || SetWarmup() || UnlogSet() || AddSet() || AddExercise() || MoveExercise() || SetNote() || UpdateExercise() => null,
  };

  Future<void> _addExercise() async {
    final picked = await pickExercise(context, widget.store, inDay: {for (final s in _state.workout.slots) s.exercise.id});
    if (picked == null || !mounted) return;
    _dispatch(AddExercise(picked, lastSession: _lastTimeOf(picked.id)));
    _reveal(picked.id);
  }

  /// Scrolls the card into view after the frame that builds it.
  void _reveal(ExerciseId id) => WidgetsBinding.instance.addPostFrameCallback((_) {
    final context = _cardKeys[id]?.currentContext;
    if (context != null) Scrollable.ensureVisible(context, alignment: 0.2, duration: const Duration(milliseconds: 200));
  });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.alarm.show(_state.workout.restAt(DateTime.now()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workout = _state.workout;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.day.iso), // TODO: weekday and date; a note action dispatching SetNote
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => HistoryScreen(store: widget.store, alarm: widget.alarm))),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: workout.slots.length,
              // Flutter reports the insertion index before removal, so a card dragged down lands one later than its final index.
              onReorder: (from, to) => _dispatch(MoveExercise(from, to > from ? to - 1 : to)),
              itemBuilder: (context, i) {
                final slot = workout.slots[i];
                final id = slot.exercise.id;
                return _SlotCard(
                  key: _cardKeys.putIfAbsent(id, GlobalKey.new),
                  index: i,
                  slot: slot,
                  focus: _state.focus,
                  lastTime: _lastTimeOf(id),
                  collapsed: slot.finished && !_expanded.contains(id) && _state.focus?.exercise != id,
                  onToggle: () => setState(() => _expanded.contains(id) ? _expanded.remove(id) : _expanded.add(id)),
                  onCommand: _dispatch,
                );
              },
              footer: Column(
                children: [
                  TextButton.icon(onPressed: _addExercise, icon: const Icon(Icons.add), label: const Text('Add exercise')),
                  if (workout.slots.isEmpty)
                    for (final past in _recent) _CopyTile(workout: past, onCopy: () => _dispatch(CopyDay(past))),
                ],
              ),
            ),
          ),
          _Panel(state: _state, onCommand: _dispatch),
        ],
      ),
    );
  }
}

/// One exercise card. It shows a header with name, progress, drag handle and menu, then one row per set, or only the header with the top set once finished.
class _SlotCard extends StatelessWidget {
  const _SlotCard({super.key, required this.index, required this.slot, required this.focus, required this.lastTime, required this.collapsed, required this.onToggle, required this.onCommand});

  final int index;
  final Slot slot;
  final SetRef? focus;
  final List<SetEntry> lastTime;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<Command> onCommand;

  @override
  Widget build(BuildContext context) {
    final id = slot.exercise.id;
    final kind = slot.exercise.kind;
    final header = ListTile(
      title: Text(slot.exercise.name),
      subtitle: collapsed ? Text(slot.topSet?.describe(kind) ?? '') : null,
      onTap: slot.finished ? onToggle : null,
      leading: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        slot.finished ? const Icon(Icons.check) : Text('${slot.doneCount}/${slot.sets.length}'),
        _CardMenu(slot: slot, onCommand: onCommand),
      ]),
    );
    if (collapsed) return Card(child: header);
    return Card(
      child: Column(children: [
        header,
        for (var i = 0; i < slot.sets.length; i++)
          _SetRow(
            number: i + 1,
            set: slot.sets[i],
            kind: kind,
            lastTime: i < lastTime.length ? lastTime[i].describe(kind) : null,
            focused: focus == (exercise: id, index: i),
            onTap: () => onCommand(FocusSet((exercise: id, index: i))),
            onCheck: () => onCommand(slot.sets[i].isDone ? UnlogSet((exercise: id, index: i)) : LogSet((exercise: id, index: i), at: DateTime.now())),
          ),
      ]),
    );
  }
}

/// Add set, warm-up toggle for a set, edit exercise (increment and rest, saved through [Store.updateExercise] then [UpdateExercise]), remove exercise.
class _CardMenu extends StatelessWidget {
  const _CardMenu({required this.slot, required this.onCommand});

  final Slot slot;
  final ValueChanged<Command> onCommand;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Set number, the kind's values, last time's values in small muted text, and a check circle. Long press offers remove and warm-up.
class _SetRow extends StatelessWidget {
  const _SetRow({required this.number, required this.set, required this.kind, required this.lastTime, required this.focused, required this.onTap, required this.onCheck});

  final int number;
  final SetEntry set;
  final ExerciseKind kind;
  final String? lastTime;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// The docked panel. Edits the focused set: name and set number, one stepper per field of the kind, the rest countdown after a log, and the Log button. Shows the session summary when nothing is focused.
class _Panel extends StatelessWidget {
  const _Panel({required this.state, required this.onCommand});

  final DayState state;
  final ValueChanged<Command> onCommand;

  @override
  Widget build(BuildContext context) {
    final ref = state.focus;
    if (ref == null) return _SummaryPanel(summary: state.workout.summary);
    final slot = state.workout.slotOf(ref.exercise)!;
    final set = slot.sets[ref.index];
    final rest = state.workout.restAt(DateTime.now());
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${slot.exercise.name} · set ${ref.index + 1} of ${slot.sets.length}'),
          for (final field in slot.exercise.kind.fields)
            _Stepper(
              field: field,
              value: field.read(set),
              onStep: (up) => onCommand(SetField(ref, field, field.stepped(slot.exercise, field.read(set), up: up))),
              onTyped: (value) => onCommand(SetField(ref, field, value)),
            ),
          if (rest != null) _RestCountdown(rest: rest),
          FilledButton(
            onPressed: () => onCommand(LogSet(ref, at: DateTime.now())),
            child: Text(set.isDone ? 'Next set' : 'Log set'),
          ),
        ]),
      ),
    );
  }
}

/// Large minus and plus buttons around the value. Tapping the value opens a number dialog.
///
/// [onTyped] fires once, when the dialog is confirmed, never per keystroke. Each call runs the cascade, and typing 10 over a 5 would pass through 1 and capture any later planned set that really held 1.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.field, required this.value, required this.onStep, required this.onTyped});

  final Field field;
  final int value;
  final ValueChanged<bool> onStep;
  final ValueChanged<int> onTyped;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Counts down to [Rest.endsAt] once a second and hides itself at zero. Owns the only Dart timer in the app, which drives this text and nothing else; the notification and vibration come from [RestAlarm].
class _RestCountdown extends StatefulWidget {
  const _RestCountdown({required this.rest});

  final Rest rest;

  @override
  State<_RestCountdown> createState() => _RestCountdownState();
}

class _RestCountdownState extends State<_RestCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// A recent workout on an empty day: date, exercise names, and a Copy button.
class _CopyTile extends StatelessWidget {
  const _CopyTile({required this.workout, required this.onCopy});

  final Workout workout;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

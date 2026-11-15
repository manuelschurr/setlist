/// [_WorkoutScreenState] is the only owner of the live day. It holds one [DayState] and changes it only in [_WorkoutScreenState._dispatch], which runs [reduce], saves the whole day when it changed, offers undo, and syncs the rest alarm. Every widget below it is stateless apart from the countdown text and dialogs, and receives the state and a `ValueChanged<Command>`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'day.dart';
import 'drive_backup.dart';
import 'exercise_history_screen.dart';
import 'exercise_picker.dart';
import 'history_screen.dart';
import 'rest_alarm.dart';
import 'store.dart';

/// What the app's home screen holds. The home shows [day], today as of app start or of the resume that moved it to a new day, and it is the only screen ever opened for that day, so no second screen writes it: history pops back to the home instead of opening it again. Only the home drives [alarm], because the countdown belongs to today and a screen for another day would cancel it. [restore] swaps the database file and rebuilds the app from a new home. [backup] outlives every home, because it belongs to the database file.
final class Home {
  const Home({required this.day, required this.alarm, required this.restore, required this.backup});

  final Day day;
  final RestAlarm alarm;
  final ValueChanged<String> restore;
  final DriveBackup backup;

  /// Asks before [restore], the one confirmation in the app, because a restore replaces everything.
  Future<void> confirmRestore(BuildContext context, String backupPath) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: const Text('Everything in Setlist is replaced by the backup. Workouts logged after it was made are lost. A copy of the current data stays on the phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed == true) restore(backupPath);
  }
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key, required this.store, required this.home, required this.day});

  final Store store;
  final Home home;
  final Day day;

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> with WidgetsBindingObserver {
  late DayState _state = DayState.open(widget.store.loadDay(widget.day));

  /// The state before the last change that offered undo. Cleared by the next change to the workout, so the snackbar's Undo never reverts anything but the change it names. Focus taps keep it, since restoring would only move the focus back.
  DayState? _undoTo;

  /// The root messenger, kept so [dispose] can reach it after this screen's context is gone. The snackbar it shows outlives the screen and would follow the lifter to the home.
  late ScaffoldMessengerState _messenger;

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoBar;

  bool _unsaved = false;

  final Map<ExerciseId, bool> _collapsedByHand = {};

  final Map<ExerciseId, List<SetEntry>> _lastTime = {};

  final Map<ExerciseId, GlobalKey> _cardKeys = {};

  /// The superset whose header strip is being dragged, and the row it was picked up from. Its cards and footer stay in the list at zero height while it floats, so the drop indices still count them, and they open again in the frame that the drop lands, not first where the superset was.
  ({int from, Superset superset})? _lifted;

  bool _folded(int row) => switch (_lifted) {
    (:final from, :final superset) => row > from && row <= from + superset.slots.length + 1,
    null => false,
  };

  void _land() {
    if (_lifted != null) setState(() => _lifted = null);
  }

  late List<Workout> _recent = _loadRecent();

  bool get _isHome => widget.day == widget.home.day;

  bool _collapsed(Slot slot) => _collapsedByHand[slot.exercise.id] ?? (slot.finished && _state.focus?.exercise != slot.exercise.id);

  List<Workout> _loadRecent() => widget.store.recentWorkouts(before: widget.day, limit: 5);

  List<SetEntry> _lastTimeOf(ExerciseId id) => _lastTime.putIfAbsent(id, () => widget.store.lastSession(id, before: widget.day));

  void _dispatch(Command command) {
    final before = _state;
    final after = reduce(before, command);
    if (identical(after, before)) return;
    final focus = after.focus?.exercise;
    setState(() {
      _state = after;
      if (command is LogSet && after.workout.slotOf(command.ref.exercise)?.finished == true) _collapsedByHand.remove(command.ref.exercise);
      if (focus != null && focus != before.focus?.exercise) _collapsedByHand.remove(focus);
    });
    if (!identical(after.workout, before.workout)) {
      _persist(after.workout);
      final label = _undoLabel(command);
      _undoTo = label == null ? null : before;
      _messenger.hideCurrentSnackBar();
      if (label != null) {
        final bar = _undoBar = _messenger.showSnackBar(SnackBar(content: Text(label), persist: false, action: SnackBarAction(label: 'Undo', onPressed: _undo)));
        bar.closed.then((_) {
          if (_undoBar == bar) _undoBar = null;
        });
      }
    }
    if (focus != null && focus != before.focus?.exercise) _reveal(focus);
  }

  void _undo() {
    final to = _undoTo;
    if (to == null || !mounted) return;
    _undoTo = null;
    setState(() => _state = to);
    _persist(to.workout);
  }

  void _persist(Workout workout) {
    try {
      widget.store.saveDay(workout);
      if (_unsaved) setState(() => _unsaved = false);
    } on StoreWriteFailed {
      if (!_unsaved) setState(() => _unsaved = true);
    }
    _syncAlarm(workout);
  }

  void _syncAlarm(Workout workout) {
    if (_isHome) widget.home.alarm.show(workout.restAt(DateTime.now()));
  }

  /// Reads the day, the last-time cache and the recent list again, because a pushed route or an import may have written to the store. The focus stays on the same set when it still exists. While saves are failing the live day is newer than the store, so it is kept.
  void _reload() {
    if (_unsaved) _persist(_state.workout);
    final focus = _state.focus;
    setState(() {
      _lastTime.clear();
      _recent = _loadRecent();
      if (_unsaved) return;
      final opened = DayState.open(widget.store.loadDay(widget.day));
      final next = focus == null ? opened : reduce(opened, FocusSet(focus));
      if (next.workout != _state.workout) {
        _undoTo = null;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
      _state = next;
    });
    _syncAlarm(_state.workout);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _unsaved) _persist(_state.workout);
    if (state == AppLifecycleState.resumed) {
      _syncAlarm(_state.workout);
      setState(() {});
    }
  }

  /// Snackbar text for the changes that offer undo. Exhaustive with no wildcard, so a new command does not compile until someone decides here.
  String? _undoLabel(Command command) => switch (command) {
    LogSet() => 'Set logged',
    RemoveSet() => 'Set removed',
    RemoveExercise() => 'Exercise removed',
    CopyDay() => 'Workout copied',
    FocusSet() || SetField() || SetWarmup() || SetSetNote() || UnlogSet() || AddSet() || AddExercise() || Arrange() || SupersetWith() || SetNote() || UpdateExercise() => null,
  };

  Future<T?> _push<T>(Widget screen) async {
    final result = await Navigator.push<T>(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) _reload();
    return result;
  }

  Future<void> _addExercise() async {
    final picked = await pickExercise(context, widget.store, inDay: {for (final s in _state.workout.slots) s.exercise.id});
    if (!mounted) return;
    _reload();
    if (picked == null) return;
    _dispatch(AddExercise(picked, lastSession: _lastTimeOf(picked.id)));
    _reveal(picked.id);
  }

  void _copy(Workout source) {
    final before = _state.workout;
    _dispatch(CopyDay(source));
    if (identical(_state.workout, before)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This day already has every exercise of that workout')));
    }
  }

  Future<void> _openHistory() async {
    final copy = await _push<Workout>(HistoryScreen(store: widget.store, home: widget.home));
    if (copy != null && mounted) _copy(copy);
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(context: context, initialDate: widget.day.date, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (picked != null && mounted) _openDay(Day.of(picked));
  }

  Future<void> _openDay(Day day) async {
    if (day == widget.day) return;
    if (!_isHome) {
      Navigator.pop(context, day);
      return;
    }
    final next = await _push<Day>(WorkoutScreen(store: widget.store, home: widget.home, day: day));
    if (next != null && mounted) _openDay(next);
  }

  Future<void> _editNote() async {
    final note = await askText(context, title: 'Workout note', initial: _state.workout.note);
    if (note != null && mounted) _dispatch(SetNote(note));
  }

  Future<void> _copyPast() async {
    final recent = widget.store.recentWorkouts(before: widget.day, limit: 30);
    final picked = await showModalBottomSheet<Workout>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        builder: (context, controller) => recent.isEmpty
            ? const Center(child: Text('No past workouts yet'))
            : ListView(controller: controller, children: [for (final w in recent) CopyTile(workout: w, onCopy: () => Navigator.pop(context, w))]),
      ),
    );
    if (picked != null && mounted) _copy(picked);
  }

  Future<void> _cardAction(Slot slot, _CardAction action) async {
    switch (action) {
      case _CardAction.history:
        await _push<void>(ExerciseHistoryScreen(store: widget.store, exercise: slot.exercise));
      case _CardAction.edit:
        final edited = await editExercise(context, widget.store, slot.exercise);
        if (edited != null && mounted) _dispatch(UpdateExercise(edited));
      case _CardAction.superset:
        final picked = await _pickPartner(slot);
        if (picked != null && mounted) _dispatch(SupersetWith(slot.exercise.id, picked));
      case _CardAction.remove:
        _dispatch(RemoveExercise(slot.exercise.id));
    }
  }

  /// What "Superset with…" offers for [slot]: every exercise of the day outside [slot]'s own superset, or every other one when [slot] is plain.
  List<Slot> _partnersOf(Slot slot) {
    final own = _state.workout.entryOf(slot.exercise.id)!.slots;
    return [
      for (final other in _state.workout.slots)
        if (!own.any((s) => s.exercise.id == other.exercise.id)) other,
    ];
  }

  /// An exercise already in another superset shows that superset under its name, because picking it takes it out of there.
  Future<ExerciseId?> _pickPartner(Slot slot) {
    final workout = _state.workout;
    return showModalBottomSheet<ExerciseId>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Superset ${slot.exercise.name} with', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final partner in _partnersOf(slot))
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: Text(partner.exercise.name),
                subtitle: switch (workout.entryOf(partner.exercise.id)) {
                  final Superset other => Text(namesOf([other])),
                  _ => null,
                },
                onTap: () => Navigator.pop(context, partner.exercise.id),
              ),
          ],
        ),
      ),
    );
  }

  void _reveal(ExerciseId id) => WidgetsBinding.instance.addPostFrameCallback((_) {
    final card = _cardKeys[id]?.currentContext;
    if (card == null || !card.mounted) return;
    final box = card.findRenderObject()!;
    final viewport = RenderAbstractViewport.of(box);
    final pixels = Scrollable.of(card).position.pixels;
    final fullyVisible = pixels <= viewport.getOffsetToReveal(box, 0).offset && pixels >= viewport.getOffsetToReveal(box, 1).offset;
    if (!fullyVisible) Scrollable.ensureVisible(card, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncAlarm(_state.workout);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clears the queue too, because the bar may still wait behind the one it replaced while that one animates out.
    if (_undoBar != null) _messenger.clearSnackBars();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workout = _state.workout;
    final rows = listRows(workout);
    final note = workout.note.isEmpty ? null : ListTile(leading: const Icon(Icons.notes), title: Text(workout.note), onTap: _editNote);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _pickDay,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Text(dayLabel(widget.day)), const Icon(Icons.arrow_drop_down)]),
          ),
        ),
        actions: [
          if (_isHome) IconButton(icon: const Icon(Icons.history), tooltip: 'History', onPressed: _openHistory),
          PopupMenuButton<VoidCallback>(
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(value: _editNote, child: const Text('Workout note')),
              PopupMenuItem(value: _copyPast, child: const Text('Copy a past workout')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_unsaved)
            MaterialBanner(
              content: const Text('Not saved. Setlist tries again on the next change.'),
              actions: [TextButton(onPressed: () => _persist(_state.workout), child: const Text('Retry'))],
            ),
          Expanded(
            child: workout.slots.isEmpty
                ? ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      ?note,
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.tonalIcon(onPressed: _addExercise, icon: const Icon(Icons.add), label: const Text('Add exercise'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56))),
                      ),
                      if (_recent.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text('Copy a recent workout', style: Theme.of(context).textTheme.titleSmall),
                        ),
                      for (final past in _recent) CopyTile(workout: past, onCopy: () => _copy(past)),
                    ],
                  )
                // A cancelled drag reports no end and no drop.
                : Listener(
                    onPointerCancel: (_) => _land(),
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      // Every card stays built, so a card the focus moves to can be scrolled to. A day has about ten exercises at most.
                      scrollCacheExtent: const ScrollCacheExtent.pixels(20000),
                      padding: const EdgeInsets.only(top: 4, bottom: 16),
                      itemCount: rows.length,
                      onReorderStart: (i) {
                        if (rows[i] case SupersetTop(:final superset)) setState(() => _lifted = (from: i, superset: superset));
                      },
                      // A drop back where the drag started reports no reorder, so nothing else would open the folded rows.
                      onReorderEnd: (i) {
                        final lifted = _lifted;
                        if (lifted != null && (i > lifted.from ? i - 1 : i) == lifted.from) _land();
                      },
                      onReorderItem: (from, to) {
                        _land();
                        final layout = layoutAfterDrop(workout, from, to);
                        if (layout != null) _dispatch(Arrange(layout));
                      },
                      proxyDecorator: (child, i, animation) => AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) {
                          final lift = 6 * Curves.easeInOut.transform(animation.value);
                          return switch (rows[i]) {
                            SupersetTop(:final superset) => _SupersetHeader(index: i, superset: superset, lift: lift),
                            _ => Material(elevation: lift, child: child),
                          };
                        },
                        child: _Lifted(child: child),
                      ),
                      header: note,
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        final key = switch (row) {
                          ExerciseRow(:final exercise) => _cardKeys.putIfAbsent(exercise, GlobalKey.new),
                          SupersetTop(:final superset) || SupersetBottom(:final superset) => ValueKey((row.runtimeType, superset.slots.first.exercise.id)),
                        };
                        if (_folded(i)) return SizedBox.shrink(key: key);
                        final ExerciseId id;
                        switch (row) {
                          case ExerciseRow(:final exercise):
                            id = exercise;
                          case SupersetTop(:final superset):
                            return _SupersetHeader(key: key, index: i, superset: superset);
                          case SupersetBottom():
                            return _SupersetFooter(key: key);
                        }
                        final slot = workout.slotOf(id)!;
                        return _SlotCard(
                          key: key,
                          index: i,
                          slot: slot,
                          framed: workout.entryOf(id) is Superset,
                          canSuperset: _partnersOf(slot).isNotEmpty,
                          focus: _state.focus,
                          lastTime: alignLastTime(slot.sets, _lastTimeOf(id)),
                          collapsed: _collapsed(slot),
                          onToggle: () => setState(() => _collapsedByHand[id] = !_collapsed(slot)),
                          onAction: (action) => _cardAction(slot, action),
                          onCommand: _dispatch,
                        );
                      },
                      footer: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: OutlinedButton.icon(onPressed: _addExercise, icon: const Icon(Icons.add), label: const Text('Add exercise'), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48))),
                      ),
                    ),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: workout.slots.isEmpty ? null : _Panel(state: _state, onCommand: _dispatch),
    );
  }
}

enum _CardAction { history, edit, superset, remove }

/// A superset's frame is drawn by three kinds of list row that meet edge to edge, so it reads as one shape while each part stays its own row for the drag: [_SupersetHeader] on top, the frame's sides around each of its cards, and [_SupersetFooter] below. The frame lines up with plain cards, and the cards inside are inset by [_frameSide].
const _cardSide = 12.0;
const _frameSide = 8.0;
const _frameRadius = Radius.circular(16);

/// A quiet tint of the primary colour, well below the focused row's highlight, so a superset reads as a group without competing with the set being edited.
Color _frameColor(ColorScheme scheme) => Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface);

/// Marks the floating copy of a dragged row, which draws no frame around a card, because the card may land outside every frame.
class _Lifted extends InheritedWidget {
  const _Lifted({required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Lifted>() != null;

  @override
  bool updateShouldNotify(_Lifted oldWidget) => false;
}

/// With [lift], the strip floats on its own during a drag at that elevation, rounded all round, and its exercises fold into it as one line of names.
class _SupersetHeader extends StatelessWidget {
  const _SupersetHeader({super.key, required this.index, required this.superset, this.lift});

  final int index;
  final Superset superset;
  final double? lift;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = namesOf([superset]);
    final lift = this.lift;
    final title = Text('Superset', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary));
    return Padding(
      padding: const EdgeInsets.fromLTRB(_cardSide, 8, _cardSide, 0),
      child: Material(
        color: _frameColor(theme.colorScheme),
        elevation: lift ?? 0,
        borderRadius: lift == null ? const BorderRadius.vertical(top: _frameRadius) : const BorderRadius.all(_frameRadius),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(_frameSide + 14, 12, 14, 12),
                  child: Icon(Icons.drag_indicator, semanticLabel: 'Drag to reorder superset $names'),
                ),
              ),
              if (lift == null)
                title
              else
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      Text(names, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupersetFooter extends StatelessWidget {
  const _SupersetFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_cardSide, 0, _cardSide, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(color: _frameColor(Theme.of(context).colorScheme), borderRadius: const BorderRadius.vertical(bottom: _frameRadius)),
        child: const SizedBox(height: 12, width: double.infinity),
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({super.key, required this.index, required this.slot, required this.framed, required this.canSuperset, required this.focus, required this.lastTime, required this.collapsed, required this.onToggle, required this.onAction, required this.onCommand});

  final int index;
  final Slot slot;

  /// The card sits inside a superset's frame and draws the frame's sides around itself.
  final bool framed;

  /// The day has an exercise "Superset with…" could offer.
  final bool canSuperset;
  final SetRef? focus;
  final List<SetEntry?> lastTime;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<_CardAction> onAction;
  final ValueChanged<Command> onCommand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = slot.exercise.id;
    final kind = slot.exercise.kind;
    final labels = setLabels(slot.sets);
    final top = slot.topSet;
    final count = slot.sets.length == 1 ? '1 set' : '${slot.sets.length} sets';
    final header = InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(padding: const EdgeInsets.all(14), child: Icon(Icons.drag_indicator, semanticLabel: 'Drag to reorder ${slot.exercise.name}')),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(slot.exercise.name, style: theme.textTheme.titleMedium),
                  if (collapsed) Text(top == null ? count : '$count · top ${top.describe(kind)}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            slot.finished ? Icon(Icons.check_circle, color: theme.colorScheme.primary, semanticLabel: 'Finished') : Text('${slot.doneCount}/${slot.sets.length}', style: theme.textTheme.labelLarge),
            PopupMenuButton<_CardAction>(
              tooltip: 'More for ${slot.exercise.name}',
              onSelected: onAction,
              itemBuilder: (_) => [
                const PopupMenuItem(value: _CardAction.history, child: Text('History')),
                const PopupMenuItem(value: _CardAction.edit, child: Text('Edit exercise')),
                if (canSuperset) const PopupMenuItem(value: _CardAction.superset, child: Text('Superset with…')),
                const PopupMenuItem(value: _CardAction.remove, child: Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
    final card = Card(
      margin: EdgeInsets.symmetric(horizontal: framed ? _frameSide : _cardSide, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (!collapsed) ...[
            for (var i = 0; i < slot.sets.length; i++)
              Dismissible(
                // The set count is part of the key, so a removal gives every row a fresh key and the dismissed row never comes back as its neighbour.
                key: ValueKey((i, slot.sets.length)),
                direction: DismissDirection.endToStart,
                background: ColoredBox(
                  color: theme.colorScheme.errorContainer,
                  child: Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(right: 24), child: Icon(Icons.delete, color: theme.colorScheme.onErrorContainer))),
                ),
                onDismissed: (_) => onCommand(RemoveSet((exercise: id, index: i))),
                child: _SetRow(
                  label: labels[i],
                  set: slot.sets[i],
                  kind: kind,
                  lastTime: lastTime[i]?.describe(kind),
                  focused: focus == (exercise: id, index: i),
                  onTap: () => onCommand(FocusSet((exercise: id, index: i))),
                  onCheck: () => onCommand(slot.sets[i].isDone ? UnlogSet((exercise: id, index: i)) : LogSet((exercise: id, index: i), at: DateTime.now())),
                  onLongPress: () => _showSetOptions(context, (exercise: id, index: i), slot.sets[i], onCommand),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 4),
                child: TextButton.icon(onPressed: () => onCommand(AddSet(id)), icon: const Icon(Icons.add), label: const Text('Add set')),
              ),
            ),
          ],
        ],
      ),
    );
    if (!framed) return card;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _cardSide),
      child: _Lifted.of(context) ? card : ColoredBox(color: _frameColor(theme.colorScheme), child: card),
    );
  }
}

enum _SetOption { warmup, note, delete }

Future<void> _showSetOptions(BuildContext context, SetRef ref, SetEntry set, ValueChanged<Command> onCommand) async {
  final choice = await showModalBottomSheet<_SetOption>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(title: const Text('Warm-up'), value: set.warmup, onChanged: (_) => Navigator.pop(context, _SetOption.warmup)),
          ListTile(leading: const Icon(Icons.notes), title: Text(set.note.isEmpty ? 'Add note' : 'Edit note'), onTap: () => Navigator.pop(context, _SetOption.note)),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete set'), onTap: () => Navigator.pop(context, _SetOption.delete)),
        ],
      ),
    ),
  );
  switch (choice) {
    case _SetOption.warmup:
      onCommand(SetWarmup(ref, warmup: !set.warmup));
    case _SetOption.note:
      if (!context.mounted) return;
      final note = await askText(context, title: 'Set note', initial: set.note);
      if (note != null) onCommand(SetSetNote(ref, note));
    case _SetOption.delete:
      onCommand(RemoveSet(ref));
    case null:
      return;
  }
}

class _SetRow extends StatelessWidget {
  const _SetRow({required this.label, required this.set, required this.kind, required this.lastTime, required this.focused, required this.onTap, required this.onCheck, required this.onLongPress});

  final String label;
  final SetEntry set;
  final ExerciseKind kind;
  final String? lastTime;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback onCheck;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final onRow = focused ? theme.colorScheme.onSecondaryContainer : null;
    return Material(
      color: focused ? theme.colorScheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.only(left: 20, right: 4),
          child: Row(
            children: [
              SizedBox(width: 32, child: Text(label, style: theme.textTheme.titleSmall?.copyWith(color: set.warmup ? muted : onRow))),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(setText(set, kind), style: theme.textTheme.bodyLarge?.copyWith(color: onRow, fontWeight: focused ? FontWeight.w600 : null)),
                      if (set.note.isNotEmpty) Text(set.note, style: theme.textTheme.bodySmall?.copyWith(color: muted, fontStyle: FontStyle.italic)),
                    ],
                  ),
                ),
              ),
              if (lastTime != null) Text('last $lastTime', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              IconButton(
                onPressed: onCheck,
                tooltip: set.isDone ? 'Unlog set $label' : 'Log set $label',
                icon: set.isDone ? Icon(Icons.check_circle, color: theme.colorScheme.primary) : Icon(Icons.radio_button_unchecked, color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.state, required this.onCommand});

  final DayState state;
  final ValueChanged<Command> onCommand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ref = state.focus;
    final Widget content;
    if (ref == null) {
      content = _SummaryPanel(summary: state.workout.summary);
    } else {
      final slot = state.workout.slotOf(ref.exercise)!;
      final set = slot.sets[ref.index];
      final rest = state.workout.restAt(DateTime.now());
      final label = setLabels(slot.sets)[ref.index];
      final working = slot.sets.where((s) => !s.warmup).length;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(slot.exercise.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(set.warmup ? 'Warm-up' : 'Set $label of $working', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (rest != null) _RestCountdown(rest: rest),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final (i, field) in slot.exercise.kind.fields.indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(
                  child: _Stepper(
                    field: field,
                    value: field.read(set),
                    onStep: (up) => onCommand(SetField(ref, field, field.stepped(slot.exercise, field.read(set), up: up))),
                    onTyped: (value) => onCommand(SetField(ref, field, value)),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56), textStyle: theme.textTheme.titleMedium),
            onPressed: () => onCommand(LogSet(ref, at: DateTime.now())),
            child: Text(set.isDone ? 'Next set' : 'Log set'),
          ),
        ],
      );
    }
    return Material(
      key: const ValueKey('panel'),
      color: theme.colorScheme.surfaceContainer,
      elevation: 8,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: content,
      ),
    );
  }
}

/// [onTyped] fires once, when the dialog is confirmed, never per keystroke. Each call runs the cascade, and typing 10 over a 5 would pass through 1 and capture any later planned set that really held 1.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.field, required this.value, required this.onStep, required this.onTyped});

  final Field field;
  final int value;
  final ValueChanged<bool> onStep;
  final ValueChanged<int> onTyped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = unitOf(field);
    final name = field.name;
    Widget button(IconData icon, String tooltip, bool up) => Expanded(
      child: Tooltip(
        message: tooltip,
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size(56, 56), padding: EdgeInsets.zero),
          onPressed: () => onStep(up),
          child: Icon(icon, size: 28),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final typed = await showDialog<int>(context: context, builder: (_) => _ValueDialog(field: field, value: value));
            if (typed != null) onTyped(typed);
          },
          child: SizedBox(
            height: 48,
            width: double.infinity,
            child: Center(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: field.format(value), style: theme.textTheme.headlineMedium),
                    if (unit != null) TextSpan(text: ' $unit', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
                semanticsLabel: '$name ${field.format(value)}${unit == null ? '' : ' $unit'}, tap to type',
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [button(Icons.remove, 'Decrease $name', false), const SizedBox(width: 8), button(Icons.add, 'Increase $name', true)]),
      ],
    );
  }
}

class _ValueDialog extends StatefulWidget {
  const _ValueDialog({required this.field, required this.value});

  final Field field;
  final int value;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final _text = TextEditingController(text: widget.field.format(widget.value))..selection = TextSelection(baseOffset: 0, extentOffset: widget.field.format(widget.value).length);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final value = widget.field.parse(_text.text);
    if (value == null) {
      setState(() => _error = switch (widget.field) {
        Field.weight => 'Type a weight such as 102.5',
        Field.reps => 'Type a whole number',
        Field.distance => 'Type metres, or km such as 5.2 km',
        Field.time => 'Type m:ss such as 1:30, or seconds',
      });
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    return AlertDialog(
      title: Text(capitalized(field.name)),
      content: TextField(
        controller: _text,
        autofocus: true,
        keyboardType: switch (field) {
          Field.weight => const TextInputType.numberWithOptions(decimal: true, signed: true),
          Field.reps => TextInputType.number,
          Field.distance => TextInputType.text,
          Field.time => TextInputType.datetime,
        },
        decoration: InputDecoration(suffixText: unitOf(field), errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}

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
  Widget build(BuildContext context) {
    final seconds = (widget.rest.endsAt.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    if (seconds <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = theme.colorScheme.onTertiaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 20, color: color),
            const SizedBox(width: 6),
            Text('Rest ${Field.time.format(seconds)}', style: theme.textTheme.titleMedium?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = summary.elapsed;
    final stats = [
      ('${summary.doneSets}', summary.doneSets == 1 ? 'set' : 'sets'),
      if (summary.volumeGrams > 0) (Field.weight.format(summary.volumeGrams), 'kg volume'),
      if (elapsed != null) (elapsed.inHours > 0 ? '${elapsed.inHours}:${(elapsed.inMinutes % 60).toString().padLeft(2, '0')}' : '${elapsed.inMinutes}', elapsed.inHours > 0 ? 'hours' : 'min'),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('All sets logged', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final (value, label) in stats)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: theme.textTheme.headlineSmall),
                    Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class CopyTile extends StatelessWidget {
  const CopyTile({super.key, required this.workout, required this.onCopy});

  final Workout workout;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(dayLabel(workout.day)),
      subtitle: Text(workout.slots.map((s) => s.exercise.name).join(', '), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: FilledButton.tonal(onPressed: onCopy, child: const Text('Copy')),
    );
  }
}

Future<String?> askText(BuildContext context, {required String title, required String initial}) => showDialog<String>(context: context, builder: (_) => _TextDialog(title: title, initial: initial));

class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(controller: _text, autofocus: true, minLines: 1, maxLines: 5, textCapitalization: TextCapitalization.sentences),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _text.text.trim()), child: const Text('OK')),
      ],
    );
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The exercises of [entries] on one line, as the history and the copy tiles show a day: a superset's names joined with " + ", entries with ", ".
String namesOf(Iterable<Entry> entries) => entries.map((e) => e.slots.map((s) => s.exercise.name).join(' + ')).join(', ');

String dayLabel(Day day) {
  final now = DateTime.now();
  if (day == Day.of(now)) return 'Today';
  if (day == Day.of(DateTime(now.year, now.month, now.day - 1))) return 'Yesterday';
  final date = day.date;
  final short = '${_weekdays[date.weekday - 1]} ${date.day} ${_months[date.month - 1]}';
  return date.year == now.year ? short : '$short ${date.year}';
}

/// The unit shown after a stepper value. Distance and time carry theirs in [Field.format].
String? unitOf(Field field) => switch (field) {
  Field.weight => 'kg',
  Field.reps => 'reps',
  Field.distance || Field.time => null,
};

String setText(SetEntry set, ExerciseKind kind) {
  if (kind == ExerciseKind.weightReps) return '${Field.weight.format(set.grams)} kg × ${set.reps}';
  return [
    for (final field in kind.fields)
      switch (unitOf(field)) {
        final unit? => '${field.format(field.read(set))} $unit',
        null => field.format(field.read(set)),
      },
  ].join(' · ');
}

List<String> setLabels(List<SetEntry> sets) {
  var working = 0;
  return [for (final set in sets) set.warmup ? 'W' : '${++working}'];
}

String capitalized(String text) => text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

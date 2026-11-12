/// Choosing an exercise for a day, creating one, or editing one. Two entry points, [pickExercise] and [editExercise]; the screen and the dialog behind them are private.
library;

import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';
import 'workout_screen.dart';

/// Shows every exercise, most recently done first, with a search field, and returns the one picked, or null on back. Exercises already in the day carry a check and can still be picked, so the caller scrolls to them. When the search matches no name exactly, the first row offers to create it.
Future<Exercise?> pickExercise(BuildContext context, Store store, {Set<ExerciseId> inDay = const {}}) {
  return Navigator.push<Exercise>(context, MaterialPageRoute(builder: (_) => _PickerScreen(store: store, inDay: inDay)));
}

/// Edits name, kind, category, increment and rest of [exercise] and saves them through [Store.updateExercise]. Returns the saved exercise, or null on Cancel. The caller dispatches [UpdateExercise] so the open day shows it.
Future<Exercise?> editExercise(BuildContext context, Store store, Exercise exercise) {
  return showDialog<Exercise>(
    context: context,
    builder: (_) => _ExerciseDialog(
      title: 'Edit exercise',
      action: 'Save',
      initial: (name: exercise.name, kind: exercise.kind, category: exercise.category, weightStepGrams: exercise.weightStepGrams, rest: exercise.rest),
      save: (d) {
        final edited = Exercise(id: exercise.id, name: d.name, kind: d.kind, category: d.category, weightStepGrams: d.weightStepGrams, rest: d.rest);
        store.updateExercise(edited);
        return edited;
      },
    ),
  );
}

class _PickerScreen extends StatefulWidget {
  const _PickerScreen({required this.store, required this.inDay});

  final Store store;
  final Set<ExerciseId> inDay;

  @override
  State<_PickerScreen> createState() => _PickerScreenState();
}

class _PickerScreenState extends State<_PickerScreen> {
  late final List<Exercise> _all = widget.store.exercises();
  String _query = '';

  /// Name or category contains the query, ignoring case, in the store's order.
  List<Exercise> get _matches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return [
      for (final e in _all)
        if (e.name.toLowerCase().contains(q) || (e.category?.toLowerCase().contains(q) ?? false)) e,
    ];
  }

  bool get _exactMatch => _all.any((e) => e.name.toLowerCase() == _query.trim().toLowerCase());

  Future<void> _create() async {
    final defaults = widget.store.loadDefaults();
    final created = await showDialog<Exercise>(
      context: context,
      builder: (_) => _ExerciseDialog(
        title: 'New exercise',
        action: 'Create',
        initial: (name: _query.trim(), kind: ExerciseKind.weightReps, category: null, weightStepGrams: defaults.weightStepGrams, rest: defaults.rest),
        save: (d) => widget.store.createExercise(name: d.name, kind: d.kind, category: d.category, weightStepGrams: d.weightStepGrams, rest: d.rest),
      ),
    );
    if (created != null && mounted) Navigator.pop(context, created);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final query = _query.trim();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Search exercises', border: InputBorder.none),
          onChanged: (q) => setState(() => _query = q),
        ),
      ),
      body: ListView(
        children: [
          if (query.isNotEmpty && !_exactMatch) ListTile(leading: const Icon(Icons.add), title: Text('Create "$query"'), onTap: _create),
          if (query.isEmpty && _all.isEmpty) const ListTile(title: Text('Type a name to create your first exercise.')),
          for (final e in matches)
            ListTile(
              title: Text(e.name),
              subtitle: e.category == null ? null : Text(e.category!),
              trailing: widget.inDay.contains(e.id) ? const Icon(Icons.check, semanticLabel: 'In this day') : null,
              onTap: () => Navigator.pop(context, e),
            ),
        ],
      ),
    );
  }
}

typedef _Draft = ({String name, ExerciseKind kind, String? category, int weightStepGrams, Duration rest});

/// Name, kind (the ten combinations), category, weight increment and rest. [save] writes the draft and may throw [DuplicateExerciseName], which keeps the dialog open with the error under the name.
class _ExerciseDialog extends StatefulWidget {
  const _ExerciseDialog({required this.title, required this.action, required this.initial, required this.save});

  final String title;
  final String action;
  final _Draft initial;
  final Exercise Function(_Draft draft) save;

  @override
  State<_ExerciseDialog> createState() => _ExerciseDialogState();
}

class _ExerciseDialogState extends State<_ExerciseDialog> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _category = TextEditingController(text: widget.initial.category ?? '');
  late final _step = TextEditingController(text: Field.weight.format(widget.initial.weightStepGrams));
  late final _rest = TextEditingController(text: Field.time.format(widget.initial.rest.inSeconds));
  late ExerciseKind _kind = widget.initial.kind;
  String? _nameError;
  String? _stepError;
  String? _restError;

  @override
  void dispose() {
    for (final c in [_name, _category, _step, _rest]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final step = _kind.fields.contains(Field.weight) ? Field.weight.parse(_step.text) : widget.initial.weightStepGrams;
    final rest = Field.time.parse(_rest.text);
    setState(() {
      _nameError = name.isEmpty ? 'Give it a name' : null;
      _stepError = step == null || step <= 0 ? 'Type a step above 0, such as 2.5' : null;
      _restError = rest == null ? 'Type m:ss such as 2:00' : null;
    });
    if (_nameError != null || _stepError != null || _restError != null) return;
    final category = _category.text.trim();
    try {
      final saved = widget.save((name: name, kind: _kind, category: category.isEmpty ? null : category, weightStepGrams: step!, rest: Duration(seconds: rest!)));
      Navigator.pop(context, saved);
    } on DuplicateExerciseName {
      setState(() => _nameError = 'An exercise with this name exists');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _name, autofocus: _name.text.isEmpty, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: 'Name', errorText: _nameError)),
          const SizedBox(height: 12),
          DropdownButtonFormField<ExerciseKind>(
            initialValue: _kind,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Records'),
            items: [for (final kind in ExerciseKind.values) DropdownMenuItem(value: kind, child: Text(capitalized(kind.fields.map((f) => f.name).join(' and '))))],
            onChanged: (kind) => setState(() => _kind = kind ?? _kind),
          ),
          const SizedBox(height: 12),
          TextField(controller: _category, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Category (optional)')),
          if (_kind.fields.contains(Field.weight)) ...[
            const SizedBox(height: 12),
            TextField(controller: _step, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Weight step', suffixText: 'kg', errorText: _stepError)),
          ],
          const SizedBox(height: 12),
          TextField(controller: _rest, keyboardType: TextInputType.datetime, decoration: InputDecoration(labelText: 'Rest', helperText: 'm:ss', errorText: _restError)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

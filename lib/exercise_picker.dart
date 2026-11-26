library;

import 'package:flutter/material.dart';

import 'day.dart';
import 'equipment_mark.dart';
import 'store.dart';
import 'workout_screen.dart';

Future<Exercise?> pickExercise(BuildContext context, Store store, {Set<ExerciseId> inDay = const {}}) {
  return Navigator.push<Exercise>(context, MaterialPageRoute(builder: (_) => _PickerScreen(store: store, inDay: inDay)));
}

/// Edits name, kind, category, increment, rest and equipment of [exercise] and saves them through [Store.updateExercise]. Returns the saved exercise, or null on Cancel. The caller dispatches [UpdateExercise] so the open day shows it.
Future<Exercise?> editExercise(BuildContext context, Store store, Exercise exercise) {
  return showDialog<Exercise>(
    context: context,
    builder: (_) => _ExerciseDialog(
      title: 'Edit exercise',
      action: 'Save',
      initial: (name: exercise.name, kind: exercise.kind, category: exercise.category, weightStepGrams: exercise.weightStepGrams, rest: exercise.rest, equipment: exercise.equipment),
      save: (d) {
        final edited = Exercise(id: exercise.id, name: d.name, kind: d.kind, equipment: d.equipment, category: d.category, weightStepGrams: d.weightStepGrams, rest: d.rest);
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
        initial: (name: _query.trim(), kind: ExerciseKind.weightReps, category: null, weightStepGrams: defaults.weightStepGrams, rest: defaults.rest, equipment: Equipment.none),
        save: (d) => widget.store.createExercise(name: d.name, kind: d.kind, category: d.category, weightStepGrams: d.weightStepGrams, rest: d.rest, equipment: d.equipment),
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

typedef _Draft = ({String name, ExerciseKind kind, String? category, int weightStepGrams, Duration rest, Equipment equipment});

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
  late final _bar = TextEditingController(
    text: Field.weight.format(switch (widget.initial.equipment) {
      Barbell(:final barGrams) => barGrams,
      _ => Barbell.standardBarGrams,
    }),
  );
  late final _handle = TextEditingController(
    text: switch (widget.initial.equipment) {
      Dumbbell(handleGrams: final handle?) => Field.weight.format(handle),
      _ => '',
    },
  );
  late ExerciseKind _kind = widget.initial.kind;
  late Equipment _equipment = widget.initial.equipment;
  String? _nameError;
  String? _stepError;
  String? _barError;
  String? _handleError;
  String? _restError;

  @override
  void dispose() {
    for (final c in [_name, _category, _step, _bar, _handle, _rest]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final hasWeight = _kind.fields.contains(Field.weight);
    final step = hasWeight ? Field.weight.parse(_step.text) : widget.initial.weightStepGrams;
    final bar = Field.weight.parse(_bar.text);
    final handleText = _handle.text.trim();
    final handle = handleText.isEmpty ? null : Field.weight.parse(handleText);
    final rest = Field.time.parse(_rest.text);
    setState(() {
      _nameError = name.isEmpty ? 'Give it a name' : null;
      _stepError = step == null || step <= 0 ? 'Type a step above 0, such as 2.5' : null;
      _barError = hasWeight && _equipment is Barbell && (bar == null || bar <= 0) ? 'Type a bar weight above 0, such as 20' : null;
      _handleError = hasWeight && _equipment is Dumbbell && handleText.isNotEmpty && (handle == null || handle <= 0) ? 'Type a handle weight above 0, or leave it empty' : null;
      _restError = rest == null ? 'Type m:ss such as 2:00' : null;
    });
    if (_nameError != null || _stepError != null || _barError != null || _handleError != null || _restError != null) return;
    final category = _category.text.trim();
    final equipment = !hasWeight
        ? Equipment.none
        : switch (_equipment) {
            Barbell() => Barbell(bar!),
            DumbbellPair() => DumbbellPair(handleGrams: handle),
            OneDumbbell() => OneDumbbell(handleGrams: handle),
            NoEquipment() => Equipment.none,
          };
    try {
      final saved = widget.save((name: name, kind: _kind, category: category.isEmpty ? null : category, weightStepGrams: step!, rest: Duration(seconds: rest!), equipment: equipment));
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
            const SizedBox(height: 12),
            DropdownButtonFormField<Equipment>(
              initialValue: _equipment,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Equipment'),
              items: [
                for (final e in Equipment.choices(
                  barGrams: switch (_equipment) {
                    Barbell(:final barGrams) => barGrams,
                    _ => Barbell.standardBarGrams,
                  },
                  handleGrams: switch (_equipment) {
                    Dumbbell(:final handleGrams) => handleGrams,
                    _ => null,
                  },
                ))
                  DropdownMenuItem(
                    value: e,
                    child: Row(
                      children: [
                        Expanded(child: Text(e.label)),
                        EquipmentMark(e, height: 16, color: Theme.of(context).colorScheme.onSurfaceVariant, gap: 0),
                      ],
                    ),
                  ),
              ],
              onChanged: (e) => setState(() => _equipment = e ?? _equipment),
            ),
            if (_equipment is Barbell) ...[
              const SizedBox(height: 12),
              TextField(controller: _bar, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Bar weight', suffixText: 'kg', errorText: _barError)),
            ],
            if (_equipment is Dumbbell) ...[
              const SizedBox(height: 12),
              TextField(controller: _handle, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Handle weight (optional)', helperText: 'For adjustable dumbbells', suffixText: 'kg', errorText: _handleError)),
            ],
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

/// Choosing an exercise for a day, or creating one. One entry point, [pickExercise]; the screen behind it is private.
library;

import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';

/// Shows every exercise, most recently done first, with a search field, and returns the one picked, or null on back. Exercises already in the day carry a check and can still be picked, so the caller scrolls to them. When the search matches no name exactly, the first row offers to create it.
Future<Exercise?> pickExercise(BuildContext context, Store store, {Set<ExerciseId> inDay = const {}}) {
  return Navigator.push<Exercise>(context, MaterialPageRoute(builder: (_) => _PickerScreen(store: store, inDay: inDay)));
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
  List<Exercise> get _matches => throw UnimplementedError();

  bool get _exactMatch => _all.any((e) => e.name.toLowerCase() == _query.trim().toLowerCase());

  Future<void> _create() async {
    final draft = await _showCreateDialog(context, name: _query.trim());
    if (draft == null || !mounted) return;
    try {
      final created = widget.store.createExercise(name: draft.name, kind: draft.kind, category: draft.category, weightStepGrams: draft.weightStepGrams, rest: draft.rest);
      Navigator.pop(context, created);
    } on DuplicateExerciseName {
      // TODO: show "An exercise with this name exists" in the dialog instead of closing it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return Scaffold(
      appBar: AppBar(title: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Search exercises'), onChanged: (q) => setState(() => _query = q))),
      body: ListView(children: [
        if (_query.trim().isNotEmpty && !_exactMatch) ListTile(leading: const Icon(Icons.add), title: Text('Create "${_query.trim()}"'), onTap: _create),
        for (final e in matches)
          ListTile(
            title: Text(e.name),
            subtitle: e.category == null ? null : Text(e.category!),
            trailing: widget.inDay.contains(e.id) ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, e),
          ),
      ]),
    );
  }
}

typedef _Draft = ({String name, ExerciseKind kind, String? category, int weightStepGrams, Duration rest});

/// Name, kind (the ten combinations), category, weight increment and rest. The defaults are weight and reps, 2.5 kg and 2:00.
Future<_Draft?> _showCreateDialog(BuildContext context, {required String name}) => throw UnimplementedError();

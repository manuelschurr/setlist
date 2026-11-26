import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';

/// Edits the plates the lifter owns and saves them through [Store.savePlates]. Returns the saved plates, or null on Cancel.
Future<Plates?> editPlates(BuildContext context, Store store) => showDialog<Plates>(context: context, builder: (_) => _PlatesDialog(store: store));

/// Offered even when not owned, so a usual set is entered by ticks alone.
const _usualGrams = [500, 1000, 1250, 2000, 2500, 5000, 10000, 15000, 20000, 25000];

class _PlatesDialog extends StatefulWidget {
  const _PlatesDialog({required this.store});

  final Store store;

  @override
  State<_PlatesDialog> createState() => _PlatesDialogState();
}

class _PlatesDialogState extends State<_PlatesDialog> {
  late final Plates _saved = widget.store.loadPlates();
  late final Set<int> _owned = {..._saved.pieces.keys};

  /// One optional count per size, lightest first.
  late final Map<int, TextEditingController> _counts = {
    for (final grams in {..._usualGrams, ..._saved.pieces.keys}.toList()..sort()) grams: TextEditingController(text: _saved.pieces[grams]?.toString() ?? ''),
  };

  final _newSize = TextEditingController();
  String? _newSizeError;
  final Set<int> _badCounts = {};

  @override
  void dispose() {
    for (final c in [..._counts.values, _newSize]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggle(int grams) => setState(() => _owned.contains(grams) ? _owned.remove(grams) : _owned.add(grams));

  void _addSize() {
    final grams = Field.weight.parse(_newSize.text);
    setState(() {
      _newSizeError = grams == null || grams <= 0 ? 'Type a weight above 0, such as 0.75' : null;
      if (grams == null || grams <= 0) return;
      _counts.putIfAbsent(grams, TextEditingController.new);
      final sorted = _counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      _counts
        ..clear()
        ..addEntries(sorted);
      _owned.add(grams);
      _newSize.clear();
    });
  }

  /// A ticked size with an empty count stands for as many as a lift needs, and a count of 0 means not owned.
  void _save() {
    final counts = {for (final grams in _owned) grams: _counts[grams]!.text.trim()};
    setState(() {
      _badCounts
        ..clear()
        ..addAll([for (final MapEntry(key: grams, value: text) in counts.entries) if (text.isNotEmpty && (int.tryParse(text) ?? -1) < 0) grams]);
    });
    if (_badCounts.isNotEmpty) return;
    final plates = Plates({
      for (final MapEntry(key: grams, value: text) in counts.entries)
        if (text != '0') grams: text.isEmpty ? null : int.parse(text),
    });
    widget.store.savePlates(plates);
    Navigator.pop(context, plates);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Your plates'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tick the plates you own, and count only those you could run short of. Barbells and adjustable dumbbells then show which plates to load.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final MapEntry(key: grams, value: controller) in _counts.entries)
            InkWell(
              onTap: () => _toggle(grams),
              child: Row(
                children: [
                  Checkbox(key: ValueKey('plates $grams'), value: _owned.contains(grams), onChanged: (_) => _toggle(grams)),
                  Expanded(child: Text('${Field.weight.format(grams)} kg', style: theme.textTheme.bodyLarge)),
                  SizedBox(
                    width: 88,
                    child: TextField(
                      key: ValueKey('plate count $grams'),
                      controller: controller,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.end,
                      decoration: InputDecoration(hintText: _owned.contains(grams) ? 'any' : null, suffixText: 'pcs', isDense: true, errorText: _badCounts.contains(grams) ? 'Whole number' : null),
                      onChanged: (text) {
                        if (text.trim().isNotEmpty && !_owned.contains(grams)) setState(() => _owned.add(grams));
                      },
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(controller: _newSize, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Another size', suffixText: 'kg', errorText: _newSizeError), onSubmitted: (_) => _addSize()),
              ),
              IconButton(icon: const Icon(Icons.add), tooltip: 'Add size', onPressed: _addSize),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

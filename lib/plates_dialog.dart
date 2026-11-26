import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';

/// Edits the plates the lifter owns and saves them through [Store.savePlates]. Returns the saved plates, or null on Cancel.
Future<Plates?> editPlates(BuildContext context, Store store) => showDialog<Plates>(context: context, builder: (_) => _PlatesDialog(store: store));

/// Offered as rows even when none is owned, so a usual set is entered by counts alone.
const _usualGrams = [500, 1000, 1250, 2000, 2500, 5000, 10000, 15000, 20000, 25000];

class _PlatesDialog extends StatefulWidget {
  const _PlatesDialog({required this.store});

  final Store store;

  @override
  State<_PlatesDialog> createState() => _PlatesDialogState();
}

class _PlatesDialogState extends State<_PlatesDialog> {
  late final Plates _owned = widget.store.loadPlates();

  /// One count field per weight, lightest first.
  late final Map<int, TextEditingController> _counts = {
    for (final grams in {..._usualGrams, ..._owned.pieces.keys}.toList()..sort()) grams: TextEditingController(text: _owned.pieces[grams]?.toString() ?? ''),
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

  int? _count(String text) => text.trim().isEmpty ? 0 : int.tryParse(text.trim());

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
      _newSize.clear();
    });
  }

  void _save() {
    final counts = {for (final MapEntry(key: grams, value: c) in _counts.entries) grams: _count(c.text)};
    setState(() {
      _badCounts
        ..clear()
        ..addAll([for (final MapEntry(key: grams, value: n) in counts.entries) if (n == null || n < 0) grams]);
    });
    if (_badCounts.isNotEmpty) return;
    final plates = Plates({for (final MapEntry(key: grams, value: n) in counts.entries) grams: n!});
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
          Text('How many of each plate you own, counting every piece. Adjustable dumbbells then show which plates go on each end.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final MapEntry(key: grams, value: controller) in _counts.entries)
            Row(
              children: [
                Expanded(child: Text('${Field.weight.format(grams)} kg', style: theme.textTheme.bodyLarge)),
                SizedBox(
                  width: 88,
                  child: TextField(
                    key: ValueKey('plates $grams'),
                    controller: controller,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    decoration: InputDecoration(hintText: '0', suffixText: 'pcs', isDense: true, errorText: _badCounts.contains(grams) ? 'Whole number' : null),
                  ),
                ),
              ],
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

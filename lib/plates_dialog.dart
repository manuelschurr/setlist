import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';

/// Edits the plate sizes the lifter owns and saves them through [Store.savePlates]. Returns the saved plates, or null on Cancel.
Future<Plates?> editPlates(BuildContext context, Store store) => showDialog<Plates>(context: context, builder: (_) => _PlatesDialog(store: store));

/// Offered even when not owned, so a usual set is entered by taps alone.
const _usualGrams = [500, 1000, 1250, 2000, 2500, 5000, 10000, 15000, 20000, 25000];

class _PlatesDialog extends StatefulWidget {
  const _PlatesDialog({required this.store});

  final Store store;

  @override
  State<_PlatesDialog> createState() => _PlatesDialogState();
}

class _PlatesDialogState extends State<_PlatesDialog> {
  late final Set<int> _owned = {...widget.store.loadPlates().sizes};

  /// Every size offered, lightest first.
  late final List<int> _sizes = {..._usualGrams, ..._owned}.toList()..sort();

  final _newSize = TextEditingController();
  String? _newSizeError;

  @override
  void dispose() {
    _newSize.dispose();
    super.dispose();
  }

  void _addSize() {
    final grams = Field.weight.parse(_newSize.text);
    setState(() {
      _newSizeError = grams == null || grams <= 0 ? 'Type a weight above 0, such as 0.75' : null;
      if (grams == null || grams <= 0) return;
      if (!_sizes.contains(grams)) {
        _sizes
          ..add(grams)
          ..sort();
      }
      _owned.add(grams);
      _newSize.clear();
    });
  }

  void _save() {
    final plates = Plates(_owned);
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
          Text('Tap the sizes you own. Barbells and adjustable dumbbells then show which plates to load.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final grams in _sizes)
                FilterChip(
                  key: ValueKey('plates $grams'),
                  label: Text('${Field.weight.format(grams)} kg'),
                  selected: _owned.contains(grams),
                  onSelected: (owned) => setState(() => owned ? _owned.add(grams) : _owned.remove(grams)),
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

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'day.dart';

/// One end of an adjustable dumbbell seen from the side: a stub of the handle, then [plates] in grams from the inside out, each a dark plate with its weight on it and taller the heavier it is, so the lifter reads the loading without a sentence.
class PlateStrip extends StatelessWidget {
  const PlateStrip(this.plates, {super.key});

  final List<int> plates;

  /// The tallest plate, which the panel reserves so the value above never moves.
  static const maxHeight = 20.0;

  static const _minHeight = 15.0;

  /// Real plates grow in diameter far slower than in weight, so 0.5 to 25 kg spans the heights on a log scale.
  static double _height(int grams) => _minHeight + (maxHeight - _minHeight) * (math.log(grams / 500) / math.log(50)).clamp(0, 1);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.surface, fontWeight: FontWeight.w700, height: 1, fontSize: 12);
    final textScaler = MediaQuery.textScalerOf(context);
    Widget bar(double width) => Container(width: width, height: 4, color: scheme.outline);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          bar(6),
          for (final (i, grams) in plates.indexed) ...[
            if (i > 0) bar(1.5),
            Container(
              height: textScaler.scale(_height(grams)),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: scheme.onSurfaceVariant, borderRadius: BorderRadius.circular(3)),
              child: Text(Field.weight.format(grams), style: label),
            ),
          ],
          bar(4),
        ],
      ),
    );
  }
}

library;

import 'package:flutter/widgets.dart';

import 'day.dart';

/// The passive marker drawn before a weight, in [color], [height] logical pixels tall and scaled with the text beside it. Draws nothing for [Equipment.none].
class EquipmentMark extends StatelessWidget {
  const EquipmentMark(this.equipment, {super.key, required this.height, required this.color, this.gap = 8});

  final Equipment equipment;
  final double height;
  final Color color;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final aspect = switch (equipment) {
      NoEquipment() => null,
      Barbell() => 1.8,
      DumbbellPair() || OneDumbbell() => 1.3,
    };
    if (aspect == null) return const SizedBox.shrink();
    final h = MediaQuery.textScalerOf(context).scale(height);
    return Padding(
      padding: EdgeInsetsDirectional.only(end: gap),
      child: Semantics(
        label: equipment.label,
        child: CustomPaint(size: Size(h * aspect, h), painter: _GlyphPainter(equipment, color)),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.equipment, this.color);

  final Equipment equipment;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final paint = Paint()..color = color;
    void box(Offset centre, double width, double height, double radius) => canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: centre, width: width, height: height), Radius.circular(radius)), paint);
    void dumbbell(Offset centre, double s) {
      box(centre, s * 0.5, s * 0.12, s * 0.06);
      for (final side in [-1, 1]) {
        box(centre.translate(side * s * 0.3, 0), s * 0.16, s * 0.5, s * 0.06);
      }
    }

    final w = size.width;
    switch (equipment) {
      case NoEquipment():
        break;
      case Barbell():
        final r = h * 0.06;
        box(Offset(w / 2, h / 2), w, h * 0.1, r);
        for (final x in [w * 0.16, w * 0.84]) {
          box(Offset(x, h / 2), h * 0.16, h * 0.86, r);
        }
        for (final x in [w * 0.16 - h * 0.16, w * 0.84 + h * 0.16]) {
          box(Offset(x, h / 2), h * 0.12, h * 0.56, r);
        }
      case OneDumbbell():
        dumbbell(Offset(w / 2, h / 2), h * 1.2);
      case DumbbellPair():
        dumbbell(Offset(w / 2, h * 0.24), h * 0.8);
        dumbbell(Offset(w / 2, h * 0.76), h * 0.8);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.equipment != equipment || old.color != color;
}

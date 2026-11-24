import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/main.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

final class _SilentAlarm implements RestAlarm {
  @override
  void show(Rest? rest) {}
}

Future<void> _loadFonts() async {
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final weight in ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(File('$fonts/Roboto-$weight.ttf').readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(File('$fonts/MaterialIcons-Regular.otf').readAsBytes().then((b) => ByteData.view(b.buffer)));
  await icons.load();
}

void main() {
  final out = Platform.environment['SETLIST_RENDER_DIR'];
  final boundary = GlobalKey();
  final today = Day.of(DateTime.now());
  Day daysAgo(int n) {
    final now = DateTime.now();
    return Day.of(DateTime(now.year, now.month, now.day - n));
  }

  SetEntry kg(num w, int r, {bool warmup = false}) => SetEntry(grams: (w * 1000).round(), reps: r, warmup: warmup, status: Done(DateTime.now().subtract(const Duration(days: 3))));

  Future<void> shot(WidgetTester tester, String name, {bool settle = true}) async {
    if (settle) await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: tester.view.devicePixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
    });
  }

  testWidgets('the longest usual barbell caption fits its stepper on the test phone, in real fonts', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8125;
    addTearDown(tester.view.reset);
    final store = Store.inMemory();
    addTearDown(store.close);
    final squat = store.createExercise(name: 'Barbell Squat', kind: ExerciseKind.weightReps, equipment: const Barbell(20000));
    store.saveDay(Workout(day: today, entries: [Slot(squat, [const SetEntry(grams: 102500, reps: 5)])]));
    await tester.pumpWidget(MaterialApp(theme: setlistTheme(Brightness.light), home: WorkoutScreen(store: store, home: Home(day: today, alarm: _SilentAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: today)));
    await tester.pumpAndSettle();
    final caption = find.text(const Barbell(20000).breakdown(102500));
    expect(caption, findsOneWidget);
    expect(tester.renderObject<RenderParagraph>(find.descendant(of: caption, matching: find.byType(RichText))).didExceedMaxLines, isFalse);
  });

  testWidgets('the longest usual adjustable dumbbell caption fits its stepper on the test phone, in real fonts', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8125;
    addTearDown(tester.view.reset);
    final store = Store.inMemory();
    addTearDown(store.close);
    const pair = DumbbellPair(handleGrams: 2500);
    final curl = store.createExercise(name: 'Hammer Curl', kind: ExerciseKind.weightReps, equipment: pair);
    // Plates of 0.5 kg and up on a 2.5 kg handle make every dumbbell a multiple of 0.5 kg, so a pair line never needs more than one decimal on each side.
    store.saveDay(Workout(day: today, entries: [Slot(curl, [const SetEntry(grams: 47000, reps: 8)])]));
    await tester.pumpWidget(MaterialApp(theme: setlistTheme(Brightness.light), home: WorkoutScreen(store: store, home: Home(day: today, alarm: _SilentAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: today)));
    await tester.pumpAndSettle();
    final caption = find.text(pair.breakdown(47000));
    expect(caption, findsOneWidget);
    expect(tester.renderObject<RenderParagraph>(find.descendant(of: caption, matching: find.byType(RichText))).didExceedMaxLines, isFalse);
  });

  testWidgets('the longest plate line for a pair up to 60 kg fits the panel on the test phone, in real fonts', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8125;
    addTearDown(tester.view.reset);
    final store = Store.inMemory();
    addTearDown(store.close);
    final plates = Plates({for (final grams in [500, 1000, 1250, 2000, 2500, 5000, 10000, 15000]) grams: 4});
    store.savePlates(plates);
    const pair = DumbbellPair(handleGrams: 2500);
    final longest = [for (var grams = 5000; grams <= 60000; grams += 500) grams].reduce((a, b) => pair.plateLine(b, plates)!.length > pair.plateLine(a, plates)!.length ? b : a);
    final curl = store.createExercise(name: 'Hammer Curl', kind: ExerciseKind.weightReps, equipment: pair);
    store.saveDay(Workout(day: today, entries: [Slot(curl, [SetEntry(grams: longest, reps: 8)])]));
    await tester.pumpWidget(MaterialApp(theme: setlistTheme(Brightness.light), home: WorkoutScreen(store: store, home: Home(day: today, alarm: _SilentAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: today)));
    await tester.pumpAndSettle();
    final line = find.text(pair.plateLine(longest, plates)!);
    expect(line, findsOneWidget);
    expect(tester.renderObject<RenderParagraph>(find.descendant(of: line, matching: find.byType(RichText))).didExceedMaxLines, isFalse, reason: pair.plateLine(longest, plates));
  });

  testWidgets('render the workout flow', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8125;
    addTearDown(tester.view.reset);

    final store = Store.inMemory();
    addTearDown(store.close);
    final squat = store.createExercise(name: 'Barbell Squat', kind: ExerciseKind.weightReps, category: 'Legs', equipment: const Barbell(20000));
    final bench = store.createExercise(name: 'Incline Dumbbell Bench Press', kind: ExerciseKind.weightReps, category: 'Chest', equipment: const DumbbellPair(handleGrams: 2500));
    store.savePlates(Plates({for (final grams in [500, 1000, 1250, 2000, 2500, 5000]) grams: 4}));
    final raise = store.createExercise(name: 'Lateral Dumbbell Raise', kind: ExerciseKind.weightReps, category: 'Shoulders', equipment: Equipment.oneDumbbell);
    final plank = store.createExercise(name: 'Plank', kind: ExerciseKind.time, category: 'Core');
    store.saveDay(Workout(day: daysAgo(3), entries: [
      Slot(squat, [kg(20, 8, warmup: true), kg(34, 5), kg(34, 5), kg(34, 5)]),
      Slot(bench, [kg(13, 10), kg(13, 10), kg(13, 10)]),
      Slot(raise, [kg(8, 15), kg(8, 15), kg(8, 15)]),
      Slot(plank, [SetEntry(seconds: 60, status: Done(DateTime.now())), SetEntry(seconds: 60, status: Done(DateTime.now()))]),
    ]));

    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: setlistTheme(Brightness.light),
        home: WorkoutScreen(store: store, home: Home(day: today, alarm: _SilentAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: today),
      ),
    ));
    await shot(tester, '01-empty-day');

    await tester.tap(find.text('Copy').first);
    await shot(tester, '02-copied');

    await tester.tap(find.byTooltip('Increase weight').first);
    await shot(tester, '03-plus-on-set-2');

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Log set'));
      await tester.pump(const Duration(seconds: 5));
    }
    await shot(tester, '04-squat-done');

    await tester.binding.setSurfaceSize(null);
    final dark = store.loadDay(today);
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: setlistTheme(Brightness.dark),
        home: WorkoutScreen(store: store, home: Home(day: dark.day, alarm: _SilentAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: dark.day),
      ),
    ));
    await shot(tester, '05-dark');
  }, skip: out == null);

  testWidgets('render a superset day', (tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8125;
    addTearDown(tester.view.reset);

    final store = Store.inMemory();
    addTearDown(store.close);
    final squat = store.createExercise(name: 'Barbell Squat', kind: ExerciseKind.weightReps, category: 'Legs', equipment: const Barbell(20000));
    final bench = store.createExercise(name: 'Incline Dumbbell Bench Press', kind: ExerciseKind.weightReps, category: 'Chest', equipment: Equipment.dumbbellPair);
    final row = store.createExercise(name: 'Chest Supported Row', kind: ExerciseKind.weightReps, category: 'Back');
    final raise = store.createExercise(name: 'Lateral Dumbbell Raise', kind: ExerciseKind.weightReps, category: 'Shoulders', equipment: Equipment.oneDumbbell);
    final curl = store.createExercise(name: 'Cable Curl', kind: ExerciseKind.weightReps, category: 'Arms');
    final pushdown = store.createExercise(name: 'Triceps Pushdown', kind: ExerciseKind.weightReps, category: 'Arms');
    SetEntry plan(num w, int r) => SetEntry(grams: (w * 1000).round(), reps: r);
    store.saveDay(Workout(day: today, entries: [
      Slot(squat, [kg(34, 5), kg(34, 5), kg(34, 5)]),
      Superset([
        Slot(bench, [kg(13, 10), plan(13, 10), plan(13, 10)]),
        Slot(row, [kg(30, 10), plan(30, 10), plan(30, 10)]),
      ]),
      Slot(raise, [plan(8, 15), plan(8, 15)]),
      Superset([
        Slot(curl, [plan(15, 12), plan(15, 12)]),
        Slot(pushdown, [plan(20, 12), plan(20, 12)]),
      ]),
    ]));

    Future<void> open(Brightness brightness) => tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: setlistTheme(brightness),
        home: WorkoutScreen(store: store, home: Home(day: today, alarm: _SilentAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: today),
      ),
    ));

    await open(Brightness.light);
    await shot(tester, '06-superset');

    final strip = find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == 'Drag to reorder superset Incline Dumbbell Bench Press + Chest Supported Row');
    final lifted = await tester.startGesture(tester.getCenter(strip));
    for (var i = 0; i < 20; i++) {
      await lifted.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '07-superset-lifted', settle: false);
    await lifted.cancel();
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await shot(tester, '08-superset-scrolled');

    await tester.pumpWidget(const SizedBox());
    await open(Brightness.dark);
    await shot(tester, '09-superset-dark');
  }, skip: out == null);
}

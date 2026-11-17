import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/main.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

final class FakeAlarm implements RestAlarm {
  final List<Rest?> shown = [];

  @override
  void show(Rest? rest) => shown.add(rest);
}

final today = Day.of(DateTime.now());

Day daysAgo(int n) {
  final now = DateTime.now();
  return Day.of(DateTime(now.year, now.month, now.day - n));
}

SetEntry kg(num weight, int reps, {bool done = false}) => SetEntry(grams: (weight * 1000).round(), reps: reps, status: done ? Done(DateTime.now().subtract(const Duration(hours: 1))) : const Planned());

List<SetEntry> sets(int n, num weight, int reps, {bool done = false}) => [for (var i = 0; i < n; i++) kg(weight, reps, done: done)];

final panel = find.byKey(const ValueKey('panel'));

Finder inPanel(Finder finder) => find.descendant(of: panel, matching: finder);

Finder card(String name, {bool skipOffstage = true}) => find.ancestor(of: find.text(name, skipOffstage: skipOffstage), matching: find.byType(Card, skipOffstage: skipOffstage));

Finder handle(String label) => find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == 'Drag to reorder $label', skipOffstage: false);

/// Exercise names in the order their cards stand on screen.
List<String> cardOrder(WidgetTester tester, List<String> names) => [...names]..sort((a, b) => tester.getTopLeft(card(a, skipOffstage: false)).dy.compareTo(tester.getTopLeft(card(b, skipOffstage: false)).dy));

void main() {
  late Store store;
  late FakeAlarm alarm;
  late Exercise squat;
  late Exercise bench;
  late Exercise row;

  setUp(() {
    store = Store.inMemory();
    addTearDown(store.close);
    alarm = FakeAlarm();
    squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    bench = store.createExercise(name: 'Bench press', kind: ExerciseKind.weightReps);
    row = store.createExercise(name: 'Row', kind: ExerciseKind.weightReps);
  });

  Future<void> openToday(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: setlistTheme(Brightness.light), home: WorkoutScreen(store: store, home: Home(day: today, alarm: alarm, restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)), day: today)));
  }

  List<SetEntry> savedSets(Exercise e) => store.loadDay(today).slotOf(e.id)!.sets;

  List<List<String>> savedLayout() => [
    for (final entry in store.loadDay(today).entries) [for (final slot in entry.slots) slot.exercise.name],
  ];

  testWidgets('one plus tap on set 1 turns a copied 3 x 5 at 100 kg into 3 x 5 at 102.5 kg', (tester) async {
    store.saveDay(Workout(day: daysAgo(3), entries: [Slot(squat, sets(3, 100, 5, done: true))]));
    await openToday(tester);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('100 kg × 5'), findsNWidgets(3));

    await tester.tap(inPanel(find.byTooltip('Increase weight')));
    await tester.pump();
    expect(find.text('102.5 kg × 5'), findsNWidgets(3));
    expect(find.text('100 kg × 5'), findsNothing);
    expect([for (final s in savedSets(squat)) s.grams], [102500, 102500, 102500]);
  });

  testWidgets('a typed value commits once, on OK', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, [kg(100, 5), kg(100, 5), kg(1, 5)])]));
    await openToday(tester);
    await tester.tap(inPanel(find.text('100 kg')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '110');
    await tester.pump();
    expect(find.text('100 kg × 5'), findsNWidgets(2));

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect([for (final s in savedSets(squat)) s.grams], [110000, 110000, 1000]);
    expect(find.text('110 kg × 5'), findsNWidgets(2));
  });

  testWidgets('logging the last set of an exercise moves the panel to the next exercise with no dialog', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, [kg(100, 5, done: true), kg(100, 5)]), Slot(bench, sets(2, 80, 8))]));
    await openToday(tester);
    expect(inPanel(find.text('Squat')), findsOneWidget);
    expect(inPanel(find.text('Set 2 of 2')), findsOneWidget);

    await tester.tap(inPanel(find.text('Log set')));
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);
    expect(inPanel(find.text('Bench press')), findsOneWidget);
    expect(inPanel(find.text('Set 1 of 2')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(savedSets(squat).every((s) => s.isDone), isTrue);
  });

  testWidgets('a finished card collapses to its summary and a tap on its header opens it again', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, [kg(100, 5, done: true), kg(100, 5)]), Slot(bench, sets(2, 80, 8))]));
    await openToday(tester);
    expect(find.text('100 kg × 5'), findsNWidgets(2));

    await tester.tap(inPanel(find.text('Log set')));
    await tester.pumpAndSettle();
    expect(find.text('100 kg × 5'), findsNothing);
    expect(find.text('2 sets · top 100 × 5'), findsOneWidget);

    await tester.tap(find.text('Squat'));
    await tester.pumpAndSettle();
    expect(find.text('100 kg × 5'), findsNWidgets(2));
    expect(inPanel(find.text('Bench press')), findsOneWidget);
  });

  testWidgets('Undo after logging restores the set and ends the rest', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(2, 100, 5))]));
    await openToday(tester);
    await tester.tap(inPanel(find.text('Log set')));
    await tester.pumpAndSettle();
    expect(savedSets(squat).first.isDone, isTrue);
    expect(inPanel(find.text('Set 2 of 2')), findsOneWidget);
    expect(inPanel(find.textContaining('Rest ')), findsOneWidget);
    expect(alarm.shown.last, isNotNull);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(savedSets(squat).first.isPlanned, isTrue);
    expect(inPanel(find.text('Set 1 of 2')), findsOneWidget);
    expect(find.byTooltip('Log set 1'), findsOneWidget);
    expect(inPanel(find.textContaining('Rest ')), findsNothing);
    expect(alarm.shown.last, isNull);
  });

  /// Opens yesterday over the home and logs its first set there, which offers Undo.
  Future<Day> logOnYesterday(WidgetTester tester) async {
    final past = daysAgo(1);
    store.saveDay(Workout(day: past, entries: [Slot(squat, sets(2, 100, 5))]));
    await openToday(tester);
    final home = tester.widget<WorkoutScreen>(find.byType(WorkoutScreen)).home;
    tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute<void>(builder: (_) => WorkoutScreen(store: store, home: home, day: past)));
    await tester.pumpAndSettle();
    await tester.tap(inPanel(find.text('Log set')));
    await tester.pumpAndSettle();
    expect(find.text('Set logged'), findsOneWidget);
    return past;
  }

  testWidgets('leaving a past day takes its Undo snackbar with it', (tester) async {
    final past = await logOnYesterday(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(WorkoutScreen, skipOffstage: false), findsOneWidget);
    expect(find.text('Set logged'), findsNothing);
    expect(store.loadDay(past).slotOf(squat.id)!.sets.first.isDone, isTrue);
  });

  testWidgets('a tap on Undo while it leaves with its past day changes nothing', (tester) async {
    final past = await logOnYesterday(tester);
    await tester.pageBack();
    for (var i = 0; i < 100 && find.byType(WorkoutScreen, skipOffstage: false).evaluate().length > 1; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(WorkoutScreen, skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.loadDay(past).slotOf(squat.id)!.sets.first.isDone, isTrue);
  });

  testWidgets('dragging a card by its handle moves it in one gesture', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(3, 100, 5)), Slot(bench, sets(3, 80, 8)), Slot(row, sets(3, 60, 10))]));
    await openToday(tester);
    final names = ['Squat', 'Bench press', 'Row'];
    expect(cardOrder(tester, names), names);

    await tester.ensureVisible(handle('Row'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(handle('Row')));
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(cardOrder(tester, names), ['Row', 'Squat', 'Bench press']);
    expect([for (final s in store.loadDay(today).slots) s.exercise.name], ['Row', 'Squat', 'Bench press']);
  });

  testWidgets('an empty day offers the five most recent workouts, and Copy fills the day', (tester) async {
    for (var n = 1; n <= 6; n++) {
      final e = store.createExercise(name: 'Lift $n', kind: ExerciseKind.weightReps);
      store.saveDay(Workout(day: daysAgo(n), entries: [Slot(e, sets(2, 50 + n, 5, done: true))]));
    }
    await openToday(tester);
    expect(find.text('Copy'), findsNWidgets(5));
    expect(find.text('Lift 6'), findsNothing);
    expect(find.text('Add exercise'), findsOneWidget);

    await tester.tap(find.text('Copy').first);
    await tester.pumpAndSettle();
    expect(card('Lift 1'), findsOneWidget);
    expect(find.text('51 kg × 5'), findsNWidgets(2));
    expect(find.text('Workout copied'), findsOneWidget);
    expect(store.loadDay(today).slots.single.sets, sets(2, 51, 5));
  });

  testWidgets('tapping a row moves the panel to that set', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(3, 100, 5)), Slot(bench, [kg(80, 8), kg(85, 6)])]));
    await openToday(tester);
    expect(inPanel(find.text('Squat')), findsOneWidget);

    await tester.tap(find.text('85 kg × 6'));
    await tester.pump();
    expect(inPanel(find.text('Bench press')), findsOneWidget);
    expect(inPanel(find.text('Set 2 of 2')), findsOneWidget);
    expect(inPanel(find.text('85 kg')), findsOneWidget);
    expect(inPanel(find.text('6 reps')), findsOneWidget);
  });

  testWidgets('when the focus moves to an exercise off the screen, its card scrolls into view', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(5, 100, 5)), Slot(bench, sets(5, 80, 8)), Slot(row, sets(1, 60, 10))]));
    await openToday(tester);
    await tester.ensureVisible(find.text('60 kg × 10', skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 kg × 10'));
    await tester.pump();
    expect(inPanel(find.text('Row')), findsOneWidget);
    expect(find.text('100 kg × 5'), findsNothing);

    await tester.tap(inPanel(find.text('Log set')));
    await tester.pumpAndSettle();
    expect(inPanel(find.text('Squat')), findsOneWidget);
    expect(inPanel(find.text('Set 1 of 5')), findsOneWidget);
    expect(find.text('100 kg × 5'), findsNWidgets(5));
  });

  testWidgets('the picker adds an exercise with planned sets from its last session, and creates a new one', (tester) async {
    final deadlift = store.createExercise(name: 'Deadlift', kind: ExerciseKind.weightReps);
    store.saveDay(Workout(day: daysAgo(2), entries: [Slot(deadlift, [kg(140, 5, done: true), kg(140, 5, done: true), kg(150, 3, done: true)])]));
    await openToday(tester);

    await tester.tap(find.text('Add exercise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dead');
    await tester.pump();
    expect(find.text('Squat'), findsNothing);
    await tester.tap(find.text('Deadlift'));
    await tester.pumpAndSettle();
    expect(find.text('140 kg × 5'), findsNWidgets(2));
    expect(find.text('150 kg × 3'), findsOneWidget);
    expect(savedSets(deadlift), [kg(140, 5), kg(140, 5), kg(150, 3)]);

    await tester.ensureVisible(find.text('Add exercise'));
    await tester.tap(find.text('Add exercise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Farmer carry');
    await tester.pump();
    await tester.tap(find.text('Create "Farmer carry"'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(card('Farmer carry'), findsOneWidget);
    expect([for (final e in store.exercises()) e.name], contains('Farmer carry'));
    final day = store.loadDay(today);
    expect([for (final s in day.slots) s.exercise.name], ['Deadlift', 'Farmer carry']);
    expect(day.slots.last.sets, [const SetEntry()]);
  });

  testWidgets('creating an exercise under a taken name keeps the dialog open with the error', (tester) async {
    await openToday(tester);
    await tester.tap(find.text('Add exercise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Curl');
    await tester.pump();
    await tester.tap(find.text('Create "Curl"'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'squat');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.text('An exercise with this name exists'), findsOneWidget);
  });

  Future<void> openEdit(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.byTooltip('More for $name'));
    await tester.tap(find.byTooltip('More for $name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit exercise'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseEquipment(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<Equipment>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Equipment storedEquipment(Exercise e) => store.exercises().singleWhere((x) => x.id == e.id).equipment;

  testWidgets('creating an exercise offers equipment for a kind with a weight and stores the choice', (tester) async {
    await openToday(tester);
    await tester.tap(find.text('Add exercise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hammer curl');
    await tester.pump();
    await tester.tap(find.text('Create "Hammer curl"'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(DropdownButtonFormField<Equipment>, 'None'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bar weight'), findsNothing);
    await chooseEquipment(tester, 'Two dumbbells');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(store.exercises().singleWhere((e) => e.name == 'Hammer curl').equipment, Equipment.dumbbellPair);
  });

  testWidgets('editing an exercise sets a barbell with its bar weight, and a later edit of only the name keeps it', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(1, 60, 5))]));
    await openToday(tester);
    await openEdit(tester, 'Squat');
    await chooseEquipment(tester, 'Barbell');
    final bar = find.widgetWithText(TextField, 'Bar weight');
    expect(tester.widget<TextField>(bar).controller!.text, '20');
    await tester.enterText(bar, '15');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(storedEquipment(squat), const Barbell(15000));

    await openEdit(tester, 'Squat');
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Bar weight')).controller!.text, '15');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Back squat');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(storedEquipment(squat), const Barbell(15000));
    expect(store.loadDay(today).slots.single.exercise.equipment, const Barbell(15000));
  });

  testWidgets('a bar weight of 0 or not a number keeps the dialog open with the error', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(1, 60, 5))]));
    await openToday(tester);
    await openEdit(tester, 'Squat');
    await chooseEquipment(tester, 'Barbell');
    for (final typed in ['0', 'abc']) {
      await tester.enterText(find.widgetWithText(TextField, 'Bar weight'), typed);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Type a bar weight above 0, such as 20'), findsOneWidget, reason: typed);
      expect(find.text('Edit exercise'), findsOneWidget, reason: typed);
    }
    expect(storedEquipment(squat), Equipment.none);
  });

  testWidgets('history returns to the home screen for today, and its Copy fills today there', (tester) async {
    store.saveDay(Workout(day: daysAgo(2), entries: [Slot(squat, sets(3, 100, 5, done: true))]));
    store.saveDay(Workout(day: today, entries: [Slot(bench, sets(2, 80, 8))]));
    await openToday(tester);

    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkoutScreen), findsOneWidget);
    expect(find.text('History'), findsNothing);

    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy to today'));
    await tester.pumpAndSettle();
    expect(find.text('History'), findsNothing);
    expect(card('Squat'), findsOneWidget);
    expect([for (final s in store.loadDay(today).slots) s.exercise.name], ['Bench press', 'Squat']);
  });

  testWidgets('exercise history shows each session with its estimated max and marks a new best', (tester) async {
    store.saveDay(Workout(day: daysAgo(3), entries: [Slot(squat, [kg(100, 5, done: true)])]));
    store.saveDay(Workout(day: daysAgo(2), entries: [Slot(squat, [kg(100, 3, done: true)])]));
    store.saveDay(Workout(day: daysAgo(1), entries: [Slot(squat, [kg(105, 5, done: true)])]));
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(1, 105, 5))]));
    await openToday(tester);

    await tester.tap(find.byTooltip('More for Squat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('e1RM 112.5 kg'), findsOneWidget);
    expect(find.text('e1RM 105.9 kg'), findsOneWidget);
    expect(find.text('e1RM 118.1 kg'), findsOneWidget);
    expect(find.text('New best'), findsOneWidget);
    expect(tester.getTopLeft(find.text('New best')).dy, lessThan(tester.getTopLeft(find.text('e1RM 105.9 kg')).dy));
  });

  testWidgets('a superset draws its cards inside one frame under a Superset strip, inset from plain cards', (tester) async {
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(1, 100, 5)), Superset([Slot(bench, sets(1, 80, 8)), Slot(row, sets(1, 60, 10))])]));
    await openToday(tester);
    expect(find.text('Superset'), findsOneWidget);
    expect(handle('superset Bench press + Row'), findsOneWidget);

    final squatCard = tester.getRect(card('Squat'));
    final benchCard = tester.getRect(card('Bench press'));
    final rowCard = tester.getRect(card('Row'));
    expect(tester.getRect(find.text('Superset')).bottom, lessThan(benchCard.top));
    expect(benchCard.bottom, lessThanOrEqualTo(rowCard.top));
    expect(benchCard.left, greaterThan(squatCard.left));
    expect(benchCard.right, lessThan(squatCard.right));
    for (final name in ['Bench press', 'Row']) {
      expect(find.descendant(of: card(name), matching: find.text('Add set')), findsOneWidget);
      expect(find.byTooltip('More for $name'), findsOneWidget);
      expect(handle(name), findsOneWidget);
    }
  });

  /// Picks up the row at [handle], then moves it by [dy] in small steps and lets go. [dy] is asked for once the row floats, so it measures from the floating copy and reads the list as the drag left it.
  Future<void> drag(WidgetTester tester, Finder handle, double Function() dy, {void Function()? whileHeld}) async {
    await tester.ensureVisible(handle);
    await tester.pumpAndSettle();
    final direction = dy().sign;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(Offset(0, 8 * direction));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final total = dy();
    final steps = (total.abs() / 10).ceil();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, total / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    whileHeld?.call();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('dragging a card by its handle into a superset frame, within it and out of it regroups the day', (tester) async {
    final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(1, 100, 5, done: true)), Superset([Slot(bench, sets(1, 80, 8, done: true)), Slot(row, sets(1, 60, 10, done: true))]), Slot(curl, sets(1, 20, 12))]));
    await openToday(tester);
    Rect at(String name) => tester.getRect(card(name, skipOffstage: false));

    await drag(tester, handle('Squat'), () => (at('Bench press').bottom + at('Row').top) / 2 - at('Squat').bottom);
    expect(savedLayout(), [['Bench press', 'Squat', 'Row'], ['Curl']]);
    expect(cardOrder(tester, ['Squat', 'Bench press', 'Row', 'Curl']), ['Bench press', 'Squat', 'Row', 'Curl']);
    expect(at('Squat').left, at('Bench press').left, reason: 'the dropped card is framed like the others');

    await drag(tester, handle('Row'), () => at('Bench press').top - at('Row').top);
    expect(savedLayout(), [['Row', 'Bench press', 'Squat'], ['Curl']]);

    await drag(tester, handle('Squat'), () => at('Curl').top - at('Squat').bottom);
    expect(savedLayout(), [['Row', 'Bench press'], ['Squat'], ['Curl']]);
    expect(at('Squat').left, at('Curl').left, reason: 'the card left the frame');
    expect(find.text('Superset'), findsOneWidget);

    final below = at('Squat').top;
    await drag(tester, handle('Squat'), () => below - 40 - at('Squat').top);
    expect(savedLayout(), [['Row', 'Bench press', 'Squat'], ['Curl']], reason: 'a collapsed card right below the frame, lifted 40 dp, joins its end');
  });

  testWidgets('dragging the Superset strip moves the whole superset, folded into the strip while it floats', (tester) async {
    final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
    final press = store.createExercise(name: 'Press', kind: ExerciseKind.weightReps);
    store.saveDay(Workout(day: today, entries: [Superset([Slot(bench, sets(1, 80, 8, done: true)), Slot(row, sets(1, 60, 10, done: true))]), Slot(press, sets(1, 40, 8, done: true)), Superset([Slot(squat, sets(1, 100, 5, done: true)), Slot(curl, sets(1, 20, 12))])]));
    await openToday(tester);
    Rect at(String name) => tester.getRect(card(name, skipOffstage: false));
    final strip = handle('superset Bench press + Row');

    Rect stripRect() => tester.getRect(find.ancestor(of: strip, matching: find.byType(Material)).first);

    await drag(
      tester,
      strip,
      () => (at('Squat').bottom + at('Curl').top) / 2 - stripRect().bottom,
      whileHeld: () {
        expect(card('Bench press', skipOffstage: false), findsNothing);
        expect(card('Row', skipOffstage: false), findsNothing);
        expect(find.text('Bench press + Row'), findsOneWidget);
      },
    );
    expect(savedLayout(), [['Press'], ['Bench press', 'Row'], ['Squat', 'Curl']], reason: 'dropped inside another superset, it lands right above that one');
    expect(cardOrder(tester, ['Press', 'Bench press', 'Row', 'Squat', 'Curl']), ['Press', 'Bench press', 'Row', 'Squat', 'Curl']);
    expect(find.text('Bench press + Row'), findsNothing);

    await drag(tester, strip, () => at('Press').top - (stripRect().top - 8));
    expect(savedLayout(), [['Bench press', 'Row'], ['Press'], ['Squat', 'Curl']]);

    final interrupted = await tester.startGesture(tester.getCenter(strip));
    for (var i = 0; i < 10; i++) {
      await interrupted.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(card('Bench press', skipOffstage: false), findsNothing);
    await interrupted.cancel();
    await tester.pumpAndSettle();
    expect(cardOrder(tester, ['Bench press', 'Row', 'Press']), ['Bench press', 'Row', 'Press'], reason: 'a cancelled drag opens the superset again where it was');
    expect(savedLayout(), [['Bench press', 'Row'], ['Press'], ['Squat', 'Curl']]);
  });

  testWidgets("Superset with… offers only the exercises outside the card's superset and joins the pick to it", (tester) async {
    final curl = store.createExercise(name: 'Curl', kind: ExerciseKind.weightReps);
    store.saveDay(Workout(day: today, entries: [Slot(squat, sets(1, 100, 5, done: true)), Superset([Slot(bench, sets(1, 80, 8, done: true)), Slot(row, sets(1, 60, 10, done: true))]), Slot(curl, sets(1, 20, 12, done: true))]));
    await openToday(tester);
    Future<void> openMenu(String name) async {
      await tester.ensureVisible(find.byTooltip('More for $name'));
      await tester.tap(find.byTooltip('More for $name'));
      await tester.pumpAndSettle();
    }

    final sheet = find.byType(BottomSheet);
    List<String> offered() => [for (final tile in tester.widgetList<ListTile>(find.descendant(of: sheet, matching: find.byType(ListTile)))) (tile.title! as Text).data!];

    await openMenu('Squat');
    await tester.tap(find.text('Superset with…'));
    await tester.pumpAndSettle();
    expect(offered(), ['Bench press', 'Row', 'Curl']);
    expect(find.descendant(of: sheet, matching: find.text('Bench press + Row')), findsNWidgets(2));
    await tester.tap(find.descendant(of: sheet, matching: find.text('Curl')));
    await tester.pumpAndSettle();
    expect(savedLayout(), [['Squat', 'Curl'], ['Bench press', 'Row']]);
    expect(find.text('Superset'), findsNWidgets(2));

    await openMenu('Bench press');
    await tester.tap(find.text('Superset with…'));
    await tester.pumpAndSettle();
    expect(offered(), ['Squat', 'Curl']);
    await tester.tap(find.descendant(of: sheet, matching: find.text('Squat')));
    await tester.pumpAndSettle();
    expect(savedLayout(), [['Curl'], ['Bench press', 'Squat', 'Row']], reason: 'the pick left its pair, and the one left is plain');

    await openMenu('Curl');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await openMenu('Bench press');
    expect(find.text('Edit exercise'), findsOneWidget);
    expect(find.text('Superset with…'), findsNothing, reason: 'every exercise of the day is already in this superset');
  });

  testWidgets('logging through the panel alternates a superset, names where it goes next, and rests only after each round', (tester) async {
    store.saveDay(Workout(day: today, entries: [Superset([Slot(bench, sets(2, 80, 8)), Slot(row, sets(2, 60, 10))]), Slot(squat, sets(1, 100, 5))]));
    await openToday(tester);
    final rest = inPanel(find.textContaining('Rest '));
    Future<void> logSet() async {
      await tester.tap(inPanel(find.text('Log set')));
      await tester.pumpAndSettle();
    }

    void expectPanel(String exercise, String line) {
      expect(inPanel(find.text(exercise)), findsOneWidget);
      expect(inPanel(find.text(line)), findsOneWidget);
    }

    expectPanel('Bench press', 'Set 1 of 2 · then Row');
    await logSet();
    expectPanel('Row', 'Set 1 of 2 · then Bench press');
    expect(rest, findsNothing, reason: 'the round is not over');
    expect(alarm.shown.last, isNull);

    await logSet();
    expectPanel('Bench press', 'Set 2 of 2 · then Row');
    expect(rest, findsOneWidget);
    expect(alarm.shown.last, isNotNull);

    await logSet();
    expectPanel('Row', 'Set 2 of 2');
    expect(rest, findsNothing);

    await logSet();
    expectPanel('Squat', 'Set 1 of 1');
    expect(rest, findsOneWidget);
    expect(savedSets(bench).every((s) => s.isDone) && savedSets(row).every((s) => s.isDone), isTrue);
  });

  testWidgets('a past superset day shows its names joined with a plus, and copying it keeps the superset', (tester) async {
    store.saveDay(Workout(day: daysAgo(2), entries: [Superset([Slot(bench, sets(1, 80, 8, done: true)), Slot(row, sets(1, 60, 10, done: true))]), Slot(squat, sets(1, 100, 5, done: true))]));
    await openToday(tester);
    expect(find.text('Bench press + Row, Squat'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('Superset'), findsOneWidget);
    expect(savedLayout(), [['Bench press', 'Row'], ['Squat']]);
  });
}


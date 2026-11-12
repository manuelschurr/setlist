import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/history_screen.dart';
import 'package:setlist/main.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

final class FakeAlarm implements RestAlarm {
  @override
  void show(Rest? rest) {}
}

void main() {
  testWidgets('restoring a backup swaps the database and starts the app over on today, and a file that is no backup changes nothing', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_app_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final today = Day.of(DateTime.now());
    final source = Store.open('${dir.path}/source.sqlite');
    final squat = source.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    source.saveDay(Workout(day: today, slots: [Slot(squat, const [SetEntry(grams: 100000, reps: 5)])]));
    source.copyTo('${dir.path}/backup.sqlite');
    source.close();

    await tester.pumpWidget(SetlistApp(dbPath: '${dir.path}/setlist.sqlite', alarm: FakeAlarm()));
    expect(find.text('Add exercise'), findsOneWidget);
    expect(find.text('Squat'), findsNothing);

    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
    tester.widget<WorkoutScreen>(find.byType(WorkoutScreen, skipOffstage: false)).home.restore('${dir.path}/backup.sqlite');
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsNothing);
    expect(find.text('Backup restored'), findsOneWidget);
    expect(find.text('100 kg × 5'), findsOneWidget);

    final junk = File('${dir.path}/junk.sqlite')..writeAsStringSync('not a database');
    tester.widget<WorkoutScreen>(find.byType(WorkoutScreen)).home.restore(junk.path);
    await tester.pumpAndSettle();
    expect(find.textContaining('not a Setlist backup'), findsOneWidget);
    expect(find.text('100 kg × 5'), findsOneWidget);
  });
}

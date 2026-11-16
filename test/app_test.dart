import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/history_screen.dart';
import 'package:setlist/main.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

import 'drive_backup_test.dart' show FakeProvider, nextMillisecond;

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
    source.saveDay(Workout(day: today, entries: [Slot(squat, const [SetEntry(grams: 100000, reps: 5)])]));
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

  testWidgets('a resume on a later day moves the home to today, unless a set was logged in the last 3 hours', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_app_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final evening = Day.parse('2026-03-10');
    final seed = Store.open('${dir.path}/setlist.sqlite');
    final squat = seed.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    seed.saveDay(Workout(day: evening, entries: [Slot(squat, [SetEntry(grams: 100000, reps: 5, status: Done(DateTime(2026, 3, 10, 23, 30))), const SetEntry(grams: 100000, reps: 5)])]));
    seed.close();
    var now = DateTime(2026, 3, 10, 23, 40);
    Future<void> resumeAt(DateTime time) async {
      now = time;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(SetlistApp(dbPath: '${dir.path}/setlist.sqlite', alarm: FakeAlarm(), clock: () => now));
    expect(tester.widget<WorkoutScreen>(find.byType(WorkoutScreen)).day, evening);

    await resumeAt(DateTime(2026, 3, 11, 0, 45));
    expect(tester.widget<WorkoutScreen>(find.byType(WorkoutScreen)).day, evening);
    expect(find.text('100 kg × 5'), findsNWidgets(2));

    await resumeAt(DateTime(2026, 3, 11, 7));
    expect(tester.widget<WorkoutScreen>(find.byType(WorkoutScreen)).day, Day.parse('2026-03-11'));
    expect(find.text('100 kg × 5'), findsNothing);
    expect(find.text('Add exercise'), findsOneWidget);
  });

  testWidgets('leaving the app backs up a changed database to this week\'s file on the app clock, and an unchanged one not again', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_app_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final provider = FakeProvider();
    addTearDown(provider.dispose);
    final path = '${dir.path}/setlist.sqlite';
    DateTime clock() => DateTime(2026, 3, 11, 18);
    final today = Day.of(clock());
    final seed = Store.open(path);
    final squat = seed.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    seed.saveDay(Workout(day: today, entries: [Slot(squat, const [SetEntry(grams: 100000, reps: 5)])]));
    nextMillisecond();
    final linking = DriveBackup(dbPath: path, store: () => seed, weekClock: clock);
    await linking.linkFolder();
    seed.close();
    final uri = (linking.link! as FolderLink).latest!.doc.uri;
    nextMillisecond();

    await tester.pumpWidget(SetlistApp(dbPath: path, alarm: FakeAlarm(), clock: clock));
    Future<void> leaveAndReturn() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byTooltip('Log set 1'));
    await tester.pumpAndSettle();
    nextMillisecond();
    await leaveAndReturn();
    expect(provider.writtenTo, [uri]);
    expect(provider.created, hasLength(1));
    expect(provider.setsIn(uri, today).single.isDone, isTrue);

    nextMillisecond();
    await leaveAndReturn();
    expect(provider.writtenTo, [uri]);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/drive_backup_screen.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

import 'drive_backup_test.dart' show FakeProvider;

final class FakeAlarm implements RestAlarm {
  @override
  void show(Rest? rest) {}
}

void main() {
  testWidgets('the Drive backup screen links a file, shows its last backup or error, restores from it after confirming, and stops', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_drive_screen_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/setlist.sqlite');
    addTearDown(store.close);
    final provider = FakeProvider();
    addTearDown(provider.dispose);
    final today = Day.of(DateTime.now());
    final squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    store.saveDay(Workout(day: today, entries: [Slot(squat, const [SetEntry(grams: 100000, reps: 5)])]));
    final backup = DriveBackup(dbPath: store.path!, store: () => store);
    Uint8List? restored;
    final home = Home(day: today, alarm: FakeAlarm(), restore: (path) => restored = File(path).readAsBytesSync(), backup: backup);
    await tester.pumpWidget(MaterialApp(home: DriveBackupScreen(home: home)));

    await tester.tap(find.text('Choose backup file'));
    await tester.pumpAndSettle();
    expect(find.text(DriveBackup.suggestedName), findsOneWidget);
    expect(find.text('Last backup: Today at ${_clock(backup.link!.lastSuccess!)}'), findsOneWidget);

    provider.refuse = PlatformException(code: 'denied');
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed: Today at'), findsOneWidget);
    provider.refuse = null;

    await tester.tap(find.text('Restore from this backup'));
    await tester.pumpAndSettle();
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(restored, isNull);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(restored, provider.files[backup.link!.uri]);
    expect(File('${store.path}.drive-restore').existsSync(), isFalse);

    await tester.tap(find.text('Stop backing up'));
    await tester.pumpAndSettle();
    expect(find.text('Choose backup file'), findsOneWidget);
    expect(provider.released, hasLength(1));
  });
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

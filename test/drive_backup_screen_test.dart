import 'dart:convert';
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
  late Store store;
  late FakeProvider provider;
  late DriveBackup backup;
  Uint8List? restored;

  Future<void> openScreen(WidgetTester tester) async {
    backup = DriveBackup(dbPath: store.path!, store: () => store, weekClock: () => DateTime(2026, 11, 11, 18));
    final home = Home(day: Day.of(DateTime.now()), alarm: FakeAlarm(), restore: (path) => restored = File(path).readAsBytesSync(), backup: backup);
    await tester.pumpWidget(MaterialApp(home: DriveBackupScreen(home: home)));
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> expectSaid(WidgetTester tester, String message) async {
    expect(find.text(message), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(DriveBackupScreen))).removeCurrentSnackBar();
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>())).enabled;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('setlist_drive_screen_');
    addTearDown(() => dir.deleteSync(recursive: true));
    store = Store.open('${dir.path}/setlist.sqlite');
    addTearDown(store.close);
    provider = FakeProvider();
    addTearDown(provider.dispose);
    restored = null;
    final squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    store.saveDay(Workout(day: Day.of(DateTime.now()), entries: [Slot(squat, const [SetEntry(grams: 100000, reps: 5)])]));
  });

  testWidgets('the screen links a folder, shows its latest backup or error, restores the latest or an earlier week after confirming, and stops', (tester) async {
    await openScreen(tester);
    expect(find.textContaining('Setlist keeps one backup file per week'), findsOneWidget);
    expect(find.textContaining('My Drive itself'), findsOneWidget);

    await tap(tester, 'Choose backup folder');
    await expectSaid(tester, 'Backing up to Setlist backups.');
    expect(find.text('Setlist backups'), findsOneWidget);
    expect(find.text('Last backup: Today at ${_clock(backup.link!.lastSuccess!)}'), findsOneWidget);
    expect(find.text('In Setlist week of 2026-11-09.sqlite'), findsOneWidget);
    expect(find.textContaining('Setlist never changes or deletes an earlier week'), findsOneWidget);
    for (final label in ['Back up now', 'Restore latest backup', 'Restore an earlier week', 'Change folder', 'Stop backing up']) {
      expect(enabled(tester, label), isTrue, reason: label);
    }
    expect(find.text('Restore from this backup'), findsNothing);

    provider.refuse = PlatformException(code: 'denied');
    await tap(tester, 'Back up now');
    expect(find.textContaining('Failed: Today at'), findsOneWidget);
    expect(find.textContaining('Choose it again with Change folder'), findsOneWidget);
    provider.refuse = null;

    await tap(tester, 'Restore latest backup');
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(restored, isNull);
    await tap(tester, 'Restore');
    expect(restored, provider.files[(backup.link! as FolderLink).latest!.doc.uri]);
    expect(File('${store.path}.drive-restore').existsSync(), isFalse);

    provider.pickNext = Uint8List.fromList([7, 7, 7]);
    await tap(tester, 'Restore an earlier week');
    expect(provider.nearSeen.last, FakeProvider.backups.uri);
    await tap(tester, 'Restore');
    expect(restored, [7, 7, 7]);
    expect(File('${store.path}.drive-restore').existsSync(), isFalse);

    await tap(tester, 'Stop backing up');
    await expectSaid(tester, 'Backups stopped. The backup files stay in Drive.');
    expect(find.text('Choose backup folder'), findsOneWidget);
    expect(provider.released, [FakeProvider.backups.uri]);
  });

  testWidgets('Restore latest backup stays off until a backup reached the folder', (tester) async {
    provider.failCopy = true;
    await openScreen(tester);
    await tap(tester, 'Choose backup folder');
    await expectSaid(tester, 'Backing up to Setlist backups.');
    expect(find.text('No backup yet'), findsOneWidget);
    expect(find.textContaining('Drive could not be reached'), findsOneWidget);
    expect(enabled(tester, 'Restore latest backup'), isFalse);
    expect(enabled(tester, 'Restore an earlier week'), isTrue);

    provider.failCopy = false;
    await tap(tester, 'Back up now');
    await expectSaid(tester, 'Backed up');
    expect(enabled(tester, 'Restore latest backup'), isTrue);
  });

  testWidgets('a phone upgraded from 0.2 is asked to choose a folder while its backups keep going to its file', (tester) async {
    const oldFile = 'content://com.google.android.apps.docs.storage/document/acc%3D1%3Bdoc%3Dold';
    File('${store.path}.drive-backup.json').writeAsStringSync(jsonEncode({'uri': oldFile, 'name': 'Setlist backup.sqlite', 'lastSuccessMs': DateTime.now().millisecondsSinceEpoch}));
    await openScreen(tester);
    expect(find.text('Back up into a folder'), findsOneWidget);
    expect(find.textContaining('Until you choose a folder, backups keep going to Setlist backup.sqlite.'), findsOneWidget);
    expect(find.text('Setlist backup.sqlite'), findsOneWidget);
    for (final label in ['Choose backup folder', 'Back up now', 'Restore from this backup', 'Stop backing up']) {
      expect(enabled(tester, label), isTrue, reason: label);
    }
    expect(find.text('Change folder'), findsNothing);
    expect(find.text('Restore an earlier week'), findsNothing);

    await tap(tester, 'Back up now');
    expect(provider.writtenTo, [oldFile]);

    await tap(tester, 'Choose backup folder');
    expect(find.text('Back up into a folder'), findsNothing);
    expect(find.text('Setlist backups'), findsOneWidget);
    expect(provider.released, [oldFile]);
  });
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

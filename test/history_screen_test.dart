import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/history_screen.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

import 'drive_backup_test.dart' show FakeProvider;
import 'fitnotes_test.dart' show trainingLogRows, writeFitNotes;

final class FakeAlarm implements RestAlarm {
  @override
  void show(Rest? rest) {}
}

/// What the Android picker hands back: a content URI with no file path, readable only as bytes.
final class ContentUriFile extends PlatformFile {
  ContentUriFile(this.bytes);

  final Uint8List bytes;

  @override
  String get name => 'FitNotes_Backup.fitnotes';

  @override
  Uri get uri => Uri.parse('content://com.android.providers.downloads.documents/document/42');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

final class FakePicker extends FilePickerPlatform {
  FakePicker(this.file);

  final PlatformFile file;

  /// Answers [saveFile] once the test completes it, so an export stays running until then.
  final saving = Completer<Uri?>();
  bool saveAsked = false;

  @override
  Future<Uri?> saveFile({required String fileName, required Uint8List bytes, required String mimeType, String? dialogTitle, String? initialDirectory, Function(FilePickerStatus)? onFileSaving, WindowsOptions windowsOptions = const WindowsOptions(), LinuxOptions linuxOptions = const LinuxOptions(), WebOptions webOptions = const WebOptions()}) {
    saveAsked = true;
    return saving.future;
  }

  @override
  Future<PlatformFile?> pickFile({String? dialogTitle, String? initialDirectory, FileType type = FileType.any, List<String>? allowedExtensions, Function(FilePickerStatus)? onFileLoading, int compressionQuality = 0, AndroidOptions androidOptions = const AndroidOptions(), DarwinOptions darwinOptions = const DarwinOptions(), WindowsOptions windowsOptions = const WindowsOptions(), LinuxOptions linuxOptions = const LinuxOptions(), WebOptions webOptions = const WebOptions()}) async => file;
}

void main() {
  testWidgets('importing a FitNotes backup from the data menu writes one set per training log row and says so', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_import_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final backup = '${dir.path}/backup.fitnotes';
    writeFitNotes(backup);
    FilePickerPlatform.instance = FakePicker(ContentUriFile(File(backup).readAsBytesSync()));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final store = Store.open('${dir.path}/setlist.sqlite');
    addTearDown(store.close);
    final today = Day.of(DateTime.now());
    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store, home: Home(day: today, alarm: FakeAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: store.path!, store: () => store)))));
    expect(find.text('No workouts yet'), findsOneWidget);

    await tester.tap(find.byTooltip('Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import FitNotes backup'));
    for (var i = 0; i < 200 && find.text('FitNotes import done').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.textContaining('$trainingLogRows of $trainingLogRows sets written'), findsOneWidget);
    expect(find.textContaining('Left out: '), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('No workouts yet'), findsNothing);
    expect(find.textContaining('Squat'), findsWidgets);
  });

  testWidgets('Back and the day rows do nothing while an export runs, and work again once it ends', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_busy_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final picker = FakePicker(ContentUriFile(Uint8List(0)));
    FilePickerPlatform.instance = picker;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    final store = Store.open('${dir.path}/setlist.sqlite');
    addTearDown(store.close);
    final today = Day.of(DateTime.now());
    store.saveDay(Workout(day: today, note: 'today'));
    final home = Home(day: today, alarm: FakeAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: store.path!, store: () => store));
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => HistoryScreen(store: store, home: home))), child: const Text('Open history'))),
    ));
    await tester.tap(find.text('Open history'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Setlist backup'));
    for (var i = 0; i < 200 && !picker.saveAsked; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(picker.saveAsked, isTrue);
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryScreen), findsOneWidget);
    await tester.tap(find.text('Today'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryScreen), findsOneWidget);

    picker.saving.complete(null);
    for (var i = 0; i < 200 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsNothing);
  });

  testWidgets('a day lists a superset\'s names joined with a plus and its entries with commas', (tester) async {
    final store = Store.inMemory();
    addTearDown(store.close);
    final bench = store.createExercise(name: 'Bench press', kind: ExerciseKind.weightReps);
    final row = store.createExercise(name: 'Row', kind: ExerciseKind.weightReps);
    final squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    final done = SetEntry(grams: 80000, reps: 5, status: Done(DateTime.now()));
    final today = Day.of(DateTime.now());
    final now = DateTime.now();
    store.saveDay(Workout(day: Day.of(DateTime(now.year, now.month, now.day - 2)), entries: [Slot(squat, [done]), Superset([Slot(bench, [done]), Slot(row, [done])])]));
    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store, home: Home(day: today, alarm: FakeAlarm(), restore: (_) {}, backup: DriveBackup(dbPath: '${Directory.systemTemp.path}/unlinked.sqlite', store: () => store)))));
    expect(find.text('Squat, Bench press + Row'), findsOneWidget);
  });

  testWidgets('restoring a Setlist backup from the data menu picks the file through the documents channel, restores it after confirming, and deletes the copy', (tester) async {
    final dir = Directory.systemTemp.createTempSync('setlist_restore_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final provider = FakeProvider();
    addTearDown(provider.dispose);
    final store = Store.open('${dir.path}/setlist.sqlite');
    addTearDown(store.close);
    Uint8List? restored;
    final home = Home(day: Day.of(DateTime.now()), alarm: FakeAlarm(), restore: (path) => restored = File(path).readAsBytesSync(), backup: DriveBackup(dbPath: store.path!, store: () => store));
    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store, home: home)));
    provider.pickNext = Uint8List.fromList([1, 2, 3]);

    await tester.tap(find.byTooltip('Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore Setlist backup'));
    await tester.pumpAndSettle();
    expect(provider.nearSeen, [null]);
    expect(find.text('Restore this backup?'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(restored, [1, 2, 3]);
    expect(File('${store.path}.drive-restore').existsSync(), isFalse);
  });
}


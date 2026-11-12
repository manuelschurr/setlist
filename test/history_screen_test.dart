import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/history_screen.dart';
import 'package:setlist/rest_alarm.dart';
import 'package:setlist/store.dart';
import 'package:setlist/workout_screen.dart';

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
    await tester.pumpWidget(MaterialApp(home: HistoryScreen(store: store, home: Home(day: today, alarm: FakeAlarm(), restore: (_) {}))));
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
}

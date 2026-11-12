import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/store.dart';

/// The Drive app's document provider as the Android side of `de.schurr.setlist/documents` presents it: files by URI, a picker that creates one, and permissions to release.
final class FakeProvider {
  FakeProvider() {
    _messenger.setMockMethodCallHandler(_channel, _handle);
  }

  static const _channel = MethodChannel('de.schurr.setlist/documents');
  static TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final files = <String, Uint8List>{};
  final writtenTo = <String>[];
  final released = <String>[];

  /// Every write fails with this while set, as when the lifter revoked the permission.
  PlatformException? refuse;

  /// While set, the picker stays open until it completes.
  Completer<void>? picking;

  void dispose() => _messenger.setMockMethodCallHandler(_channel, null);

  /// The sets of [day] in the file at [uri], read the way a restore would.
  List<SetEntry> setsIn(String uri, Day day) {
    final dir = Directory.systemTemp.createTempSync('setlist_drive_read_');
    try {
      final copy = File('${dir.path}/copy.sqlite')..writeAsBytesSync(files[uri]!);
      final store = Store.open(copy.path);
      try {
        return [for (final slot in store.loadDay(day).slots) ...slot.sets];
      } finally {
        store.close();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, String>();
    switch (call.method) {
      case 'create':
        await picking?.future;
        final uri = 'content://com.google.android.apps.docs.storage/document/${files.length + 1}';
        files[uri] = Uint8List(0);
        return {'uri': uri, 'name': args['name']};
      case 'write':
        writtenTo.add(args['uri']!);
        if (refuse case final e?) throw e;
        files[args['uri']!] = File(args['path']!).readAsBytesSync();
      case 'read':
        File(args['path']!).writeAsBytesSync(files[args['uri']!]!);
      case 'release':
        released.add(args['uri']!);
    }
    return null;
  }
}

/// File times and backup times carry milliseconds, and a write in the same millisecond as a backup counts as a change, so tests keep the two apart.
void nextMillisecond() => sleep(const Duration(milliseconds: 5));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = Day.of(DateTime.now());
  late String path;
  late Store store;
  late FakeProvider provider;
  late Exercise squat;

  void logSets(int count) => store.saveDay(Workout(day: today, slots: [Slot(squat, [for (var i = 0; i < count; i++) SetEntry(grams: 100000, reps: 5, status: Done(DateTime.now()))])]));
  DriveBackup open() => DriveBackup(dbPath: path, store: () => store);

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('setlist_drive_');
    addTearDown(() => dir.deleteSync(recursive: true));
    path = '${dir.path}/setlist.sqlite';
    store = Store.open(path);
    addTearDown(store.close);
    provider = FakeProvider();
    addTearDown(provider.dispose);
    squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    logSets(1);
    nextMillisecond();
  });

  test('does nothing while no file is linked', () async {
    final backup = open();
    await backup.backUpIfChanged();
    expect(backup.link, isNull);
    expect(provider.writtenTo, isEmpty);
  });

  test('linking backs up at once, and leaving the app backs up again only after the database changed', () async {
    final backup = open();
    expect(await backup.linkNewFile(), isTrue);
    final uri = backup.link!.uri;
    expect(backup.link!.name, DriveBackup.suggestedName);
    expect(provider.setsIn(uri, today), hasLength(1));
    final first = backup.link!.lastSuccess!;

    nextMillisecond();
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [uri]);

    logSets(2);
    nextMillisecond();
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [uri, uri]);
    expect(provider.setsIn(uri, today), hasLength(2));
    expect(backup.link!.lastSuccess!.isAfter(first), isTrue);

    nextMillisecond();
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [uri, uri]);
  });

  test('the link and its last backup survive a restart', () async {
    final before = open();
    await before.linkNewFile();
    nextMillisecond();

    final after = open();
    expect(after.link?.uri, before.link!.uri);
    expect(after.link?.lastSuccess, before.link!.lastSuccess);
    await after.backUpIfChanged();
    expect(provider.writtenTo, hasLength(1));
  });

  test('a revoked permission is recorded as an error that keeps the last backup, and the next backup retries and clears it', () async {
    final backup = open();
    await backup.linkNewFile();
    final uri = backup.link!.uri;
    final success = backup.link!.lastSuccess;
    provider.refuse = PlatformException(code: 'denied', message: 'java.lang.SecurityException: No persistable permission grants found');
    logSets(2);
    nextMillisecond();

    await backup.backUpIfChanged();
    expect(backup.link!.lastError?.message, contains('Change file'));
    expect(backup.link!.lastSuccess, success);
    expect(open().link!.lastError, isNotNull);
    expect(provider.setsIn(uri, today), hasLength(1));

    provider.refuse = null;
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [uri, uri, uri]);
    expect(backup.link!.lastError, isNull);
    expect(provider.setsIn(uri, today), hasLength(2));
  });

  test('stopping releases the permission, forgets the file, and backs up nothing more', () async {
    final backup = open();
    await backup.linkNewFile();
    final uri = backup.link!.uri;

    await backup.unlink();
    expect(provider.released, [uri]);
    expect(backup.link, isNull);
    expect(open().link, isNull);

    logSets(2);
    nextMillisecond();
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [uri]);
  });

  test('a backup asked for while the picker is open for a new file waits, and goes to the new file', () async {
    final backup = open();
    await backup.linkNewFile();
    final old = backup.link!.uri;
    logSets(2);
    nextMillisecond();

    provider.picking = Completer();
    final changing = backup.linkNewFile();
    final leaving = backup.backUpIfChanged();
    await pumpEventQueue();
    expect(provider.writtenTo, [old]);

    provider.picking!.complete();
    await changing;
    await leaving;
    final now = backup.link!.uri;
    expect(now, isNot(old));
    expect(provider.released, [old]);
    expect(provider.writtenTo.skip(1), everyElement(now));
    expect(provider.setsIn(now, today), hasLength(2));
    expect(open().link?.uri, now);
  });
}

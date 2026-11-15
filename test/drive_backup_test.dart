import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/drive_backup.dart';
import 'package:setlist/store.dart';

final class FakeProvider {
  FakeProvider() {
    _messenger.setMockMethodCallHandler(_channel, _handle);
  }

  static const _channel = MethodChannel('de.schurr.setlist/documents');
  static TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  static const backups = (uri: 'content://com.google.android.apps.docs.storage/tree/acc%3D1%3Bdoc%3Dbackups', name: 'Setlist backups');

  final files = <String, Uint8List>{};
  final writtenTo = <String>[];
  final released = <String>[];

  final created = <String>[];

  final askedToCreate = <String>[];

  final nearSeen = <String?>[];

  DriveDoc? pickedFolder = backups;

  Uint8List? pickNext;

  /// Every write fails with this while set, as when the lifter revoked the permission.
  PlatformException? refuse;

  final unwritable = <String>{};

  bool failCopy = false;

  bool binned = false;

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

  static bool _inTree(String uri) => uri.contains('/tree/');

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, String>();
    switch (call.method) {
      case 'openFolder':
        nearSeen.add(args['near']);
        await picking?.future;
        if (pickedFolder case final folder?) return {'uri': folder.uri, 'name': folder.name};
        return null;
      case 'copyInto':
        askedToCreate.add(args['name']!);
        if (binned) throw PlatformException(code: 'binned', message: 'the backup folder is in the Drive bin');
        if (failCopy) throw PlatformException(code: 'failed', message: 'java.io.IOException: no network');
        final uri = '${args['folder']}/document/${files.length + 1}';
        created.add(args['name']!);
        files[uri] = File(args['path']!).readAsBytesSync();
        return {'uri': uri, 'name': args['name']};
      case 'write':
        final uri = args['uri']!;
        writtenTo.add(uri);
        if (refuse case final e?) throw e;
        if (binned && _inTree(uri)) throw PlatformException(code: 'binned', message: 'the backup folder is in the Drive bin');
        if (unwritable.contains(uri)) throw PlatformException(code: 'failed', message: 'java.io.FileNotFoundException: Cannot write trashed document');
        files[uri] = File(args['path']!).readAsBytesSync();
      case 'read':
        File(args['path']!).writeAsBytesSync(files[args['uri']!]!);
      case 'pickCopy':
        nearSeen.add(args['near']);
        if (pickNext case final bytes?) {
          File(args['path']!).writeAsBytesSync(bytes);
          return true;
        }
        return false;
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
  late DateTime now;

  void logSets(int count) {
    store.saveDay(Workout(day: today, entries: [Slot(squat, [for (var i = 0; i < count; i++) SetEntry(grams: 100000, reps: 5, status: Done(DateTime.now()))])]));
    nextMillisecond();
  }

  DriveBackup open() => DriveBackup(dbPath: path, store: () => store, weekClock: () => now);
  FolderLink folderLink(DriveBackup backup) => backup.link! as FolderLink;
  WeekFile latest(DriveBackup backup) => folderLink(backup).latest!;

  void writeState(Map<String, Object?> json) => File('$path.drive-backup.json').writeAsStringSync(jsonEncode(json));
  const oldFile = 'content://com.google.android.apps.docs.storage/document/acc%3D1%3Bdoc%3Dold';

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('setlist_drive_');
    addTearDown(() => dir.deleteSync(recursive: true));
    path = '${dir.path}/setlist.sqlite';
    store = Store.open(path);
    addTearDown(store.close);
    provider = FakeProvider();
    addTearDown(provider.dispose);
    squat = store.createExercise(name: 'Squat', kind: ExerciseKind.weightReps);
    now = DateTime(2026, 11, 11, 18);
    logSets(1);
  });

  test('a week starts on the Monday on or before the local date', () {
    expect(Week.of(DateTime(2026, 11, 9)).fileName, 'Setlist week of 2026-11-09.sqlite');
    expect(Week.of(DateTime(2026, 11, 15, 23, 59)).fileName, 'Setlist week of 2026-11-09.sqlite');
    expect(Week.of(DateTime(2026, 11, 16)).fileName, 'Setlist week of 2026-11-16.sqlite');
    expect(Week.of(DateTime(2026, 1, 1, 12)).fileName, 'Setlist week of 2025-12-29.sqlite');
    expect(Week.of(DateTime(2026, 3, 29, 12)), Week.of(DateTime(2026, 3, 23)), reason: 'the Sunday clocks go forward in Europe stays in its week');
    expect(Week.of(DateTime(2026, 3, 29, 23, 59)).fileName, 'Setlist week of 2026-03-23.sqlite');
    expect(Week.of(DateTime(2026, 10, 25, 23, 59)).fileName, 'Setlist week of 2026-10-19.sqlite', reason: 'the Sunday clocks go back in Europe stays in its week');
    expect(Week.of(DateTime(2026, 10, 26)).fileName, 'Setlist week of 2026-10-26.sqlite');
    expect(Week.parse('2026-11-09'), Week.of(DateTime(2026, 11, 12)));
    expect(() => Week.parse('2026-11-10'), throwsFormatException);
  });

  test('does nothing while nothing is linked', () async {
    final backup = open();
    await backup.backUpIfChanged();
    expect(backup.link, isNull);
    expect(provider.writtenTo, isEmpty);
    expect(provider.created, isEmpty);
  });

  test('linking a folder backs up at once into a file named for this week', () async {
    final backup = open();
    expect(await backup.linkFolder(), isTrue);
    expect(provider.created, ['Setlist week of 2026-11-09.sqlite']);
    expect(folderLink(backup).folder, FakeProvider.backups);
    expect(latest(backup).doc.name, 'Setlist week of 2026-11-09.sqlite');
    expect(provider.setsIn(latest(backup).doc.uri, today), hasLength(1));
    expect(backup.link!.lastError, isNull);
  });

  test('cancelling the folder picker links nothing', () async {
    provider.pickedFolder = null;
    final backup = open();
    expect(await backup.linkFolder(), isFalse);
    expect(backup.link, isNull);
    expect(provider.created, isEmpty);
  });

  test('a change in the same week overwrites that week\'s file, and no change writes nothing', () async {
    final backup = open();
    await backup.linkFolder();
    final week = latest(backup).doc.uri;
    final first = backup.link!.lastSuccess!;

    await backup.backUpIfChanged();
    expect(provider.writtenTo, isEmpty, reason: 'no change since the backup');

    logSets(2);
    now = DateTime(2026, 11, 15, 23, 59);
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [week]);
    expect(provider.created, hasLength(1));
    expect(provider.setsIn(week, today), hasLength(2));
    expect(backup.link!.lastSuccess!.isAfter(first), isTrue);

    await backup.backUpIfChanged();
    expect(provider.writtenTo, [week]);
  });

  test('a change in a later week creates that week\'s file and leaves the earlier file alone', () async {
    final backup = open();
    await backup.linkFolder();
    final earlier = latest(backup).doc.uri;
    final earlierBytes = provider.files[earlier];

    now = DateTime(2026, 11, 16, 7);
    await backup.backUpIfChanged();
    expect(provider.created, hasLength(1), reason: 'a new week with no change makes no file');

    logSets(2);
    await backup.backUpIfChanged();
    expect(provider.created, ['Setlist week of 2026-11-09.sqlite', 'Setlist week of 2026-11-16.sqlite']);
    expect(latest(backup).doc.name, 'Setlist week of 2026-11-16.sqlite');
    expect(provider.setsIn(latest(backup).doc.uri, today), hasLength(2));
    expect(provider.files[earlier], earlierBytes);
    expect(provider.writtenTo, isEmpty);

    logSets(3);
    await backup.backUpIfChanged();
    expect(provider.writtenTo, [latest(backup).doc.uri]);
    expect(provider.files[earlier], earlierBytes);
  });

  test('a write to this week\'s file that fails gets a new file for the week in the same run', () async {
    final backup = open();
    await backup.linkFolder();
    final gone = latest(backup).doc.uri;
    provider.unwritable.add(gone);

    logSets(2);
    await backup.backUpIfChanged();
    expect(provider.created, ['Setlist week of 2026-11-09.sqlite', 'Setlist week of 2026-11-09.sqlite']);
    expect(latest(backup).doc.uri, isNot(gone));
    expect(provider.setsIn(latest(backup).doc.uri, today), hasLength(2));
    expect(backup.link!.lastError, isNull);

    logSets(3);
    await backup.backUpIfChanged();
    expect(provider.created, hasLength(2), reason: 'later backups go to the new file');
    expect(provider.setsIn(latest(backup).doc.uri, today), hasLength(3));
  });

  test('a lost grant is recorded with the latest backup kept and creates nothing, and the next backup retries and clears it', () async {
    final backup = open();
    await backup.linkFolder();
    final before = latest(backup);
    provider.refuse = PlatformException(code: 'denied', message: 'java.lang.SecurityException: No persistable permission grants found');

    logSets(2);
    await backup.backUpIfChanged();
    expect(backup.link!.lastError?.message, 'Setlist lost access to the backup folder. Choose it again with Change folder.');
    expect(latest(backup), before);
    expect(provider.created, hasLength(1));
    expect(open().link!.lastError, isNotNull);

    provider.refuse = null;
    await backup.backUpIfChanged();
    expect(backup.link!.lastError, isNull);
    expect(provider.setsIn(before.doc.uri, today), hasLength(2));
  });

  test('a folder in the Drive bin is recorded as such, and neither this week\'s file nor a new one is written', () async {
    final backup = open();
    await backup.linkFolder();
    final before = latest(backup);
    final bytes = provider.files[before.doc.uri];
    provider.binned = true;

    logSets(2);
    await backup.backUpIfChanged();
    expect(backup.link!.lastError?.message, 'The backup folder is in the Drive bin. Restore it in Drive, or choose another folder with Change folder.');
    expect(provider.askedToCreate, hasLength(1), reason: 'a binned folder gets no new file for the week either');
    expect(provider.files[before.doc.uri], bytes);
    expect(latest(backup), before);

    now = DateTime(2026, 11, 16, 7);
    await backup.backUpIfChanged();
    expect(provider.created, hasLength(1));
    expect(backup.link!.lastError?.message, contains('Drive bin'));
  });

  test('a failed create is recorded and keeps the latest backup', () async {
    final backup = open();
    await backup.linkFolder();
    final before = latest(backup);
    provider.failCopy = true;

    now = DateTime(2026, 11, 16, 7);
    logSets(2);
    await backup.backUpIfChanged();
    expect(backup.link!.lastError?.message, 'Drive could not be reached (java.io.IOException: no network).');
    expect(latest(backup), before);

    provider.failCopy = false;
    await backup.backUpIfChanged();
    expect(latest(backup).doc.name, 'Setlist week of 2026-11-16.sqlite');
    expect(backup.link!.lastError, isNull);
  });

  test('restoring latest copies the newest week\'s file next to the database', () async {
    final backup = open();
    await backup.linkFolder();
    now = DateTime(2026, 11, 16, 7);
    logSets(2);
    await backup.backUpIfChanged();

    final copy = await backup.fetch();
    expect(File(copy).readAsBytesSync(), provider.files[latest(backup).doc.uri]);
    expect(provider.files[latest(backup).doc.uri], isNot(provider.files.values.first));
  });

  test('the link and its latest backup survive a restart', () async {
    final before = open();
    await before.linkFolder();

    final after = open();
    expect(folderLink(after).folder, FakeProvider.backups);
    expect(latest(after), latest(before));
    await after.backUpIfChanged();
    logSets(2);
    await after.backUpIfChanged();
    expect(provider.writtenTo, [latest(before).doc.uri]);
    expect(provider.created, hasLength(1));
  });

  test('a state file whose latest week is not a Monday keeps the folder linked, and the next backup starts this week\'s file', () async {
    writeState({
      'folder': {'uri': FakeProvider.backups.uri, 'name': FakeProvider.backups.name},
      'latest': {'week': '2026-11-10', 'uri': '${FakeProvider.backups.uri}/document/9', 'name': 'Setlist week of 2026-11-10.sqlite', 'atMs': 0},
    });
    final backup = open();
    expect(folderLink(backup).folder, FakeProvider.backups);
    expect(folderLink(backup).latest, isNull);

    await backup.backUpIfChanged();
    expect(provider.created, ['Setlist week of 2026-11-09.sqlite']);
    expect(provider.setsIn(latest(backup).doc.uri, today), hasLength(1));
  });

  test('a phone upgraded from 0.2 keeps backing up to its file until a folder is chosen, which releases that file', () async {
    final last = DateTime.now().subtract(const Duration(days: 1));
    provider.files[oldFile] = Uint8List(0);
    writeState({'uri': oldFile, 'name': 'Setlist backup.sqlite', 'lastSuccessMs': last.millisecondsSinceEpoch});
    final backup = open();
    expect(backup.link, isA<OldFileLink>());
    expect(backup.link!.lastSuccess, DateTime.fromMillisecondsSinceEpoch(last.millisecondsSinceEpoch));

    await backup.backUpIfChanged();
    expect(provider.writtenTo, [oldFile]);
    expect(provider.created, isEmpty);
    expect(provider.setsIn(oldFile, today), hasLength(1));
    expect(open().link, isA<OldFileLink>());

    expect(await backup.linkFolder(), isTrue);
    expect(provider.nearSeen, [oldFile]);
    expect(provider.released, [oldFile]);
    expect(latest(backup).doc.name, 'Setlist week of 2026-11-09.sqlite');
    expect(provider.files, contains(oldFile));
  });

  test('picking the folder already linked keeps its week file, and another folder releases the first', () async {
    final backup = open();
    await backup.linkFolder();
    final week = latest(backup).doc.uri;

    expect(await backup.linkFolder(), isTrue);
    expect(provider.nearSeen.last, FakeProvider.backups.uri);
    expect(provider.created, hasLength(1));
    expect(provider.writtenTo, [week]);
    expect(provider.released, isEmpty);

    provider.pickedFolder = (uri: 'content://com.google.android.apps.docs.storage/tree/acc%3D1%3Bdoc%3Dother', name: 'Other');
    await backup.linkFolder();
    expect(provider.released, [FakeProvider.backups.uri]);
    expect(folderLink(backup).folder.name, 'Other');
    expect(provider.created, hasLength(2));
    expect(latest(backup).doc.uri, startsWith(provider.pickedFolder!.uri));
  });

  test('a last backup that claims a time still to come backs up, as after the clock was set back', () async {
    final backup = open();
    await backup.linkFolder();
    final week = latest(backup);
    writeState({
      'folder': {'uri': FakeProvider.backups.uri, 'name': FakeProvider.backups.name},
      'latest': {'week': '2026-11-09', 'uri': week.doc.uri, 'name': week.doc.name, 'atMs': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch},
    });

    final reopened = open();
    await reopened.backUpIfChanged();
    expect(provider.writtenTo, [week.doc.uri]);
    expect(reopened.link!.lastSuccess!.isAfter(DateTime.now()), isFalse);
  });

  test('stopping releases the folder, forgets it, and backs up nothing more', () async {
    final backup = open();
    await backup.linkFolder();

    await backup.unlink();
    expect(provider.released, [FakeProvider.backups.uri]);
    expect(backup.link, isNull);
    expect(open().link, isNull);

    logSets(2);
    await backup.backUpIfChanged();
    expect(provider.writtenTo, isEmpty);
    expect(provider.created, hasLength(1));
  });

  test('picking a file to restore opens in the backup folder, copies it next to the database, and a cancel copies nothing', () async {
    final backup = open();
    expect(await backup.pickCopy(), isNull);
    expect(provider.nearSeen, [null]);

    await backup.linkFolder();
    provider.pickNext = Uint8List.fromList([1, 2, 3]);
    final copy = await backup.pickCopy();
    expect(File(copy!).readAsBytesSync(), [1, 2, 3]);
    expect(provider.nearSeen.last, FakeProvider.backups.uri);
  });

  test('a backup asked for while the folder picker is open waits, and goes to the folder picked', () async {
    final backup = open();
    await backup.linkFolder();
    logSets(2);

    provider.picking = Completer();
    provider.pickedFolder = (uri: 'content://com.google.android.apps.docs.storage/tree/acc%3D1%3Bdoc%3Dother', name: 'Other');
    final changing = backup.linkFolder();
    final leaving = backup.backUpIfChanged();
    await pumpEventQueue();
    expect(provider.created, hasLength(1));

    provider.picking!.complete();
    await changing;
    await leaving;
    expect(provider.released, [FakeProvider.backups.uri]);
    expect(latest(backup).doc.uri, startsWith(provider.pickedFolder!.uri));
    expect(provider.setsIn(latest(backup).doc.uri, today), hasLength(2));
    expect(provider.writtenTo, isEmpty);
    expect(folderLink(open()).folder.name, 'Other');
  });
}

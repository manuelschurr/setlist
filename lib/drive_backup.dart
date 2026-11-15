/// Keeps one copy of the database per week in a folder the lifter picked through the system folder picker, normally a folder inside My Drive. Each time the app goes to the background after a change, the snapshot goes over this week's file, which the week's first backup creates, so a week's file never changes once the week is over. The Drive app's document provider does the talking to Google (android/.../Documents.kt), so the app has no sign-in.
///
/// The link lives in a file next to the database, not in its setting table: a write there would bump the database's own modification time past the backup it records, so every backup would look stale, and a restored database would bring along a link whose permission belongs to another install.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'day.dart';
import 'store.dart';

/// The Monday that starts a local calendar week. Every backup taken in one week goes to that week's file.
extension type const Week._(Day monday) implements Object {
  factory Week.of(DateTime time) {
    final local = time.toLocal();
    // Noon, so a daylight saving change cannot move the day.
    return Week._(Day.of(DateTime(local.year, local.month, local.day - (local.weekday - DateTime.monday), 12)));
  }

  /// Parses the `YYYY-MM-DD` of a Monday, and throws [FormatException] for any other day.
  factory Week.parse(String iso) {
    final day = Day.parse(iso);
    if (day.date.weekday != DateTime.monday) throw FormatException('not a Monday', iso);
    return Week._(day);
  }

  /// The date sorts by name in Drive, and Drive keeps the name exactly (measured).
  String get fileName => 'Setlist week of ${monday.iso}.sqlite';
}

/// A document the provider named, by the content URI this install holds a grant for.
typedef DriveDoc = ({String uri, String name});

typedef BackupError = ({DateTime at, String message});

/// The newest file in the folder that holds a snapshot: its week, the document, and when the snapshot was taken, to the millisecond, so every change before [at] is in it.
typedef WeekFile = ({Week week, DriveDoc doc, DateTime at});

/// Where backups go and how they went. Unlinked is no [BackupLink] at all.
sealed class BackupLink {
  const BackupLink({this.lastError});

  /// When the snapshot of the last backup that reached Drive was taken, to the millisecond. Every change before it is in that file.
  DateTime? get lastSuccess;

  /// Set when the most recent backup failed, and cleared by a success.
  final BackupError? lastError;
}

final class FolderLink extends BackupLink {
  const FolderLink({required this.folder, this.latest, super.lastError});

  /// A tree URI with a persisted read and write grant.
  final DriveDoc folder;

  /// Null until the first backup into this folder succeeds.
  final WeekFile? latest;

  @override
  DateTime? get lastSuccess => latest?.at;
}

/// The single file Setlist 0.2 linked. Only the 0.2 state format makes one, so nothing links a single file again. Backups keep going to it until the lifter chooses a folder.
final class OldFileLink extends BackupLink {
  const OldFileLink._({required this.file, this.lastSuccess, super.lastError});

  final DriveDoc file;

  @override
  final DateTime? lastSuccess;
}

/// The provider refused or failed a call. [message] is shown to the lifter as is.
final class BackupUnreachable implements Exception {
  const BackupUnreachable(this.message);
  final String message;

  @override
  String toString() => 'BackupUnreachable: $message';
}

final class DriveBackup extends ChangeNotifier {
  DriveBackup({required String dbPath, required this.store, this.clock = DateTime.now, this._channel = const MethodChannel('de.schurr.setlist/documents')}) : _dbPath = dbPath, _stateFile = File('$dbPath.drive-backup.json') {
    _link = _read(_stateFile);
  }

  /// The open store, read at each backup, because a restore swaps it.
  final Store Function() store;

  /// Picks the week a backup goes to. Backup times stay on the system clock, because they are compared with file modification times.
  final DateTime Function() clock;

  final String _dbPath;
  final MethodChannel _channel;
  final File _stateFile;
  BackupLink? _link;

  BackupLink? get link => _link;

  /// A call is running or waiting. Calls run one at a time in the order they came, so a backup asked for while a picker is open goes where the lifter picks.
  bool get busy => _waiting > 0;
  int _waiting = 0;
  Future<void> _tail = Future.value();

  /// Opens the system folder picker, links the picked folder in place of any link before it, and backs up into it at once. Picking the folder already linked keeps its latest backup. Returns false when the lifter cancels. Throws [BackupUnreachable] when the provider refuses a lasting permission.
  Future<bool> linkFolder() => _serial(() async {
    final previous = _link;
    final Object? picked;
    try {
      picked = await _call('openFolder', {if (previous != null) 'near': _grantOf(previous)});
    } on _Refused {
      throw const BackupUnreachable('Drive did not give Setlist lasting access to that folder. Pick or create a folder inside My Drive.');
    }
    if (picked case {'uri': final String uri, 'name': final String name}) {
      final folder = (uri: uri, name: name);
      _save(switch (previous) {
        FolderLink(folder: (uri: final same, name: _), :final latest) when same == uri => FolderLink(folder: folder, latest: latest),
        _ => FolderLink(folder: folder),
      });
      if (previous != null && _grantOf(previous) != uri) await _release(_grantOf(previous));
      await _backUp();
      return true;
    }
    return false;
  });

  /// Backs up when the database changed since the last backup that reached Drive, or when that backup claims a time still to come, as after the clock was set back. Does nothing while unlinked. A failure lands in [BackupLink.lastError] instead of throwing.
  Future<void> backUpIfChanged() => _serial(() async {
    final link = _link;
    if (link == null) return;
    final success = link.lastSuccess;
    if (success != null && _lastWrite().isBefore(success) && !success.isAfter(DateTime.now())) return;
    await _backUp();
  });

  Future<void> backUpNow() => _serial(_backUp);

  /// Copies the latest backup next to the database and returns the copy's path, for [Store.replaceWith]. Throws [BackupUnreachable] when the file cannot be read.
  Future<String> fetch() => _serial(() async {
    final link = _link;
    final doc = switch (link) {
      FolderLink(:final latest?) => latest.doc,
      OldFileLink(:final file) => file,
      _ => throw StateError('there is no backup to restore'),
    };
    final copy = '$_dbPath.drive-restore';
    try {
      await _call('read', {'uri': doc.uri, 'path': copy});
    } on _Refused catch (r) {
      throw BackupUnreachable(_explain(r, link!));
    }
    return copy;
  });

  /// Opens the system file picker, in the backup folder when one is linked, and copies the picked file next to the database. Returns the copy's path, or null when the lifter cancels. Throws [BackupUnreachable] when the picked file cannot be read. Works unlinked too, which is how a new phone restores.
  Future<String?> pickCopy() => _serial(() async {
    final copy = '$_dbPath.drive-restore';
    final Object? picked;
    try {
      picked = await _call('pickCopy', {'path': copy, if (_link case FolderLink(:final folder)) 'near': folder.uri});
    } on _Refused catch (r) {
      throw BackupUnreachable('Setlist could not read that file (${r.detail}).');
    }
    return picked == true ? copy : null;
  });

  /// Forgets the link and gives up its permission. The files stay where they are.
  Future<void> unlink() => _serial(() async {
    final link = _link;
    if (link == null) return;
    _save(null);
    await _release(_grantOf(link));
  });

  Future<T> _serial<T>(Future<T> Function() op) {
    _waiting++;
    notifyListeners();
    final run = _tail.then((_) => op()).whenComplete(() {
      _waiting--;
      notifyListeners();
    });
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _backUp() async {
    final link = _link;
    if (link == null) return;
    // Truncated to the millisecond like file times, so a write in the same millisecond as the snapshot counts as a change instead of slipping past it.
    final startedAt = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch);
    final snapshot = File('$_dbPath.drive-upload');
    try {
      store().copyTo(snapshot.path);
      _save(await _upload(link, snapshot.path, startedAt));
    } on _Refused catch (r) {
      _save(_failed(link, _explain(r, link)));
    } on StoreWriteFailed catch (e) {
      _save(_failed(link, 'Setlist could not copy its database (${e.cause}).'));
    } finally {
      if (snapshot.existsSync()) snapshot.deleteSync();
    }
  }

  /// Puts the snapshot where [link] sends it, and returns the link as it stands once the snapshot is there.
  Future<BackupLink> _upload(BackupLink link, String snapshot, DateTime at) async {
    switch (link) {
      case OldFileLink(:final file):
        await _call('write', {'uri': file.uri, 'path': snapshot});
        return OldFileLink._(file: file, lastSuccess: at);
      case FolderLink(:final folder, :final latest):
        final week = Week.of(clock());
        final doc = switch (latest) {
          final current? when current.week == week => await _overwrite(current.doc, folder, week, snapshot),
          _ => await _copyInto(folder, week, snapshot),
        };
        return FolderLink(folder: folder, latest: (week: week, doc: doc, at: at));
    }
  }

  /// Writes over this week's file. A plain failure gets a new file for the week in the same run, because the lifter may have deleted, moved or binned the file in Drive, and the write cannot tell that apart from other failures. A lost grant or a binned folder would refuse the new file too.
  Future<DriveDoc> _overwrite(DriveDoc doc, DriveDoc folder, Week week, String snapshot) async {
    try {
      await _call('write', {'uri': doc.uri, 'path': snapshot});
      return doc;
    } on _Refused catch (r) {
      if (r.why != _Why.failed) rethrow;
    }
    return _copyInto(folder, week, snapshot);
  }

  Future<DriveDoc> _copyInto(DriveDoc folder, Week week, String snapshot) async {
    if (await _call('copyInto', {'folder': folder.uri, 'name': week.fileName, 'path': snapshot}) case {'uri': final String uri, 'name': final String name}) return (uri: uri, name: name);
    throw const _Refused(_Why.failed, 'no file came back');
  }

  /// The newest write to the database or its write-ahead log. An empty log holds no change, and SQLite creates one on the first read after a clean close.
  DateTime _lastWrite() {
    final db = File(_dbPath).statSync().modified;
    final wal = File('$_dbPath-wal').statSync();
    return wal.type == FileSystemEntityType.file && wal.size > 0 && wal.modified.isAfter(db) ? wal.modified : db;
  }

  Future<void> _release(String uri) async {
    try {
      await _call('release', {'uri': uri});
    } on _Refused {
      // The link is already forgotten, and a permission nobody uses does no harm.
    }
  }

  Future<Object?> _call(String method, Map<String, String> arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      throw _Refused(_Why.values.asNameMap()[e.code] ?? _Why.failed, e.message ?? e.code);
    } on MissingPluginException catch (e) {
      throw _Refused(_Why.failed, e.message ?? 'no documents channel');
    }
  }

  static String _explain(_Refused refused, BackupLink link) => switch ((refused.why, link)) {
    (_Why.denied, OldFileLink()) => 'Setlist lost access to the backup file. Choose a backup folder.',
    (_Why.denied, FolderLink()) => 'Setlist lost access to the backup folder. Choose it again with Change folder.',
    (_Why.binned, _) => 'The backup folder is in the Drive bin. Restore it in Drive, or choose another folder with Change folder.',
    (_Why.failed, _) => 'Drive could not be reached (${refused.detail}).',
  };

  static String _grantOf(BackupLink link) => switch (link) {
    FolderLink(:final folder) => folder.uri,
    OldFileLink(:final file) => file.uri,
  };

  static BackupLink _failed(BackupLink link, String message) {
    final error = (at: DateTime.now(), message: message);
    return switch (link) {
      FolderLink(:final folder, :final latest) => FolderLink(folder: folder, latest: latest, lastError: error),
      OldFileLink(:final file, :final lastSuccess) => OldFileLink._(file: file, lastSuccess: lastSuccess, lastError: error),
    };
  }

  void _save(BackupLink? link) {
    _link = link;
    if (link == null) {
      if (_stateFile.existsSync()) _stateFile.deleteSync();
    } else {
      final partial = File('${_stateFile.path}.partial');
      partial.writeAsStringSync(jsonEncode(_toJson(link)), flush: true);
      partial.renameSync(_stateFile.path);
    }
    notifyListeners();
  }

  /// A folder link has a `folder` key. The 0.2 file link keeps its 0.2 shape, so an upgraded phone reads its state file as it is.
  static Map<String, Object?> _toJson(BackupLink link) => {
    ...switch (link) {
      FolderLink(:final folder, :final latest) => {
        'folder': {'uri': folder.uri, 'name': folder.name},
        if (latest case (:final week, :final doc, :final at)?) 'latest': {'week': week.monday.iso, 'uri': doc.uri, 'name': doc.name, 'atMs': at.millisecondsSinceEpoch},
      },
      OldFileLink(:final file, :final lastSuccess) => {'uri': file.uri, 'name': file.name, 'lastSuccessMs': lastSuccess?.millisecondsSinceEpoch},
    },
    if (link.lastError case (:final at, :final message)?) 'error': {'atMs': at.millisecondsSinceEpoch, 'message': message},
  };

  static BackupLink? _read(File file) {
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      final error = switch (json) {
        {'error': {'atMs': final int ms, 'message': final String message}} => (at: DateTime.fromMillisecondsSinceEpoch(ms), message: message),
        _ => null,
      };
      return switch (json) {
        {'folder': {'uri': final String uri, 'name': final String name}} => FolderLink(
          folder: (uri: uri, name: name),
          latest: switch (json['latest']) {
            {'week': final String week, 'uri': final String uri, 'name': final String name, 'atMs': final int ms} => _weekFile(week, (uri: uri, name: name), ms),
            _ => null,
          },
          lastError: error,
        ),
        {'uri': final String uri, 'name': final String name} => OldFileLink._(
          file: (uri: uri, name: name),
          lastSuccess: switch (json['lastSuccessMs']) {
            final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
            _ => null,
          },
          lastError: error,
        ),
        _ => null,
      };
    } on FormatException {
      // Unreadable: treated as unlinked, so the lifter links again.
      return null;
    }
  }
}

/// A week that does not parse drops only the latest file, so the next backup starts a new one instead of the folder being forgotten and backups stopping.
WeekFile? _weekFile(String week, DriveDoc doc, int atMs) {
  try {
    return (week: Week.parse(week), doc: doc, at: DateTime.fromMillisecondsSinceEpoch(atMs));
  } on FormatException {
    return null;
  }
}

/// Why Documents.kt refused a call: the grant behind the document is gone, the backup folder is in the Drive bin, or anything else.
enum _Why { denied, binned, failed }

final class _Refused implements Exception {
  const _Refused(this.why, this.detail);
  final _Why why;
  final String detail;
}

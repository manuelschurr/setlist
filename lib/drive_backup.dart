/// Keeps a copy of the database in one file the lifter created through the system picker, normally on Google Drive, and refreshes it whenever the app goes to the background after a change. The Drive app's document provider does the talking to Google (android/.../Documents.kt), so the app has no sign-in.
///
/// The link lives in a file next to the database, not in its setting table: a write there would bump the database's own modification time past the backup it records, so every backup would look stale, and a restored database would bring along a link whose permission belongs to another install.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'store.dart';

/// The linked backup file and how the backups to it went. Unlinked is no [BackupLink] at all.
final class BackupLink {
  const BackupLink({required this.uri, required this.name, this.lastSuccess, this.lastError});

  /// A content URI this install holds a persisted read and write permission for.
  final String uri;

  /// The file name the provider shows.
  final String name;

  /// When the snapshot of the last backup that reached the file was taken, to the millisecond. Every change before it is in the file.
  final DateTime? lastSuccess;

  /// Set when the most recent backup failed, and cleared by a success.
  final BackupError? lastError;
}

typedef BackupError = ({DateTime at, String message});

/// The provider refused or failed a call on the backup file. [message] is shown to the lifter as is.
final class BackupUnreachable implements Exception {
  const BackupUnreachable(this.message);
  final String message;

  @override
  String toString() => 'BackupUnreachable: $message';
}

final class DriveBackup extends ChangeNotifier {
  DriveBackup({required String dbPath, required this.store, this._channel = const MethodChannel('de.schurr.setlist/documents')}) : _dbPath = dbPath, _stateFile = File('$dbPath.drive-backup.json') {
    _link = _read(_stateFile);
  }

  static const suggestedName = 'Setlist backup.sqlite';

  /// The open store, read at each backup, because a restore swaps it.
  final Store Function() store;

  final String _dbPath;
  final MethodChannel _channel;
  final File _stateFile;
  BackupLink? _link;

  BackupLink? get link => _link;

  /// A call is running or waiting. Calls run one at a time in the order they came, so a backup asked for while the picker is open goes to the file the lifter picks.
  bool get busy => _waiting > 0;
  int _waiting = 0;
  Future<void> _tail = Future.value();

  /// Opens the system picker to create a new backup file, links it in place of any file linked before, and backs up to it at once. Returns false when the lifter cancels. Throws [BackupUnreachable] when the provider refuses a lasting permission.
  Future<bool> linkNewFile() => _serial(() async {
    final created = await _call<Map<Object?, Object?>>('create', {'name': suggestedName});
    if (created case {'uri': final String uri, 'name': final String name}) {
      final previous = _link;
      _save(BackupLink(uri: uri, name: name));
      if (previous != null && previous.uri != uri) await _release(previous.uri);
      await _backUp();
      return true;
    }
    return false;
  });

  /// Backs up when the database changed since the last backup that reached the file. Does nothing while unlinked. A failure lands in [BackupLink.lastError] instead of throwing.
  Future<void> backUpIfChanged() => _serial(() async {
    final success = _link?.lastSuccess;
    if (_link == null || (success != null && _lastWrite().isBefore(success))) return;
    await _backUp();
  });

  Future<void> backUpNow() => _serial(_backUp);

  /// Copies the linked file next to the database and returns the copy's path, for [Store.replaceWith]. Throws [BackupUnreachable] when the file cannot be read.
  Future<String> fetch() => _serial(() async {
    final link = _link;
    if (link == null) throw StateError('no backup file is linked');
    final copy = '$_dbPath.drive-restore';
    await _call<void>('read', {'uri': link.uri, 'path': copy});
    return copy;
  });

  /// Forgets the link and gives up the permission. The file stays where it is.
  Future<void> unlink() => _serial(() async {
    final link = _link;
    if (link == null) return;
    _save(null);
    await _release(link.uri);
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
    String? failure;
    try {
      store().copyTo(snapshot.path);
      await _call<void>('write', {'uri': link.uri, 'path': snapshot.path});
    } on BackupUnreachable catch (e) {
      failure = e.message;
    } on StoreWriteFailed catch (e) {
      failure = 'Setlist could not copy its database (${e.cause}).';
    } finally {
      if (snapshot.existsSync()) snapshot.deleteSync();
    }
    _save(BackupLink(uri: link.uri, name: link.name, lastSuccess: failure == null ? startedAt : link.lastSuccess, lastError: failure == null ? null : (at: DateTime.now(), message: failure)));
  }

  /// The newest write to the database or its write-ahead log. An empty log holds no change, and SQLite creates one on the first read after a clean close.
  DateTime _lastWrite() {
    final db = File(_dbPath).statSync().modified;
    final wal = File('$_dbPath-wal').statSync();
    return wal.type == FileSystemEntityType.file && wal.size > 0 && wal.modified.isAfter(db) ? wal.modified : db;
  }

  Future<void> _release(String uri) async {
    try {
      await _call<void>('release', {'uri': uri});
    } on BackupUnreachable {
      // The link is already forgotten, and a permission nobody uses does no harm.
    }
  }

  Future<T?> _call<T>(String method, Map<String, String> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw BackupUnreachable(e.code == 'denied' ? 'Setlist lost access to the backup file. Choose it again with Change file.' : 'The backup file could not be reached (${e.message}).');
    }
  }

  void _save(BackupLink? link) {
    _link = link;
    if (link == null) {
      if (_stateFile.existsSync()) _stateFile.deleteSync();
    } else {
      final partial = File('${_stateFile.path}.partial');
      partial.writeAsStringSync(
        jsonEncode({
          'uri': link.uri,
          'name': link.name,
          'lastSuccessMs': link.lastSuccess?.millisecondsSinceEpoch,
          if (link.lastError case (:final at, :final message)?) 'error': {'atMs': at.millisecondsSinceEpoch, 'message': message},
        }),
        flush: true,
      );
      partial.renameSync(_stateFile.path);
    }
    notifyListeners();
  }

  static BackupLink? _read(File file) {
    if (!file.existsSync()) return null;
    try {
      if (jsonDecode(file.readAsStringSync()) case {'uri': final String uri, 'name': final String name} && final json) {
        return BackupLink(
          uri: uri,
          name: name,
          lastSuccess: switch (json['lastSuccessMs']) {
            final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
            _ => null,
          },
          lastError: switch (json['error']) {
            {'atMs': final int ms, 'message': final String message} => (at: DateTime.fromMillisecondsSinceEpoch(ms), message: message),
            _ => null,
          },
        );
      }
    } on FormatException {
      // Unreadable: treated as unlinked, so the lifter links again.
    }
    return null;
  }
}

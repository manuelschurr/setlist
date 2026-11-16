import 'dart:io';

import 'package:flutter/material.dart';

import 'day.dart';
import 'drive_backup.dart';
import 'workout_screen.dart';

/// Runs [copy], asks before restoring the file it copied, and deletes that file afterwards. A file that cannot be read shows why, and a cancelled pick does nothing.
Future<void> restoreFromCopy(BuildContext context, Home home, Future<String?> Function() copy) async {
  final String? path;
  try {
    path = await copy();
  } on BackupUnreachable catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (path == null) return;
  try {
    if (context.mounted) await home.confirmRestore(context, path);
  } finally {
    final left = File(path);
    if (left.existsSync()) left.deleteSync();
  }
}

class DriveBackupScreen extends StatefulWidget {
  const DriveBackupScreen({super.key, required this.home});

  final Home home;

  @override
  State<DriveBackupScreen> createState() => _DriveBackupScreenState();
}

class _DriveBackupScreenState extends State<DriveBackupScreen> {
  DriveBackup get _backup => widget.home.backup;

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _link() async {
    try {
      if (!await _backup.linkFolder()) return;
    } on BackupUnreachable catch (e) {
      _say(e.message);
      return;
    }
    if (_backup.link case FolderLink(:final folder)) _say('Backing up to ${folder.name}.');
  }

  Future<void> _backUpNow() async {
    await _backup.backUpNow();
    if (_backup.link?.lastError == null) _say('Backed up');
  }

  Future<void> _restore(Future<String?> Function() copy) => restoreFromCopy(context, widget.home, copy);

  Future<void> _stop() async {
    await _backup.unlink();
    _say('Backups stopped. The backup files stay in Drive.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _backup,
      builder: (context, _) {
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final busy = _backup.busy;
        void Function()? unlessBusy(void Function() action) => busy ? null : action;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Google Drive backup'),
            bottom: busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: switch (_backup.link) {
              null => [
                const Text("Choose a folder on Google Drive. Setlist keeps one backup file per week in it and updates this week's file whenever you leave the app after a change. Earlier weeks' files are never changed, so a mistake can only reach this week's."),
                const SizedBox(height: 8),
                Text("In the picker, open My Drive, then choose a folder or create one, such as Setlist backups. My Drive itself can't be used.", style: muted),
                const SizedBox(height: 24),
                FilledButton(onPressed: unlessBusy(_link), child: const Text('Choose backup folder')),
              ],
              final OldFileLink link => [
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Back up into a folder', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text('Setlist now keeps one backup file per week in a folder, so a bad change can no longer overwrite your only backup. Until you choose a folder, backups keep going to ${link.file.name}.'),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: unlessBusy(_link), child: const Text('Choose backup folder')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _Status(link: link),
                const SizedBox(height: 24),
                OutlinedButton(onPressed: unlessBusy(_backUpNow), child: const Text('Back up now')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: link.lastSuccess == null ? null : unlessBusy(() => _restore(_backup.fetch)), child: const Text('Restore from this backup')),
                const SizedBox(height: 8),
                TextButton(onPressed: unlessBusy(_stop), child: const Text('Stop backing up')),
              ],
              final FolderLink link => [
                _Status(link: link),
                const SizedBox(height: 24),
                FilledButton(onPressed: unlessBusy(_backUpNow), child: const Text('Back up now')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: link.latest == null ? null : unlessBusy(() => _restore(_backup.fetch)), child: const Text('Restore latest backup')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: unlessBusy(() => _restore(_backup.pickCopy)), child: const Text('Restore an earlier week')),
                const SizedBox(height: 8),
                TextButton(onPressed: unlessBusy(_link), child: const Text('Change folder')),
                TextButton(onPressed: unlessBusy(_stop), child: const Text('Stop backing up')),
                const SizedBox(height: 16),
                Text("One file per week, named by the Monday it starts. Setlist never changes or deletes an earlier week's file. Delete old ones in Drive if you need the space.", style: muted),
              ],
            },
          ),
        );
      },
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.link});

  final BackupLink link;

  static String _when(DateTime t) => '${dayLabel(Day.of(t))} at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = link.lastSuccess;
    final error = link.lastError;
    final (title, file) = switch (link) {
      FolderLink(:final folder, :final latest) => (folder.name, latest?.doc.name),
      OldFileLink(:final file) => (file.name, null),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(error == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, color: error == null ? theme.colorScheme.primary : theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
          ],
        ),
        const SizedBox(height: 12),
        Text(success == null ? 'No backup yet' : 'Last backup: ${_when(success)}'),
        if (file != null) Text('In $file', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text('Failed: ${_when(error.at)}. ${error.message}', style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

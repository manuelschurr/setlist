import 'dart:io';

import 'package:flutter/material.dart';

import 'day.dart';
import 'drive_backup.dart';
import 'workout_screen.dart';

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
      await _backup.linkNewFile();
    } on BackupUnreachable catch (e) {
      _say(e.message);
    }
  }

  Future<void> _backUpNow() async {
    await _backup.backUpNow();
    if (_backup.link?.lastError == null) _say('Backed up');
  }

  Future<void> _restore() async {
    final String copy;
    try {
      copy = await _backup.fetch();
    } on BackupUnreachable catch (e) {
      _say(e.message);
      return;
    }
    try {
      if (mounted) await widget.home.confirmRestore(context, copy);
    } finally {
      final left = File(copy);
      if (left.existsSync()) left.deleteSync();
    }
  }

  Future<void> _stop() async {
    await _backup.unlink();
    _say('Backups stopped. The file stays where it is.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _backup,
      builder: (context, _) {
        final link = _backup.link;
        final busy = _backup.busy;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Google Drive backup'),
            bottom: busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: link == null
                ? [
                    const Text('Choose a file on Google Drive, and Setlist copies all your workouts into it whenever you leave the app after a change.'),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: busy ? null : _link, child: const Text('Choose backup file')),
                  ]
                : [
                    _Status(link: link),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: busy ? null : _backUpNow, child: const Text('Back up now')),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: busy ? null : _restore, child: const Text('Restore from this backup')),
                    const SizedBox(height: 8),
                    TextButton(onPressed: busy ? null : _link, child: const Text('Change file')),
                    TextButton(onPressed: busy ? null : _stop, child: const Text('Stop backing up')),
                  ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(error == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, color: error == null ? theme.colorScheme.primary : theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(link.name, style: theme.textTheme.titleMedium)),
          ],
        ),
        const SizedBox(height: 12),
        Text(success == null ? 'No backup yet' : 'Last backup: ${_when(success)}'),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text('Failed: ${_when(error.at)}. ${error.message}', style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

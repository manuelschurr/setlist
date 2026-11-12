/// Past days, newest first, and the data menu: import a FitNotes backup, export a Setlist backup, restore a Setlist backup. Reads through [Store.recentWorkouts], the same query as the empty day's Copy list, and summarises each day with the getters on [Workout] and [Slot], the same ones the workout screen uses.
///
/// Pops with a [Workout] when the lifter copies a day, which the home screen copies into today, and with nothing otherwise.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'day.dart';
import 'fitnotes.dart';
import 'store.dart';
import 'workout_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.store, required this.home});

  final Store store;
  final Home home;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

enum _DataAction { import, export, restore }

class _HistoryScreenState extends State<HistoryScreen> {
  final List<Workout> _days = [];
  bool _reachedEnd = false;

  /// An import, export or restore is running. The data menu is off until it ends.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  void _loadMore() {
    final page = widget.store.recentWorkouts(before: _days.isEmpty ? null : _days.last.day, limit: 30);
    setState(() {
      _days.addAll(page);
      _reachedEnd = page.length < 30;
    });
  }

  void _reload() {
    _days.clear();
    _loadMore();
  }

  /// Today pops back to the home screen, which already shows it. Any other day opens on a workout screen of its own; a day picked there comes back here and opens in turn.
  Future<void> _open(Day day) async {
    if (day == widget.home.day) {
      Navigator.pop(context);
      return;
    }
    final next = await Navigator.push<Day>(context, MaterialPageRoute(builder: (_) => WorkoutScreen(store: widget.store, home: widget.home, day: day)));
    if (!mounted) return;
    _reload();
    if (next != null) _open(next);
  }

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Copies the picked file into the cache directory, because Android may hand back a content URI with no path, and runs [use] on the copy. The copy is gone afterwards unless [use] moved it.
  Future<void> _withPickedCopy(String title, String name, Future<void> Function(File copy) use) async {
    final picked = await FilePicker.pickFile(dialogTitle: title);
    if (picked == null || !mounted) return;
    final copy = File('${(await getTemporaryDirectory()).path}/$name');
    try {
      await copy.writeAsBytes(await picked.readAsBytes());
      if (mounted) await use(copy);
    } finally {
      if (await copy.exists()) await copy.delete();
    }
  }

  Future<void> _import() async {
    final dbPath = widget.store.path;
    if (dbPath == null) return;
    await _withPickedCopy('FitNotes backup', 'fitnotes-import.sqlite', (copy) async {
      setState(() => _busy = true);
      ImportOutcome? outcome;
      try {
        outcome = await importFitNotes(backupPath: copy.path, dbPath: dbPath);
      } on FitNotesFormatError catch (e) {
        _say(e.message);
      } on StoreWriteFailed {
        _say('The import could not write to the database and changed nothing.');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (outcome == null || !mounted) return;
      _reload();
      await _showOutcome(outcome);
    });
  }

  /// Sets written against training_log rows, days written and skipped, exercises created and matched, and what the reader left out, such as routines and superset groups.
  Future<void> _showOutcome(ImportOutcome outcome) {
    final w = outcome.written;
    final skipped = w.skippedDays;
    final lines = [
      '${w.setsWritten} of ${outcome.trainingLogRows} sets written, on ${w.daysWritten} days.',
      '${w.exercisesCreated} exercises created, ${w.exercisesLinked} matched to ones already here.',
      if (skipped.isNotEmpty) '${skipped.length} days skipped because they were changed in Setlist: ${skipped.take(5).map(dayLabel).join(', ')}${skipped.length > 5 ? ' and ${skipped.length - 5} more' : ''}.',
      if (outcome.leftOut.isNotEmpty) 'Left out: ${outcome.leftOut.entries.map((e) => '${e.value} ${e.key}').join(', ')}.',
    ];
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('FitNotes import done'),
        content: Text(lines.join('\n\n')),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    final name = 'setlist-${Day.of(DateTime.now()).iso}.sqlite';
    final copy = File('${(await getTemporaryDirectory()).path}/$name');
    try {
      widget.store.copyTo(copy.path);
      final saved = await FilePicker.saveFile(fileName: name, bytes: await copy.readAsBytes(), dialogTitle: 'Save Setlist backup');
      if (saved != null) _say('Backup saved');
    } on Exception catch (e) {
      _say('Export failed: $e');
    } finally {
      if (await copy.exists()) await copy.delete();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    await _withPickedCopy('Setlist backup', 'setlist-restore.sqlite', (copy) async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore this backup?'),
          content: const Text('Everything in Setlist is replaced by the backup. Workouts logged after it was made are lost. A copy of the current data stays on the phone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
          ],
        ),
      );
      if (confirmed == true) widget.home.restore(copy.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          PopupMenuButton<_DataAction>(
            enabled: !_busy,
            tooltip: 'Data',
            onSelected: (action) => switch (action) {
              _DataAction.import => _import(),
              _DataAction.export => _export(),
              _DataAction.restore => _restore(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: _DataAction.import, child: Text('Import FitNotes backup')),
              PopupMenuItem(value: _DataAction.export, child: Text('Export Setlist backup')),
              PopupMenuItem(value: _DataAction.restore, child: Text('Restore Setlist backup')),
            ],
          ),
        ],
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: _days.isEmpty && _reachedEnd
          ? const Center(child: Text('No workouts yet'))
          : ListView.builder(
              itemCount: _days.length + (_reachedEnd ? 0 : 1),
              itemBuilder: (context, i) {
                if (i == _days.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _loadMore();
                  });
                  return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                }
                final w = _days[i];
                final sets = w.summary.doneSets;
                return ListTile(
                  title: Text(dayLabel(w.day)),
                  subtitle: Text(w.slots.isEmpty ? w.note : w.slots.map((s) => s.exercise.name).join(', '), maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(sets == 1 ? '1 set' : '$sets sets'),
                      if (w.day != widget.home.day && w.slots.isNotEmpty) IconButton(icon: const Icon(Icons.content_copy), tooltip: 'Copy to today', onPressed: () => Navigator.pop(context, w)),
                    ],
                  ),
                  onTap: () => _open(w.day),
                );
              },
            ),
    );
  }
}

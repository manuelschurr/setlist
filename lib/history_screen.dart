/// Past days, newest first, and the FitNotes import. Reads through [Store.recentWorkouts], the same query as the empty day's Copy list, and summarises each day with the getters on [Workout] and [Slot], the same ones the workout screen uses.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'day.dart';
import 'fitnotes.dart';
import 'rest_alarm.dart';
import 'store.dart';
import 'workout_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.store, required this.alarm});

  final Store store;
  final RestAlarm alarm;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final List<Workout> _days = [];
  bool _reachedEnd = false;

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

  Future<void> _open(Day day) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => WorkoutScreen(store: widget.store, alarm: widget.alarm, day: day)));
    if (mounted) _reload();
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'FitNotes backup');
    if (picked.isEmpty || !mounted) return;
    final dbPath = widget.store.path!;
    // The picker may hand back a content URI with no path, so the importer always reads a copy in the cache directory.
    final copy = File('${(await getTemporaryDirectory()).path}/fitnotes-import.sqlite');
    await copy.writeAsBytes(await picked.single.readAsBytes());
    try {
      final outcome = await importFitNotes(backupPath: copy.path, dbPath: dbPath);
      if (!mounted) return;
      _reload();
      await _showOutcome(outcome);
    } on FitNotesFormatError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      await copy.delete();
    }
  }

  /// Sets written against training_log rows, skipped days, and what the reader left out, such as routines and superset groups.
  Future<void> _showOutcome(ImportOutcome outcome) => throw UnimplementedError();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History'), actions: [IconButton(onPressed: _import, icon: const Icon(Icons.upload_file), tooltip: 'Import FitNotes backup')]),
      body: ListView.builder(
        itemCount: _days.length + (_reachedEnd ? 0 : 1),
        itemBuilder: (context, i) {
          if (i == _days.length) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
            return const Center(child: CircularProgressIndicator());
          }
          final w = _days[i];
          return ListTile(
            title: Text(w.day.iso), // TODO: weekday and date
            subtitle: Text(w.slots.map((s) => s.exercise.name).join(', ')),
            trailing: Text('${w.summary.doneSets} sets'),
            onTap: () => _open(w.day),
          );
        },
      ),
    );
  }
}

/// Past days, newest first. Reads through [Store.recentWorkouts], the same query as the empty day's Copy list, and summarises each day with the getters on [Workout] and [Slot], the same ones the workout screen uses.
///
/// Pops with a [Workout] when the lifter copies a day, which the home screen copies into today, and with nothing otherwise.
library;

import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';
import 'workout_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.store, required this.home});

  final Store store;
  final Home home;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
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

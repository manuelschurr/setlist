/// The past sessions of one exercise, newest first, opened from a card's menu. Read-only.
library;

import 'package:flutter/material.dart';

import 'day.dart';
import 'store.dart';
import 'workout_screen.dart';

/// Brzycki's estimated one-rep max in grams, the formula FitNotes uses. Null outside 1 to 36 reps, where the formula has no meaning, and for sets with no weight.
double? estimatedMax(SetEntry set) => set.reps < 1 || set.reps > 36 || set.grams <= 0 ? null : set.grams * 36 / (37 - set.reps);

class ExerciseHistoryScreen extends StatefulWidget {
  const ExerciseHistoryScreen({super.key, required this.store, required this.exercise});

  final Store store;
  final Exercise exercise;

  @override
  State<ExerciseHistoryScreen> createState() => _ExerciseHistoryScreenState();
}

/// One past day of the exercise, with its best estimate in grams when the kind has one, and whether that beat every older session.
typedef _Session = ({Day day, List<SetEntry> sets, double? best, bool newBest});

class _ExerciseHistoryScreenState extends State<ExerciseHistoryScreen> {
  late final List<_Session> _sessions = _load();

  /// Each session's best estimate over its working sets, and whether it beat every older session on the list. The oldest session is never marked, because the list may not reach back to the first one.
  List<_Session> _load() {
    final history = widget.store.exerciseHistory(widget.exercise.id);
    final estimates = widget.exercise.kind == ExerciseKind.weightReps;
    final result = <_Session>[];
    double? record;
    for (final (:day, :sets) in history.reversed) {
      double? best;
      if (estimates) {
        for (final set in sets) {
          final e = set.warmup ? null : estimatedMax(set);
          if (e != null && (best == null || e > best)) best = e;
        }
      }
      final newBest = best != null && record != null && best > record;
      if (best != null && (record == null || best > record)) record = best;
      result.add((day: day, sets: sets, best: best, newBest: newBest));
    }
    return result.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = widget.exercise.kind;
    return Scaffold(
      appBar: AppBar(title: Text(widget.exercise.name)),
      body: _sessions.isEmpty
          ? const Center(child: Text('Not done yet'))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _sessions.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final (:day, :sets, :best, :newBest) = _sessions[i];
                final labels = setLabels(sets);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(dayLabel(day), style: theme.textTheme.titleMedium)),
                          if (best != null) Text('e1RM ${Field.weight.format((best / 100).round() * 100)} kg', style: theme.textTheme.labelLarge),
                        ],
                      ),
                      if (newBest)
                        Row(
                          children: [
                            Icon(Icons.emoji_events, size: 18, color: theme.colorScheme.tertiary),
                            const SizedBox(width: 4),
                            Text('New best', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.tertiary)),
                          ],
                        ),
                      const SizedBox(height: 4),
                      for (final (j, set) in sets.indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: 32, child: Text(labels[j], style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    text: setText(set, kind),
                                    children: [if (set.note.isNotEmpty) TextSpan(text: '  ${set.note}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic))],
                                  ),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

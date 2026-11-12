/// The Android side of the rest countdown, which is an ongoing notification that counts down and an exact alarm that vibrates when rest ends. A Dart timer cannot do this, because it stops once the screen is off and the CPU sleeps (docs/decisions.tsv, 2026-11-12).
library;

import 'package:flutter/services.dart';

import 'day.dart';

/// Keeps the system's countdown equal to the rest the workout implies. The screen does not track timer transitions; it calls [show] with [Workout.restAt] after every change and on resume.
abstract interface class RestAlarm {
  /// Makes the notification and the alarm match [rest]. It posts or moves them when [rest] is set and cancels both when null. It is idempotent. A call with the same value as the last one does nothing, so calling it after every stepper tap costs nothing, and an undo that removes the log cancels the alarm with no special case.
  void show(Rest? rest);
}

/// Talks to MainActivity over a method channel. The Kotlin side (RestAlarm.kt) posts a notification with a count-down chronometer whose `when` is [Rest.endsAt], and sets AlarmManager.setAlarmClock so a receiver vibrates and posts "Rest over" at that time.
final class AndroidRestAlarm implements RestAlarm {
  static const _channel = MethodChannel('de.schurr.setlist/rest');

  // The first call always goes through, because a notification or alarm can outlive the process that posted it.
  bool _sent = false;
  DateTime? _sentEndsAt;

  @override
  void show(Rest? rest) {
    if (_sent && rest?.endsAt == _sentEndsAt) return;
    _sent = true;
    _sentEndsAt = rest?.endsAt;
    final call = rest == null ? _channel.invokeMethod<void>('cancel') : _channel.invokeMethod<void>('show', {'title': rest.exercise.name, 'endsAtMs': rest.endsAt.millisecondsSinceEpoch});
    // Fire and forget; a failed call leaves the in-app countdown working.
    call.ignore();
  }
}

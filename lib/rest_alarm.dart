/// The Android side of the rest countdown, which is an ongoing notification that counts down and an exact alarm that vibrates when rest ends. A Dart timer cannot do this, because it stops once the screen is off and the CPU sleeps (docs/decisions.tsv, 2026-11-12).
library;

import 'day.dart';

/// Keeps the system's countdown equal to the rest the workout implies. The screen does not track timer transitions; it calls [show] with [Workout.restAt] after every change and on resume.
abstract interface class RestAlarm {
  /// Makes the notification and the alarm match [rest]. It posts or moves them when [rest] is set and cancels both when null. It is idempotent. A call with the same value as the last one does nothing, so calling it after every stepper tap costs nothing, and an undo that removes the log cancels the alarm with no special case.
  void show(Rest? rest);
}

/// Talks to a small Kotlin handler over a method channel. The handler posts a NotificationCompat with a count-down chronometer whose `when` is [Rest.endsAt], and sets AlarmManager.setExactAndAllowWhileIdle for the vibration.
final class AndroidRestAlarm implements RestAlarm {
  DateTime? _shownEndsAt;

  @override
  void show(Rest? rest) {
    // TODO:
    //   if (rest?.endsAt == _shownEndsAt) return
    //   _shownEndsAt = rest?.endsAt
    //   rest == null ? channel.invokeMethod('cancel') : channel.invokeMethod('show', {'title': rest.exercise.name, 'endsAtMs': rest.endsAt.millisecondsSinceEpoch})
    //   Fire and forget; a failed call (notification permission denied) leaves the in-app countdown working.
    throw UnimplementedError();
  }
}

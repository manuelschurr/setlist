import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'day.dart';
import 'rest_alarm.dart';
import 'store.dart';
import 'workout_screen.dart';

/// Opens the one database file and shows today. The store and the [Home] are passed down by constructor; there is no other shared state, because each screen loads what it shows from the store.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final store = Store.open('${dir.path}/setlist.sqlite');
  final home = Home(day: Day.of(DateTime.now()), alarm: AndroidRestAlarm());
  runApp(MaterialApp(title: 'Setlist', theme: setlistTheme(Brightness.light), darkTheme: setlistTheme(Brightness.dark), home: WorkoutScreen(store: store, home: home, day: home.day)));
}

/// Material 3 from a muted sage seed, light or dark as the system says, with tabular figures in every text style so weights, reps and the countdown do not jitter as digits change.
ThemeData setlistTheme(Brightness brightness) {
  final base = ThemeData(colorSchemeSeed: const Color(0xFF4F7A74), brightness: brightness);
  const tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
  return base.copyWith(
    textTheme: base.textTheme.merge(
      const TextTheme(
        displayLarge: tabular,
        displayMedium: tabular,
        displaySmall: tabular,
        headlineLarge: tabular,
        headlineMedium: tabular,
        headlineSmall: tabular,
        titleLarge: tabular,
        titleMedium: tabular,
        titleSmall: tabular,
        bodyLarge: tabular,
        bodyMedium: tabular,
        bodySmall: tabular,
        labelLarge: tabular,
        labelMedium: tabular,
        labelSmall: tabular,
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'day.dart';
import 'rest_alarm.dart';
import 'store.dart';
import 'workout_screen.dart';

/// Opens the one database file and shows today. The store and the alarm are passed down by constructor; there is no other shared state, because each screen loads what it shows from the store.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final store = Store.open('${dir.path}/setlist.sqlite');
  runApp(MaterialApp(
    title: 'Setlist',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: WorkoutScreen(store: store, alarm: AndroidRestAlarm(), day: Day.of(DateTime.now())),
  ));
}

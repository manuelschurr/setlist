import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'day.dart';
import 'rest_alarm.dart';
import 'store.dart';
import 'workout_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  runApp(SetlistApp(dbPath: '${dir.path}/setlist.sqlite', alarm: AndroidRestAlarm()));
}

class SetlistApp extends StatefulWidget {
  const SetlistApp({super.key, required this.dbPath, required this.alarm, this.clock = DateTime.now});

  final String dbPath;
  final RestAlarm alarm;

  final DateTime Function() clock;

  @override
  State<SetlistApp> createState() => _SetlistAppState();
}

class _SetlistAppState extends State<SetlistApp> with WidgetsBindingObserver {
  late Store _store = Store.open(widget.dbPath);
  late Home _home = _newHome();
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  Home _newHome() => Home(day: Day.of(widget.clock()), alarm: widget.alarm, restore: _restore);

  /// A process that lives through the night would otherwise show yesterday and log onto it. A set logged within the last 3 hours means a session that crossed midnight, which stays on its day.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = widget.clock();
    if (Day.of(now) == _home.day) return;
    final recent = [
      for (final slot in _store.loadDay(_home.day).slots)
        for (final set in slot.sets)
          if (set.status case Done(:final at?) when now.difference(at) < const Duration(hours: 3)) set,
    ];
    if (recent.isEmpty) setState(() => _home = _newHome());
  }

  /// Every screen holds the old store, so after the swap the app starts over from a new home on today, with a new navigator.
  void _restore(String backupPath) {
    _store.close();
    String message;
    try {
      Store.replaceWith(backupPath, dbPath: widget.dbPath);
      message = 'Backup restored';
    } on NotASetlistBackup catch (e) {
      message = e.message;
    } finally {
      _store = Store.open(widget.dbPath);
      setState(() => _home = _newHome());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _messenger.currentState?..clearSnackBars()..showSnackBar(SnackBar(content: Text(message))));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      key: ObjectKey(_home),
      title: 'Setlist',
      scaffoldMessengerKey: _messenger,
      theme: setlistTheme(Brightness.light),
      darkTheme: setlistTheme(Brightness.dark),
      home: WorkoutScreen(store: _store, home: _home, day: _home.day),
    );
  }
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

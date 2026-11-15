import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:setlist/day.dart';
import 'package:setlist/fitnotes.dart';
import 'package:setlist/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// The FitNotes tables the importer reads, with the DDL from docs/research.md Q1. The real `settings` table has about 44 columns; only the two the importer reads are here.
const fitNotesSchema = '''
CREATE TABLE Category(_id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, colour INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0);
CREATE TABLE exercise(_id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, category_id INTEGER NOT NULL, exercise_type_id INTEGER NOT NULL DEFAULT 0, notes TEXT, weight_increment INTEGER, default_graph_id INTEGER, default_rest_time INTEGER, weight_unit_id INTEGER NOT NULL DEFAULT 0, is_favourite INTEGER NOT NULL DEFAULT 0);
CREATE TABLE training_log (_id INTEGER PRIMARY KEY AUTOINCREMENT, exercise_id INTEGER NOT NULL, date DATE NOT NULL, metric_weight INTEGER NOT NULL, reps INTEGER NOT NULL, unit INTEGER NOT NULL DEFAULT 0, routine_section_exercise_set_id INTEGER NOT NULL DEFAULT 0, timer_auto_start INTEGER NOT NULL DEFAULT 0, is_personal_record INTEGER NOT NULL DEFAULT 0, is_personal_record_first INTEGER NOT NULL DEFAULT 0, is_complete INTEGER NOT NULL DEFAULT 0, is_pending_update INTEGER NOT NULL DEFAULT 0, distance INTEGER NOT NULL DEFAULT 0, duration_seconds INTEGER NOT NULL DEFAULT 0);
CREATE TABLE Routine(_id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, notes TEXT);
CREATE TABLE Comment (_id INTEGER PRIMARY KEY AUTOINCREMENT, date DATE NOT NULL, owner_type_id INTEGER NOT NULL, owner_id INTEGER NOT NULL, comment TEXT NOT NULL);
CREATE TABLE WorkoutComment (_id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, comment TEXT NOT NULL);
CREATE TABLE WorkoutGroup (_id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, date TEXT NOT NULL, colour INTEGER NOT NULL, routine_section_id INTEGER, auto_jump_enabled INTEGER NOT NULL DEFAULT 1, rest_timer_auto_start_enabled INTEGER NOT NULL DEFAULT 0);
CREATE TABLE BodyWeight (_id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, body_weight_metric REAL NOT NULL, body_fat REAL NOT NULL, comments TEXT);
CREATE TABLE settings (_id INTEGER PRIMARY KEY AUTOINCREMENT, metric INTEGER NOT NULL DEFAULT 1, weight_increment REAL, rest_timer_seconds INTEGER);
''';

final past = Day.parse('2026-11-01');
final noteOnly = Day.parse('2026-11-03');
final cardio = Day.parse('2026-11-05');
final today = Day.parse('2026-11-12');
final ahead = Day.parse('2026-11-13');

const trainingLogRows = 11;

void writeFitNotes(String path) {
  sqlite3.open(path)
    ..execute(fitNotesSchema)
    ..execute('''
INSERT INTO settings (weight_increment, rest_timer_seconds) VALUES (1.0, 60);
INSERT INTO Category (_id, name) VALUES (1, 'Legs'), (2, 'Chest');
INSERT INTO exercise (_id, name, category_id, exercise_type_id, weight_increment, default_rest_time) VALUES
  (1, 'Squat', 1, 0, NULL, NULL),
  (2, 'Bench Press', 2, 0, 0, 0),
  (3, 'squat', 1, 0, 2.5, 90),
  (4, 'Plank', 9, 9, NULL, 45),
  (5, 'Run', 1, 1, NULL, NULL);
INSERT INTO training_log (_id, exercise_id, date, metric_weight, reps, unit, distance, duration_seconds, is_complete, is_pending_update) VALUES
  (10, 2, '2026-11-01', 20.4117, 8, 0, 0, 0, 1, 0),
  (11, 1, '2026-11-01', 100, 5, 0, 0, 0, 1, 0),
  (12, 2, '2026-11-01', 20.4117, 8, 0, 0, 0, 1, 0),
  (13, 1, '2026-11-01', 100, 5, 0, 0, 0, 1, 0),
  (14, 1, '2026-11-01', 100, 5, 0, 0, 0, 0, 1),
  (21, 4, '2026-11-05', 0, 0, 0, 0, 60, 1, 0),
  (20, 5, '2026-11-05', 0, 0, 3, 5.2, 1500, 1, 0),
  (22, 3, '2026-11-05', 60, 5, 0, 0, 0, 1, 0),
  (30, 1, '2026-11-12', 102.5, 5, 0, 0, 0, 1, 0),
  (31, 1, '2026-11-12', 102.5, 5, 0, 0, 0, 0, 1),
  (40, 2, '2026-11-13', 22.5, 8, 0, 0, 0, 0, 1);
INSERT INTO Comment (_id, date, owner_type_id, owner_id, comment) VALUES
  (1, '2026-11-01', 1, 11, 'belt'),
  (2, '2026-11-01', 1, 11, 'knee wraps'),
  (3, '2026-10-01', 1, 999, 'set deleted since'),
  (4, '2026-11-01', 2, 1, 'workout comment, old kind');
INSERT INTO WorkoutComment (date, comment) VALUES ('2026-11-01', 'heavy day'), ('2026-11-01', 'gym busy'), ('2026-11-03', 'rest day');
INSERT INTO WorkoutGroup (name, date, colour) VALUES ('Superset', '2026-11-01', 1);
INSERT INTO Routine (name) VALUES ('Push');
INSERT INTO BodyWeight (date, body_weight_metric, body_fat) VALUES ('2026-11-01', 80, 0), ('2026-11-02', 80.2, 0);
PRAGMA user_version = 22;
''')
    ..close();
}

SetEntry done(int grams, int reps, {String note = ''}) => SetEntry(grams: grams, reps: reps, note: note, status: const Done());

/// A day's slots in workout order, whatever entries hold them.
List<ImportedSlot> slotsOf(ImportedDay day) => [for (final entry in day.entries) ...entry];

/// Every row of every Setlist table, as sorted text.
Map<String, List<String>> dump(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return {
      for (final table in ['exercise', 'workout', 'workout_slot', 'workout_set', 'app_day', 'setting']) table: [for (final row in db.select('SELECT * FROM $table')) '$row']..sort(),
    };
  } finally {
    db.close();
  }
}

void main() {
  late Directory dir;
  late String backupPath;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('setlist_fitnotes_');
    addTearDown(() => dir.deleteSync(recursive: true));
    backupPath = '${dir.path}/FitNotes_Backup.fitnotes';
    dbPath = '${dir.path}/setlist.sqlite';
    writeFitNotes(backupPath);
  });

  ({ImportBatch batch, int trainingLogRows, Map<String, int> leftOut}) read() {
    final backup = sqlite3.open(backupPath, mode: OpenMode.readOnly);
    addTearDown(backup.close);
    return readFitNotes(backup, today: today);
  }

  group('readFitNotes', () {
    test('turns exercises into the batch with the FitNotes globals for NULL and 0, and suffixes a name that collides ignoring case', () {
      final (:batch, trainingLogRows: _, leftOut: _) = read();
      expect(batch.source, 'fitnotes');
      expect((batch.defaultWeightStepGrams, batch.defaultRest), (1000, const Duration(seconds: 60)));
      expect([for (final e in batch.exercises) (e.key, e.name, e.kind, e.category, e.weightStepGrams, e.rest?.inSeconds)], [
        ('1', 'Squat', ExerciseKind.weightReps, 'Legs', 1000, 60),
        ('2', 'Bench Press', ExerciseKind.weightReps, 'Chest', 1000, 60),
        ('3', 'squat (2)', ExerciseKind.weightReps, 'Legs', 2500, 90),
        ('4', 'Plank', ExerciseKind.time, null, 1000, 45),
        ('5', 'Run', ExerciseKind.distanceTime, 'Legs', 1000, 60),
      ]);
    });

    test('orders exercises by smallest set id and sets by id, converts units, and marks every past set done', () {
      final (:batch, :trainingLogRows, leftOut: _) = read();
      expect(trainingLogRows, 11);
      final days = {for (final d in batch.days) d.day: d};
      expect(days.keys, [past, noteOnly, cardio, today, ahead]);

      expect(days[past]!.note, 'heavy day\ngym busy');
      expect([for (final s in slotsOf(days[past]!)) s.exerciseKey], ['2', '1']);
      expect(slotsOf(days[past]!)[0].sets, [done(20412, 8), done(20412, 8)]);
      expect(slotsOf(days[past]!)[1].sets, [done(100000, 5, note: 'belt / knee wraps'), done(100000, 5), done(100000, 5)], reason: 'the never-ticked placeholder is history now');

      expect((days[noteOnly]!.note, slotsOf(days[noteOnly]!).length), ('rest day', 0));

      expect([for (final s in slotsOf(days[cardio]!)) s.exerciseKey], ['5', '4', '3']);
      expect(slotsOf(days[cardio]!)[0].sets, [const SetEntry(metres: 5200, seconds: 1500, status: Done())]);

      expect(slotsOf(days[today]!).single.sets, [done(102500, 5), const SetEntry(grams: 102500, reps: 5)]);
      expect(slotsOf(days[ahead]!).single.sets, [const SetEntry(grams: 22500, reps: 8)]);
    });

    test('counts what it leaves out, including comments whose set is gone', () {
      final (batch: _, trainingLogRows: _, :leftOut) = read();
      expect(leftOut, {'superset groups': 1, 'routines': 1, 'body weight entries': 2, 'comments on deleted sets': 1, 'other comments': 1});
    });

    test('takes today from the clock by default', () {
      final backup = sqlite3.open(backupPath, mode: OpenMode.readOnly);
      addTearDown(backup.close);
      final ahead = readFitNotes(backup).batch.days.last;
      expect(slotsOf(ahead).single.sets.single.isDone, Day.of(DateTime.now()).iso.compareTo('2026-11-13') > 0);
    });
  });

  group('importFitNotes', () {
    test('writes one set per training_log row, and a second run writes the same rows', () async {
      final first = await importFitNotes(backupPath: backupPath, dbPath: dbPath);
      expect(first.trainingLogRows, trainingLogRows);
      expect(first.written.setsWritten, first.trainingLogRows);
      expect((first.written.exercisesCreated, first.written.daysWritten), (5, 5));
      final after = dump(dbPath);
      expect(after['workout_set'], hasLength(trainingLogRows));
      expect(after['setting'], ['{key: default_rest_s, value: 60}', '{key: default_weight_step_g, value: 1000}']);

      final second = await importFitNotes(backupPath: backupPath, dbPath: dbPath);
      expect(dump(dbPath), after);
      expect((second.written.exercisesCreated, second.written.setsWritten), (0, trainingLogRows));
    });

    test('keeps a copy of the Setlist database from before each import', () async {
      final store = Store.open(dbPath);
      final mine = store.createExercise(name: 'Deadlift', kind: ExerciseKind.weightReps);
      store.close();
      await importFitNotes(backupPath: backupPath, dbPath: dbPath);
      final copies = dir.listSync().where((f) => f.path.contains('.before-import-')).toList();
      expect(copies, hasLength(1));
      final before = Store.open(copies.single.path);
      addTearDown(before.close);
      expect(before.exercises(), [mine]);
    });

    test('skips a day the lifter saved in Setlist', () async {
      await importFitNotes(backupPath: backupPath, dbPath: dbPath);
      final store = Store.open(dbPath);
      addTearDown(store.close);
      final squat = store.loadDay(past).slots[1].exercise;
      final edited = Workout(day: past, entries: [Slot(squat, [done(110000, 3)])]);
      store.saveDay(edited);

      final again = await importFitNotes(backupPath: backupPath, dbPath: dbPath);
      expect(again.written.skippedDays, [past]);
      expect(again.written.setsWritten, trainingLogRows - 5);
      expect(store.loadDay(past), edited);
    });

    test('refuses a file that is not a FitNotes backup before writing anything', () async {
      final zip = File('${dir.path}/FitNotes_Automatic_Backup.zip')..writeAsBytesSync([0x50, 0x4b, 0x03, 0x04, ...List.filled(200, 0)]);
      final old = '${dir.path}/old.fitnotes';
      sqlite3.open(old)
        ..execute('CREATE TABLE training_log (_id INTEGER PRIMARY KEY); PRAGMA user_version = 21;')
        ..close();
      final setlist = '${dir.path}/other-setlist.sqlite';
      Store.open(setlist).close();

      for (final (path, says) in [(zip.path, 'unzip it first'), (setlist, 'not a FitNotes backup'), (old, 'version 21'), ('${dir.path}/missing.fitnotes', 'not a FitNotes backup')]) {
        await expectLater(importFitNotes(backupPath: path, dbPath: dbPath), throwsA(isA<FitNotesFormatError>().having((e) => e.message, 'message', contains(says))), reason: path);
      }
      expect(File(dbPath).existsSync(), isFalse);
    });
  });

  final realBackup = Platform.environment['SETLIST_FITNOTES_BACKUP'];
  test('the real backup imports one set per training_log row', () async {
    final backup = sqlite3.open(realBackup!, mode: OpenMode.readOnly);
    addTearDown(backup.close);
    int count(String sql) => backup.select(sql).single.values.single as int;
    final rows = count('SELECT COUNT(*) FROM training_log');
    final dates = count('SELECT COUNT(*) FROM (SELECT date FROM training_log UNION SELECT date FROM WorkoutComment)');

    final first = await importFitNotes(backupPath: realBackup, dbPath: dbPath);
    expect(first.trainingLogRows, rows);
    expect(first.written.setsWritten, rows);
    expect(first.written.daysWritten, dates);

    final expected = <String>[];
    final rank = <String, int>{};
    for (final r in backup.select('SELECT exercise_id, date, metric_weight, reps FROM training_log ORDER BY date, _id')) {
      final slot = '${r['date']} fitnotes:${r['exercise_id']}';
      final index = rank[slot] = (rank[slot] ?? -1) + 1;
      expected.add('$slot $index ${((r['metric_weight'] as num) * 1000).round()} ${r['reps']}');
    }
    final setlist = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    addTearDown(setlist.close);
    final actual = [for (final r in setlist.select('SELECT s.day, e.import_key, s.set_index, s.weight_g, s.reps FROM workout_set s JOIN exercise e ON e.id = s.exercise_id')) '${r['day']} ${r['import_key']} ${r['set_index']} ${r['weight_g']} ${r['reps']}'];
    final unmatched = expected.toSet().difference(actual.toSet()).length + actual.toSet().difference(expected.toSet()).length;
    expect((actual.length, actual.toSet().length, unmatched), (rows, rows, 0), reason: 'every training_log row maps to exactly one set');
    final notes = setlist.select("SELECT COUNT(*) AS n FROM workout_set WHERE note != ''").single['n'];

    final after = dump(dbPath);
    final second = await importFitNotes(backupPath: realBackup, dbPath: dbPath);
    expect(dump(dbPath), after, reason: 'a second import writes nothing new');
    expect(second.written.exercisesCreated, 0);

    // Counts only: the backup holds personal data, so nothing from its rows is printed.
    // ignore: avoid_print
    print('real backup: training_log rows $rows, sets written ${first.written.setsWritten}, days ${first.written.daysWritten}, exercises created ${first.written.exercisesCreated}, sets with a note $notes, left out ${first.leftOut}, second run created ${second.written.exercisesCreated} exercises and changed nothing');
  }, skip: realBackup != null && File(realBackup).existsSync() ? false : 'set SETLIST_FITNOTES_BACKUP to a .fitnotes file');
}

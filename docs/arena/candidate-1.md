# Setlist v1, candidate 1: natural keys, one reducer, whole-day replace

## Problem

Setlist replaces FitNotes for one lifter. The product contract in `docs/design.md` already fixes the aggregate. A day holds ordered slots, a slot holds ordered sets, and every operation is a pure function from `Workout` to `Workout`. The open part is how identity, focus, undo, the rest timer, persistence and the FitNotes import fit around that aggregate without the screen growing its own copy of the rules.

The design honors these constraints from the task and from `docs/decisions.tsv` and `docs/research.md` as of 2026-11-12:

- One workout per calendar day, an exercise at most once per day, kg only.
- Synchronous `package:sqlite3`, no code generation, no state-management package without a defence.
- Exercise kind is a table of FitNotes' ten measure combinations (weight, reps, distance, time), not three kinds.
- The rest countdown survives a locked screen through an ongoing notification and an exact alarm, because a Dart timer stops when the CPU sleeps.
- The import reads sets in `_id` order, orders exercises by smallest set `_id`, takes `metric_weight` as kg, converts distance by `training_log.unit`, skips routines and supersets and reports their counts. It must be safe to run twice, and on a fresh database it writes one set per `training_log` row.

## Usage (caller's view)

`lib/day.dart` is the whole domain and imports only `dart:core`. Open a day with `DayState.open(store.loadDay(day))`. Change it only with `reduce(state, command)`. Save `state.workout` with `store.saveDay` whenever `reduce` hands back a different `Workout` instance. A set is addressed by `(exercise: id, index: i)`. The rest countdown is `workout.restAt(now)` and is never stored.

The workout screen's one mutation path (`lib/workout_screen.dart`):

```dart
void _dispatch(Command command) {
  final before = _state;
  final after = reduce(before, command);
  setState(() => _state = after);
  if (!identical(after.workout, before.workout)) {
    _persist(after.workout);                 // store.saveDay + alarm.show(workout.restAt(now))
    final label = _undoLabel(command);       // exhaustive switch, no wildcard
    _undoTo = label == null ? null : before;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (label != null) {
      messenger.showSnackBar(SnackBar(content: Text(label), action: SnackBarAction(label: 'Undo', onPressed: _undo)));
    }
    if (command is LogSet && after.workout.slotOf(command.ref.exercise)!.finished) _expanded.remove(command.ref.exercise);
  }
  final focus = after.focus;
  if (focus != null && focus.exercise != before.focus?.exercise) _reveal(focus.exercise);
}
```

The docked panel's steppers and Log button:

```dart
for (final field in slot.exercise.kind.fields)
  _Stepper(
    field: field,
    value: field.read(set),
    onStep: (up) => onCommand(SetField(ref, field, field.stepped(slot.exercise, field.read(set), up: up))),
    onTyped: (value) => onCommand(SetField(ref, field, value)),   // once, on dialog confirm
  ),
if (rest != null) _RestCountdown(rest: rest),                    // rest = state.workout.restAt(DateTime.now())
FilledButton(onPressed: () => onCommand(LogSet(ref, at: DateTime.now())), child: Text(set.isDone ? 'Next set' : 'Log set')),
```

A row tap, a row's check circle, and a card drag:

```dart
onTap: () => onCommand(FocusSet((exercise: id, index: i))),
onCheck: () => onCommand(slot.sets[i].isDone ? UnlogSet((exercise: id, index: i)) : LogSet((exercise: id, index: i), at: DateTime.now())),

ReorderableListView.builder(
  buildDefaultDragHandles: false,
  onReorder: (from, to) => _dispatch(MoveExercise(from, to > from ? to - 1 : to)),
  ...
leading: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
```

The exercise picker and the previous-session lookup:

```dart
final picked = await pickExercise(context, widget.store, inDay: {for (final s in _state.workout.slots) s.exercise.id});
if (picked == null || !mounted) return;
_dispatch(AddExercise(picked, lastSession: _lastTimeOf(picked.id)));   // _lastTimeOf caches store.lastSession(id, before: day)
```

The history screen and the import:

```dart
final page = widget.store.recentWorkouts(before: _days.isEmpty ? null : _days.last.day, limit: 30);
subtitle: Text(w.slots.map((s) => s.exercise.name).join(', ')),
trailing: Text('${w.summary.doneSets} sets'),

final outcome = await importFitNotes(backupPath: copy.path, dbPath: widget.store.path!);
// outcome.trainingLogRows == outcome.written.setsWritten on a fresh database
```

Unit tests of the rules (`test/day_test.dart`):

```dart
test('one plus tap on set 1 turns a copied 3 x 5 at 100 kg into 3 x 5 at 102.5 kg', () {
  final s = open([Slot(squat, [kg(100, 5), kg(100, 5), kg(100, 5)])]);
  final next = reduce(s, SetField(ref(squat, 0), Field.weight, Field.weight.stepped(squat, 100000, up: true)));
  expect(weights(next, squat), [102.5, 102.5, 102.5]);
});

test('an exercise skipped earlier comes back next', () {
  var s = open([Slot(squat, [kg(100, 5)]), Slot(bench, [kg(80, 5)])]);
  s = reduce(s, FocusSet(ref(bench, 0)));
  s = reduce(s, LogSet(ref(bench, 0), at: at));
  expect(s.focus, ref(squat, 0));
});
```

## Shape

### Data structures

- `Day` (an extension type over `YYYY-MM-DD`) and `ExerciseId` (over `int`) brand the two keys, per type-system-discipline. `Day.parse` is the only text constructor and rejects 2026-02-30.
- `SetRef = ({ExerciseId exercise, int index})` is a natural key. An exercise appears at most once per day, so the exercise id is the slot's identity. Dragging a card never invalidates the focus or a row callback, and neither the aggregate nor the tables need synthetic slot or set ids.
- `SetEntry` holds four integer measures in base units (grams, reps, metres, seconds), a `warmup` flag, and a sealed `SetStatus` of `Planned` or `Done(at)`. Integers make the cascade's equality exact. `Done.at` is nullable because a FitNotes backup keeps no time per set, and the sealed type keeps a planned set from carrying a time.
- `Field` is an enhanced enum that owns `read`, `write`, `stepped`, `format` and `parse` for one measure. `ExerciseKind` is a ten-row table from kind to its ordered `List<Field>`. The panel and the rows loop over `kind.fields`, so a kind is one table row and no widget branches on kind, per model-the-domain. The units decision lives only in `Field`.
- `Slot` throws on an empty set list. `Workout` throws on a duplicate exercise. The store and the importer can only build days through these constructors, so no path produces an invalid day.
- `DayState(workout, focus)` has a private constructor. Only `DayState.open` and `reduce` build one, and both keep `focus` pointing at a set that exists. Null focus means the panel shows the summary.
- `Command` is a sealed class with thirteen subtypes. `reduce` switches over it exhaustively, and so does the screen's `_undoLabel`, so a new command fails to compile until both decide what it does, per encode-lessons-in-structure.

### Derived, not stored

- Focus is the only screen state that the workout cannot derive. It lives in `DayState`, so undo restores it with the workout.
- The rest countdown is `Workout.restAt(now)`, computed from the latest `Done.at` plus that exercise's rest. Undo of a log, an app restart and an edit during rest need no timer state, and `RestAlarm.show(rest)` is an idempotent reconcile the screen calls after every change, per make-operations-idempotent.
- Card collapse is `slot.finished && !expanded && focus not in it`, from a small `Set<ExerciseId>` of cards the lifter opened by hand.
- "Last time" is `store.lastSession(id, before: day)`, cached per screen. The same list is the plan that `AddExercise` copies, so a freshly added set's muted text is the set it was copied from.

### Module map

| File | Owns | Imports |
| --- | --- | --- |
| `lib/day.dart` | Value types, the `Field` and `ExerciseKind` tables, `DayState`, `Command`, `reduce`, and the private cascade, focus, add, copy, remove and move rules | `dart:core` only |
| `lib/store.dart` | Schema, migrations, every SQL statement, whole-day save, previous-session lookup, history paging, exercise catalog, import policy, and the `ImportBatch` boundary types | `sqlite3`, `day.dart` |
| `lib/fitnotes.dart` | FitNotes tables and conventions, `readFitNotes` (rows to `ImportBatch`), `importFitNotes` (isolate, safety copy, `Store.importBatch`) | `sqlite3`, `day.dart`, `store.dart` |
| `lib/rest_alarm.dart` | The Android notification and exact alarm behind `RestAlarm.show(Rest?)` | `day.dart` |
| `lib/workout_screen.dart` | The live day: `_dispatch`, undo, save retry, alarm sync, the list, cards, rows, the panel | Flutter, `day.dart`, `store.dart`, `rest_alarm.dart`, `exercise_picker.dart`, `history_screen.dart` |
| `lib/history_screen.dart` | Paged past days and the import action | Flutter, `file_picker`, `path_provider`, `day.dart`, `store.dart`, `fitnotes.dart`, `rest_alarm.dart`, `workout_screen.dart` |
| `lib/exercise_picker.dart` | `pickExercise` and the create dialog | Flutter, `day.dart`, `store.dart` |
| `lib/main.dart` | Opens the database file and shows today | Flutter, `path_provider`, `day.dart`, `store.dart`, `rest_alarm.dart`, `workout_screen.dart` |

Flow traces, each within three files:

- Log a set: `workout_screen.dart` (`LogSet`) to `day.dart` (`_log` and focus) to `store.dart` (`saveDay`).
- Edit set 1 and cascade: `workout_screen.dart` (`SetField`) to `day.dart` (`_cascade`) to `store.dart`.
- Copy a past day: `workout_screen.dart` (`_recent`, `CopyDay`) to `day.dart` (`_copyDay`) to `store.dart`.
- Import: `history_screen.dart` to `fitnotes.dart` (`readFitNotes`) to `store.dart` (`importBatch`).
- Rest alarm: `workout_screen.dart` to `day.dart` (`restAt`) to `rest_alarm.dart`.
- Add exercise touches four files only if you open `exercise_picker.dart`. Its contract is one function returning `Exercise?`, so the flow reads without it.

### State management

`_WorkoutScreenState` owns the live `DayState`. The undo, save and alarm glue is twenty lines in `_dispatch`. A `ChangeNotifier` controller would have exactly one caller, so it would be a layer that hides nothing, per minimize-reader-load. No other screen shares the live day. History and the picker read fresh from the store and the history screen reloads when a pushed day screen pops. The store and the alarm are passed by constructor.

Undo is single-level and exact. The snackbar's Undo restores the `DayState` from before the change it names. Any later change to the workout clears the offer and hides the snackbar, so Undo never reverts more than its label says. Focus taps keep the offer, since restoring would only move the focus back.

### Persistence

`schema.sql` is the v1 schema. Weight is integer grams, distance integer metres, time integer seconds, `logged_at` unix milliseconds, days `TEXT 'YYYY-MM-DD'`.

- `workout(day)`, `workout_slot(day, exercise_id)` and `workout_set(day, exercise_id, set_index)` use natural composite primary keys and `WITHOUT ROWID`. A day's rows are one contiguous key range, which is exactly what `loadDay` reads and `saveDay` deletes.
- `workout_slot`'s primary key is the "an exercise at most once per day" rule, enforced by the database as well as by `Workout`'s constructor. `UNIQUE (day, position)` catches a save bug that would write two cards at one position.
- `set_done_by_exercise ON workout_set (exercise_id, day, set_index) WHERE done = 1` serves the previous-session lookup and the picker's "most recently done first" order. It is partial, so planned sets copied ahead never count as a session. Measured with `EXPLAIN QUERY PLAN` on SQLite 3.46 against `schema.sql`, the `MAX(day)` subquery is one search on this covering index, and the outer query reads that day's sets as a primary-key range already in set order, with no scan and no sort.
- `exercise.name` is unique ignoring case. `exercise.import_key` (`'fitnotes:42'`) lets a second import find an exercise after the lifter renamed it.
- `app_day(day)` records every day the app has saved, including days it later emptied and deleted.

`saveDay` deletes the day's sets, slots and workout row and inserts the current ones, all in one `BEGIN IMMEDIATE` transaction. The screen calls it only when `reduce` returns a new `Workout` instance. Saving twice leaves the same rows, and after a failed save the next successful one converges with no repair step. WAL with `synchronous = NORMAL` keeps a commit on every stepper tap cheap.

Migrations are an append-only `List<String>` in `store.dart`. Entry i moves `PRAGMA user_version` from i to i + 1, and each step runs in one transaction that includes the version bump. `user_version` lives in the database header and rolls back with the step, so a crash mid-migration reruns that step on the next launch. The runner turns foreign keys off outside the transaction (SQLite ignores the pragma inside one), checks `PRAGMA foreign_key_check` before commit, and refuses a file whose version is newer than the build. A golden test migrates an empty database and compares `sqlite_master` with a database built from `schema.sql`, so the migration list and the schema file cannot drift apart unnoticed.

### The import boundary

The importer produces domain values and calls one method:

```dart
ImportReport Store.importBatch(ImportBatch batch)

ImportBatch(source: 'fitnotes', exercises: [ImportedExercise(key: '42', name, kind, category, weightStepGrams, rest)], days: [ImportedDay(day, note, slots: [(exerciseKey: '42', sets: [SetEntry(..., status: const Done())])])])
```

No FitNotes row and no Setlist id crosses the boundary. `readFitNotes` is the pure half (rows in, batch out) and never writes. `importFitNotes` runs it on a background isolate with its own connection, takes a `VACUUM INTO` safety copy, then calls `importBatch` in one transaction.

Running it twice is safe because ownership is explicit, per separate-before-serializing-shared-state. The app and the importer both write days, so each day has one owner. A day in `app_day` belongs to the app forever and the importer skips it and lists it in the report. Any other day belongs to the importer, which replaces it wholesale, so a newer backup refreshes it. Exercises match by import key, then by name ignoring case, then get created, and a matched exercise keeps the lifter's own name, increment and rest. A second run therefore finds every key, writes the same rows, and creates nothing. A crash rolls the whole run back.

### Interface depth

`reduce` plus thirteen command types hides the cascade, both focus rules, the once-per-day rule, the never-empty-slot rule and the focus repair after remove and reorder. The screen never learns any of them, and the tests drive the same entry point. `Store` has ten methods and two constructors, and hides the schema, the migrations, the ownership ledger, the exercise matching and every query. Its public types are the domain types, the five import types and three exception types. `RestAlarm` is one method. What stays exposed on purpose is `SetRef` (rows must name their set) and `Field` (the panel must loop over fields).

### What it does not do

No routines, templates, supersets, charts, body weight, units other than kg, or sync. No set comments in v1; the importer counts the ones it drops. No multi-level undo. No async database layer. No persisted focus.

## Synthesis decision

Left for arena.

## Tradeoffs accepted

- We accept rewriting a whole day (about 30 rows) on every stepper tap in exchange for a save that is idempotent, needs no diffing, and makes undo a re-save of the previous value.
- We accept synchronous SQLite on the UI isolate for everything but the import, in exchange for no async plumbing in the screen. A day is tens of rows.
- We accept `synchronous = NORMAL`, where a power loss (not an app crash) can drop the last few commits, in exchange for no fsync per tap.
- We accept single-level undo that only log, remove and copy offer, in exchange for an undo that always does exactly what its snackbar says.
- We accept that a slot holds a copy of its `Exercise`, refreshed by `UpdateExercise`, in exchange for widgets that read `slot.exercise.name` with no catalog lookup.
- We accept unused measure fields stored as 0, as FitNotes does, in exchange for one set type and one cascade for all ten kinds. Changing an exercise's kind later shows whatever those fields held.
- We accept that the cascade is not invertible. With planned sets at 100, 100 and 102.5, one plus on set 1 gives 102.5 everywhere, and one minus then gives 100 everywhere. The equality rule is the contract.
- We accept that `app_day` only grows, in exchange for an import that can never overwrite or resurrect a day the lifter touched.
- We accept no `CHECK` on `exercise.kind`, in exchange for adding a kind without a table rebuild. The store parses the column and rejects unknown values.

## Alternatives considered

- **Row-level writes with synthetic set ids.** Each edit would `UPDATE` one row. The cascade becomes several writes, a reorder rewrites positions, undo needs inverse SQL, and memory and disk can disagree after a partial failure. The caller would have to know which rows a command touched. Whole-day replace hides all of that behind one call.
- **A controller class or a state package (ChangeNotifier, Riverpod, Bloc).** It adds a layer with one caller and a dependency, and hides nothing the screen's `State` does not already hide. It would earn its place if a second screen edited the live day.
- **Methods on `Workout` called straight from widgets, no `Command` type.** Each handler would repeat the save, undo and focus glue, there would be no single list of operations, and the undo labels would lose their exhaustive switch.
- **A sealed set type per kind (`WeightRepsSet`, `TimeSet`, ...).** The cascade and the stepper would branch per kind, changing a kind would need conversions, and the importer's ten FitNotes types would map onto many classes. One four-field set with a kind table keeps one code path.
- **Imported history in separate read-only tables, merged by a view.** It also separates the two writers, but every query becomes a union and editing an imported day needs copy-on-write. The `app_day` ledger gives the same ownership with one set of tables.
- **A timer state for rest (start time plus exercise) kept next to focus.** It would need clearing on undo and restoring on restart. Deriving it from `Done.at` removes the state.

## Open questions and risks

- Should checking the circle on a row the panel is not on move the focus? The sketch says no. Focus moves only when the logged set held it (or no planned set held it), so ticking a forgotten bench set mid-squat keeps the panel on squat. `docs/design.md` does not distinguish the two cases.
- Should adding an exercise mid-workout take the focus? The sketch focuses its first set.
- Should the countdown skip warm-ups, or skip after an exercise's last set as StrongLifts does? The sketch rests after every logged set until no planned set remains.
- Copy a day copies every set, including sets left planned on the source day, as `docs/design.md` says. Should skipped sets be dropped instead?
- Are FitNotes rows with `is_pending_update = 1` planned placeholders? The sketch imports them as planned. Either way each row becomes one set, so the count check holds.
- What unit is `exercise.weight_increment` in a real backup? The sketch defaults to 2.5 kg when unsure.
- Should distance show as km or m, and should distance and time steps be per exercise? The sketch uses fixed 100 m and 5 s steps.
- Should set comments come over in v1? Each import counts the ones it drops, and a later re-import fills untouched days once a column exists.
- Typing a value must commit once. Applying each keystroke runs the cascade on every prefix, so typing 10 over a 5 passes through 1 and captures any later planned set that really held 1. `_Stepper.onTyped` documents this.
- Android 14 restricts exact alarms (`SCHEDULE_EXACT_ALARM` needs user consent, `USE_EXACT_ALARM` needs Play policy fit). If neither is available, the ongoing notification's chronometer still counts down and only the vibration at zero is lost.
- The `file_picker` result on Android can be a content URI with no path. The history screen copies the bytes into the cache directory before the import opens it.

## Next implementation step

Fill in `lib/day.dart` against `test/day_test.dart` first, since every other file depends on its types and rules, and the tests run on the VPS with no device.

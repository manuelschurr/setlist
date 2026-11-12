# Setlist v1 code structure, candidate 2

## Problem

Setlist replaces FitNotes for one lifter, offline, with years of history in one SQLite file. The contract in `docs/design.md` fixes the day as the aggregate, every operation as a pure function of it, and a whole-day replace on save. Three things make the shape non-obvious. The focus is screen state, but the rules move it (on open, on log, after a skipped exercise), and undo has to restore it. Undo is a snackbar, so it arrives seconds later, often after the lifter has already tapped a stepper on the next set. The history outlives the code, so the schema must reject bad rows on its own, and the FitNotes import must converge when run twice or after a crash. Constraints carried in: package `sqlite3` is synchronous and bundled, there is no codegen, Dart 3.12 gives sealed classes, records, patterns and extension types, and an exercise appears at most once per day.

## Usage (caller's view)

Quickstart. One controller per open day. Widgets read `state` and change it only through `apply`, which runs the rules, saves the day and returns the undo edit.

```dart
final store = Store.open('${dir.path}/setlist.db');      // migrates on open
final day = DayController(store, Day.of(DateTime.now()));
final undo = day.apply(LogSet(day.state.focus!));         // logs, moves focus, saves
day.apply(StepValue(day.state.focus!, SetField.weight, 1)); // +2.5 kg, cascades, saves
day.apply(undo!);                                         // un-logs that set only, keeps the tap
```

Workout screen (from `lib/day_screen.dart`). The list, a row tap, a drag, the panel and the snackbar:

```dart
ReorderableListView(
  buildDefaultDragHandles: false,
  onReorder: (from, to) => _day.apply(MoveExercise(slots[from].exercise.id, to > from ? to - 1 : to)),
  children: [
    for (final (index, slot) in slots.indexed)
      _SlotCard(
        key: _cardKeys.putIfAbsent(slot.exercise.id, GlobalKey.new),
        slot: slot, index: index, focus: state.focus,
        lastTime: _day.lastTime(slot),                       // aligned "last time" per row
        collapsed: slot.isDone && !_expanded.contains(slot.exercise.id),
        onTapSet: (i) => _day.apply(FocusSet((exercise: slot.exercise.id, index: i))),
        onCheck: (i) => _check((exercise: slot.exercise.id, index: i)),
        ...
      ),
  ],
)

// _Panel: one stepper per field the exercise kind uses
for (final field in exercise.kind.fields)
  _Stepper(
    field: field, value: set[field],
    onStep: (steps) => day.apply(StepValue(ref, field, steps)),
    onTyped: (value) => day.apply(SetValue(ref, field, value)),
  ),
FilledButton(onPressed: set.isDone ? null : () => onLog(ref), child: const Text('Log set')),

void _log(SetRef ref) {
  final undo = _day.apply(LogSet(ref));
  if (undo == null) return;
  ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(
    content: Text('Set ${ref.index + 1} logged'),
    action: SnackBarAction(label: 'Undo', onPressed: () => _day.apply(undo))));
}

// _RestCountdown: no timer state in the model, only a ticker that rereads
final left = widget.day.restLeft();   // derived from the last log time plus the exercise's rest
```

History and the exercise picker:

```dart
final page = store.workouts(before: _days.lastOrNull?.day, limit: 30);   // full Workouts, newest first
final recent = store.workouts(before: day, limit: 5);                     // the empty day's Copy list
_day.apply(CopyWorkout(recent.first));

final exercise = await Navigator.push<Exercise>(context, MaterialPageRoute(builder: (_) => ExercisePicker(store: store, inDay: ids)));
_day.reload();                       // every pushed route may have changed data underneath
if (exercise != null) { _day.apply(AddExercise(exercise)); _scrollTo(exercise.id); }   // no-op if present, scroll either way

final sections = pickerSections(store.catalog(), query);   // pure, recent first then by category
```

Unit tests of the rules (from `test/workout_test.dart`), with no widget and no database:

```dart
test('one tap on set 1 turns a copied 3 x 5 at 100 kg into 3 x 5 at 102.5 kg', () {
  final s = open([Slot(squat, [planned(100, 5), planned(100, 5), planned(100, 5)])]);
  expect(kg(apply(s, StepValue(at(squat, 0), SetField.weight, 1)).state, squat), [102.5, 102.5, 102.5]);
});

test('logging the last set of an exercise jumps to the first planned set from the top', () {
  final s = apply(open([Slot(bench, [planned(80, 5)]), Slot(squat, [planned(100, 5)])]), FocusSet(at(squat, 0))).state;
  expect(apply(s, LogSet(at(squat, 0))).state.focus, at(bench, 0));
});

test('undoing a log after a stepper tap on the next set keeps the tap', () {
  final logged = apply(s, LogSet(at(squat, 0)));
  final stepped = apply(logged.state, StepValue(at(squat, 1), SetField.weight, 1)).state;
  expect(kg(apply(stepped, logged.undo!).state, squat), [100, 102.5]);
});
```

## Shape

Module map. Seven files in a flat `lib/`, each owning one body of knowledge. Every flow traces through at most three of them.

| File | Owns | Imports |
| --- | --- | --- |
| `workout.dart` | `Day`, `ExerciseId`, `Exercise`, `ExerciseKind`, `SetField`, `SetEntry`, `SetStatus`, `Slot`, `Workout`, `SetRef`, `DayState`, the sealed `Edit` family, `reduce`, and the derived reads `alignLastTime`, `restRemaining`, `summarize` | nothing |
| `store.dart` | the schema and its migrations, `Store` (day load and replace, history pages, previous session, catalog, exercises, `importBatch`), the `ImportBatch` boundary types, store errors | `sqlite3`, `workout` |
| `day_screen.dart` | `DayController` and `WorkoutScreen` with its private card, row, panel, stepper, countdown and recent-workouts widgets | Flutter, `workout`, `store`, picker, history |
| `history_screen.dart` | the history list and the import action | Flutter, `file_picker`, `workout`, `store`, `fitnotes`, `day_screen` |
| `exercise_picker.dart` | `ExercisePicker` and the pure `pickerSections` | Flutter, `workout`, `store` |
| `fitnotes.dart` | `readFitNotes` and `importFitNotes` on an isolate. The only file that knows FitNotes | `sqlite3`, `workout`, `store` |
| `main.dart` | opening the store and the app shell | Flutter, `path_provider` |

Flow traces. Log set goes `day_screen` (panel, `_log`, `DayController.apply`) then `workout` (`reduce`, `_log`, `_focusAfterLog`) then `store` (`saveDay`). A stepper tap and a drag take the same three files. Last-time text goes `day_screen` (`lastTime`) to `store` (`lastSession`) and `workout` (`alignLastTime`). Import goes `history_screen` to `fitnotes` to `store`.

Data structures first (per foundational-thinking).

1. Natural keys all the way down. An exercise is unique within a day, so a slot is addressed by its `ExerciseId` and a set by `SetRef = ({ExerciseId exercise, int index})`, a record with free value equality. Moving a card changes no ref, so the focus survives a drag with no fix-up code. Nothing below the exercise has a synthetic id, in memory or on disk, because whole-day replace never needs to find a row again. The SQLite keys mirror the aggregate: `workout(day)`, `slot(day, exercise_id)`, `set_entry(day, exercise_id, position)`.
2. Integer grams. `SetEntry` holds `weightGrams`, `reps` and `seconds` as ints, and `SetField` is an enum whose values index them. The cascade's equality test is exact, a typed 110 equals 100 plus four 2.5 kg taps, and a FitNotes 22.68 kg matches itself after the round trip. One `_cascade` serves all three fields (per type-system-discipline, applied to units rather than to brands).
3. Brands for identities. `Day` and `ExerciseId` are zero-cost extension types, so a position cannot be passed as an exercise and a free string cannot be passed as a day. `Day.parse` rejects `2026-02-30` at whichever boundary read it.
4. `ExerciseKind` carries its `fields` list, so the set row and the panel loop over `kind.fields` and no widget switches on the kind (per model-the-domain). `SetStatus` is sealed `Planned` or `Done(at)`, with `at` null only for imports that kept no time.
5. `DayState` is the workout plus the focus. `DayState.settle` is the only place the focus invariant is enforced. A focus on a set that no longer exists, or a null focus while a set is still planned, moves to the first planned set. Null focus therefore means nothing is planned, which is exactly when the panel shows the summary. Every arm of `reduce` ends in `settle` (per encode-lessons-in-structure).

Edits as data. `Edit` is a sealed family of 15 small classes, one per thing the lifter does. `reduce(DayState, Edit, EditContext)` is the single pure interpreter, an exhaustive switch whose arms call private helpers in the same file. It returns `Applied = ({DayState state, Edit? undo})`. Undo edits are targeted, not snapshots. The undo of `LogSet(ref)` is `UnlogSet(ref, refocus: focusBefore)`, the undo of `RemoveExercises` is `InsertSlots` with the old indexes, the undo of `CopyWorkout` is `RemoveExercises` of what it appended. Applying an undo after an unrelated edit keeps that edit, which is what the snackbar needs, and with nothing in between the round trip returns an equal state, which the tests assert. `EditContext` passes in the clock and the previous-session lookup, so `reduce` is deterministic under test and `AddExercise` needs no second controller method.

The controller is one method deep. `DayController.apply` runs `reduce`, returns early when `reduce` hands back the identical instance (the no-op contract), writes the day with `Store.saveDay` when the workout instance changed, then publishes and notifies. The write happens before the publish, so a failed write leaves memory and disk agreeing. Saving on every edit means no dirty flag, no flush on pause and nothing lost when Android kills the app. `ChangeNotifier` and `ListenableBuilder` are the whole state management, with no package (per laziness-protocol). The public surface is `state`, `apply`, `lastTime`, `restLeft` and `reload`. It hides the rules, persistence, the clock and the previous-session memo.

Derived, not stored. The rest countdown is `restRemaining(workout, now)`, the latest log time plus that exercise's rest, so it survives an app restart and an undo of the log cancels it with no timer state to sync. "Last time" per row is `alignLastTime(slot.sets, lastSession)`, which pairs warm-ups with warm-ups and working sets with working sets by ordinal, so adding a warm-up today does not shift every comparison by one (per experience-first). The session summary and a collapsed card's top set are computed from the slot.

The store is the deep module (per boundary-discipline). Eight operations with domain types in and out hide the SQL, the schema, row parsing, transactions, migrations and import resolution. Rows parse through the validating `Slot` and `Workout` constructors, so a corrupt row fails at load with the day named. Tests use `Store.inMemory()` against real SQLite, so there is no store interface and no fake. The schema in `schema.sql` is three STRICT, WITHOUT ROWID day tables plus `exercise`. The constraints are the second line of defence for years of history: `PRIMARY KEY (day, exercise_id)` on `slot` is the one-exercise-per-day rule, `CHECK (logged_at IS NULL OR done = 1)` rejects a planned set with a log time, and STRICT rejects a text rep count. One partial index, `set_entry (exercise_id, day) WHERE done = 1`, serves the previous-session lookup and the picker's recency, and the day-leading primary keys serve load, replace and history. I ran the schema against SQLite 3.46.1 (measured): a double save leaves the same rows, an emptied day deletes its rows by cascade, the previous-session query skips a day where the exercise was only planned, and its plan is one covering-index seek plus one primary-key seek.

Migrations run on open by `PRAGMA user_version`. `_migrations` is an append-only `List<String>`, and entry `i` takes the file from version `i` to `i + 1`. Each step runs in its own `BEGIN IMMEDIATE` transaction together with its version bump, so a crash leaves the previous version and the next launch reruns that step whole (per make-operations-idempotent). Foreign keys go off before the loop, since the pragma is a no-op inside a transaction and table rebuilds need it off, and each step must pass `PRAGMA foreign_key_check` before it commits. A file from a newer app throws `NewerSchemaError` instead of being touched. Before migrating a file that holds data, the store copies it with `VACUUM INTO '<path>.v<from>.bak'`. I checked in SQLite 3.46.1 that `VACUUM INTO ?` takes a bound path, that a rolled-back step leaves `user_version` unchanged, and that `PRAGMA foreign_keys` cannot change inside a transaction (all measured). The schema text lives only in `store.dart`, so there is no second copy to drift.

The import boundary. An importer produces an `ImportBatch` of plain values keyed by the source's own ids (`ImportedExercise`, `ImportedDay`, `ImportedSlot` holding domain `SetEntry` values, plus a `losses` map of what it could not represent) and calls `Store.importBatch`, which returns an `ImportReport`. Nothing in that API names FitNotes. `importBatch` validates the whole batch first and throws `ImportRejected` before writing. Then, in one transaction, exercises resolve by `source_key` (`fitnotes:42`), else by a case-insensitive name match that claims an unkeyed Setlist exercise, else by insert. Days merge at slot granularity with `ON CONFLICT (day, exercise_id) DO NOTHING`, which is the copy-a-workout rule applied to done sets, so Setlist's own data always wins. The second run resolves every key, inserts nothing and reports zero sets written, and a crash rolls back to before the import. The explicit conflict target matters: `INSERT OR IGNORE` would also swallow a CHECK failure and drop a bad row without a word. `importFitNotes` runs the read and the write on an isolate with its own connection, and the screens reload on return. On an empty database `report.setsWritten == batch.setCount`, which is how the done check compares against the backup's training log row count.

One writer per day (per separate-before-serializing-shared-state). Tapping today in history pops back to the home screen rather than pushing a second controller for the same day. The import only adds slots a day lacks, and every screen reloads when a pushed route returns. So no two actors ever hold the same day open for writing, and nothing needs a lock.

What it deliberately does not do: no repository interfaces, no streams from the database, no diffed saves, no set ids, no snapshot undo stack, no state-management package, and no code generation.

## Synthesis decision

Left for the arena to fill in.

## Tradeoffs accepted

- We accept rewriting the whole day, about 30 rows, on every stepper tap, in exchange for no dirty tracking and nothing lost when the app is killed. The cost on the phone is a guess (single-digit milliseconds with WAL and `synchronous = NORMAL`), not a measurement.
- We accept 15 edit classes in exchange for one `apply`, an exhaustive switch that forces every new edit to decide its undo, and undo values the tests can apply.
- We accept snackbar undo only for log, remove and copy. A stepper tap is reversed by the other stepper button, and typed values by typing again.
- We accept synchronous SQLite on the UI isolate for everything except the import, in exchange for no async plumbing in the controller or the widgets.
- We accept that each `Slot` carries an `Exercise` snapshot, so a rename shows only after `reload`, in exchange for widgets and rules that never look an exercise up.
- We accept that a re-import never corrects a slot an earlier import wrote, in exchange for an import that cannot overwrite the lifter's own edits.
- We accept that `reduce` calls a lookup that hits SQLite through `EditContext.lastSession`. The controller memoizes it per day, and tests pass a map, so the rules stay deterministic.

## Alternatives considered

- Snapshot undo stack, the contract's "undo for free by keeping the previous value". It hides nothing from callers but has the wrong semantics for a snackbar. Undo after an intervening stepper tap either discards the tap or the snackbar has to vanish on every edit. Targeted inverse edits cost one inverse per undoable edit and get the semantics right.
- Pure methods on `Workout` with one controller method per operation. Every controller method would repeat save and notify, 15 pass-through methods in all, and a closure-taking `edit(fn)` cannot carry its inverse as a value the snackbar and the tests can hold.
- A FitNotes-style flat set log, one table with day, slot position and exercise on every set row. One table fewer, but one-exercise-per-day and consistent card order stop being constraints, and a day with only a note needs a second table anyway.
- One JSON document per day. It matches the aggregate perfectly, but the previous-session lookup across years would need an index into the JSON, and the import count check would stop being a `count(*)`.
- Diffed saves with stable set ids. The ids would exist only so the save can diff, and whole-day replace is already idempotent and fast at 30 rows.

## Open questions and risks

- When the lifter records a missed rep by lowering reps on the focused set before logging, the cascade also lowers every later planned set that had the same reps. Is that wanted, or should a reps edit on the set about to be logged leave the later sets alone?
- The rule sends focus to the top of the workout when no planned set follows the logged one in its exercise. If the lifter logs set 3 while set 2 is still planned, should focus go to set 2 first? The sketch follows the literal rule and marks the spot in `_focusAfterLog`.
- Should a row's check circle on a set other than the focused one move the focus? The sketch leaves the focus where it was, so catching up on a forgotten log does not pull the panel away.
- FitNotes stores distance for cardio exercises, and v1 has no distance column. Because a re-import skips slots that already exist, adding a column later would not backfill it. Should `set_entry` carry a nullable `distance_m` from v1, with the importer filling it, even though no v1 screen shows it?
- The schema allows negative weight so assisted exercises from FitNotes import, while the stepper clamps at zero. Should the weight stepper go below zero for assisted exercises?
- A copied day where the lifter skipped exercises keeps its planned sets forever. They never count as "last time", but history shows them. Should a past day drop its planned sets?
- The SQLite file is the only copy of the history once FitNotes is gone. Should v1 ship an "export database" action through the share sheet?
- Risk: `ReorderableListView` builds lazily, so scrolling to an off-screen card needs a `cacheExtent` that covers a whole day, or the card's key has no context yet.
- Risk: the save-per-tap latency is unmeasured on the phone. Time `saveDay` for a 30-set day on the Nord before building the panel.
- Risk: the four Flutter files are not type-checked, because that needs `flutter pub get` and the task ruled out Flutter runs. `workout.dart`, `store.dart`, `fitnotes.dart` and both test files pass `dart analyze` under Dart 3.12.2 with `sqlite3` 3.x (measured, with only unused-element warnings for helpers the TODO bodies will call).

## Next implementation step

Implement `workout.dart`'s types and `reduce` until `test/workout_test.dart` passes under `flutter test` on the VPS, since the rules are pure and need neither the phone nor a database.

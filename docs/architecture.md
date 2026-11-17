# Setlist architecture

This is the code structure for v1. It came out of an arena: two independent design sketches (`docs/arena/candidate-1.md`, `docs/arena/candidate-2.md`) scored by a third reviewer (`docs/arena/judge.md`). Read `docs/design.md` first for what the app must do.

## Synthesis decision

Candidate 1 is the base. Both candidates converged on the same core: a day aggregate changed only through one pure `reduce` over a sealed command family, sets addressed by `(exerciseId, index)` because an exercise appears at most once per day, integer base units so the cascade compares exactly, a rest countdown derived from log times instead of stored, and a whole-day replace on save. Candidate 1 won on fit: it already models FitNotes' ten exercise kinds and distance, keeps `reduce` free of database calls, and its import ownership ledger (`app_day`) refreshes untouched imported days while never overwriting a day the lifter saved. Candidate 2's slot-level merge would resurrect deleted slots and could never backfill a later column.

Grafted from candidate 2:

- One writer per day. From history, tapping today pops back to the home screen instead of pushing a second screen for the same day. The day screen reloads (day, last-time cache, recent list) whenever a pushed route returns or an import finishes.
- `alignLastTime`: the muted "last time" text pairs warm-ups with warm-ups and working sets with working sets by ordinal, so adding a warm-up today does not shift every row.
- STRICT tables, and a `VACUUM INTO '<path>.v<from>.bak'` copy before migrating a file that holds data.
- An index on `workout_slot (exercise_id)`.

Rejected from candidate 2: undo by inverse edits. It needs extra commands that exist only for undo (`InsertSet`, `InsertSlots`). Candidate 1's single-level snapshot undo is kept: the snackbar's Undo restores the state before the change it names, and any later change to the workout hides the offer. The cost is one case: after logging a set and then tapping a stepper within the snackbar's few seconds, Undo is gone, and the lifter unlogs with the row's check circle instead, which works on any set at any time.

## Changes to the candidate 1 sketch

Every implementer checks these off. They come from the judge's defect list, `docs/fitnotes-notes.md` and `docs/decisions.tsv`.

1. **Set note.** `SetEntry.note` (String, default empty), column `workout_set.note TEXT NOT NULL DEFAULT ''`, command `SetSetNote(ref, note)`. Copying a day and adding an exercise from its last session do not copy notes. The row shows a note under the values in small text.
2. **Focus after logging.** Next planned set after the logged one in the same exercise, else the first planned set in that exercise (a set skipped within the exercise), else the first planned set from the top of the workout, else null.
3. **Stale refs.** Every `reduce` arm checks that its ref or exercise exists and returns the state unchanged when it does not. No `!` on lookups that a stale command can reach.
4. **Defaults.** A `setting` table (`key TEXT PRIMARY KEY, value ANY`) holds `default_weight_step_g` and `default_rest_s`, used by `createExercise` when the caller gives none. Built-in fallback 2500 g and 120 s. The FitNotes import writes the FitNotes globals there from `settings.weight_increment` and `settings.rest_timer_seconds`.
5. **FitNotes import rules.** Every set on a day before the import's today imports as done. For today and later, `is_complete` decides done or planned. `weight_increment` and `default_rest_time` that are NULL or 0 become the FitNotes globals. Set comments (`Comment.owner_type_id = 1`) become set notes, several joined with ` / `; comments whose set no longer exists are counted in the report, not imported. Superset groups of logged days become supersets. FitNotes gives a routine's groups an empty date, so `WorkoutGroup.date` tells the two apart, and an exercise in two groups on one day stays in the first. Routines and body weight are counted as left out.
6. **Weight display.** `Field.weight.format` shows kg with at most two decimals and no trailing zeros (20412 g shows as `20.41`, 100000 as `100`, 102500 as `102.5`). `parse` accepts a comma or a dot. Storage and the cascade stay in exact grams.
7. **Schema has one copy.** The migration list in `store.dart` holds the real v1 statements. `docs/schema.sql` is generated from it by a test, or the golden test compares a migrated database's `sqlite_master` with `docs/schema.sql` and fails on any difference.
8. **Failed saves.** Keep candidate 1's `StoreWriteFailed` and the screen's retry.
9. **Keep the screen on** while the app is in the foreground (`FLAG_KEEP_SCREEN_ON` in `MainActivity`), as FitNotes offers.
10. **Data menu.** On the history screen: import a FitNotes backup, export a copy of the Setlist database (`Store.copyTo` then save through the file picker), and restore from such a copy (the one action with a confirmation dialog, because it replaces everything).

## Supersets

Added in 0.3.0, with the rules in `docs/design.md`.

- **Model.** `Workout.entries` holds `Slot` (a plain exercise) and `Superset` (two or more slots) under one sealed `Entry`, and `Workout.slots` is the entries flattened, so code that walks every exercise did not change. `_withGroups` in `day.dart` is the one place where a group of one becomes a plain slot.
- **Focus and panel.** `focusAfterLog` decides both the jump after a log and the panel's "then" line, so the two cannot disagree.
- **Storage.** `workout_slot.joined` marks a slot that is in the same superset as the slot before it, which cannot describe a superset of one or one whose exercises are apart. Migration 2 builds the table again from exact text instead of using ADD COLUMN, because ADD COLUMN splices the column onto the line before it and its result depends on the SQLite version. `test/schema_v1.sql` is the v1 schema the migration test starts from.
- **Drag.** Flutter's `ReorderableListView` moves one row within one flat list, so the screen draws a superset as rows of that list: a header strip, its cards and a footer. Every gap between two rows is then inside one frame or outside all of them, and `layoutAfterDrop` turns a drop into an `Arrange`. Dragging the strip folds the superset's other rows to zero height and keeps them in the list, so the drop indices still count them. They open again with the drop in `onReorderItem`, in `onReorderEnd` when the drop lands where it started (no reorder is reported then), and on a cancelled pointer, which reports neither.
- **Known limit.** A tall, expanded card dragged a short way up from right below a frame does not land as its last exercise. Once the gap opens above the card, the footer shifts down by the card's height and the gap flips back. Folding a card to its header as soon as it is touched would cure this for every drag. It is not built.

## Equipment

Added after 0.4.0, with the rules in `docs/design.md`.

- **Model.** `Equipment` in `day.dart` is sealed: `NoEquipment`, `Barbell(barGrams)`, `DumbbellPair` and `OneDumbbell`, so a bar weight on a dumbbell exercise cannot be built and every switch over it is exhaustive. `Equipment.choices` is the one hand-written list of the subclasses, read by the dialog and by `Equipment.named`, the parser of a stored row, and a test checks it against a switch. `Exercise` takes the equipment as a required parameter with no default, so the edit dialog's rebuild and every other construction must name it. Its `equipment` getter reads none for a kind without a weight, so no widget checks the kind, and `==` includes it, so an edit of only the equipment refreshes the open day.
- **Breakdown.** `Equipment.breakdown(grams)` owns both the arithmetic and the words of the panel's line. It is null for equipment that never splits a total, whatever the weight, so the panel reserves the line by equipment, and an empty string for a total of 0 or less. Halving by truncation is exact for display, because the weight format rounds to 10 g with halves up.
- **Storage.** Migration 3 adds `exercise.equipment` (the subclass name, default `none`) and `exercise.bar_g`, with a CHECK that a bar weight is set exactly for a barbell. Like migration 2 it builds the table again from exact text through a temporary copy that keeps every `id`, so `workout_slot` still points at the same rows. `test/schema_v2.sql` is the v2 schema the migration test starts from. The import writes neither column and never updates a matched exercise beyond its key, so a re-import keeps the lifter's equipment.
- **Drawing.** `EquipmentMark` paints the glyph as a sibling before the value text, never a span inside it, so the value stays one exact string for the screen and its tests.

## Module map

| File | Owns |
| --- | --- |
| `lib/day.dart` | Value types, the `Field` and `ExerciseKind` tables, the day's entries (`Slot` and `Superset`), `DayState`, `Command`, `reduce`, the cascade, focus, rest, add, copy, remove, arrange and superset rules, `focusAfterLog`, the drop mapping (`listRows`, `layoutAfterDrop`), `alignLastTime`. Imports only `dart:core`. |
| `lib/store.dart` | Schema, migrations, every SQL statement, whole-day save, previous-session lookup, history paging, exercise catalog, settings, import policy and the `ImportBatch` boundary types. |
| `lib/fitnotes.dart` | FitNotes tables and conventions, `readFitNotes` (rows to `ImportBatch`), `importFitNotes` (isolate, safety copy, `Store.importBatch`). |
| `lib/rest_alarm.dart` | `RestAlarm.show(Rest?)`, backed by a Kotlin method channel that posts a countdown notification and an exact alarm that vibrates at zero. |
| `lib/workout_screen.dart` | The live day: dispatch, undo, save retry, alarm sync, the list, cards, rows and the docked panel. |
| `lib/history_screen.dart` | Paged past days, copy to today, and the data menu. |
| `lib/exercise_picker.dart` | `pickExercise` and the create-exercise dialog. |
| `lib/equipment_mark.dart` | `EquipmentMark`, the only code that draws equipment: a barbell, two stacked dumbbells or one dumbbell, painted at a given height and scaled with the text, labelled for screen readers, and nothing for no equipment. |
| `lib/exercise_history_screen.dart` | One exercise's past sessions with the best estimated one-rep max per session. |
| `lib/drive_backup.dart` | `BackupLink`, which is a `FolderLink` (the folder's tree URI and name, and `latest`, the newest week file with its `Week` and snapshot time) or an `OldFileLink` (the single file Setlist 0.2 and 0.3 linked, made only by their state format), each with its last error, kept in `setlist.sqlite.drive-backup.json` beside the database, never in it. `Week`, the Monday that names a week's file. The rule that backs up only when the database or its `-wal` file was written after the last success, or when that success claims a time still to come. The switch that sends a backup to the old file, over this week's file, or into a new week file, with a new file for the week when this week's file cannot be written. The one-at-a-time queue of link, backup, fetch, pick and unlink calls over the `de.schurr.setlist/documents` channel that `Documents.kt` answers through Android's Storage Access Framework. |
| `lib/drive_backup_screen.dart` | The Google Drive backup screen, one layout per kind of link: choose a folder, status, back up now, restore latest, restore an earlier week, change folder, stop. Also `restoreFromCopy`, the confirm-then-delete step that History's restore shares. |
| `lib/main.dart` | Opens the database and shows today, starts over on today when the app resumes on a later day with no set logged in the last 3 hours, and backs up each time the app goes to the background, with the app clock choosing the week file. |

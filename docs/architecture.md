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
5. **FitNotes import rules.** Every set on a day before the import's today imports as done. For today and later, `is_complete` decides done or planned. `weight_increment` and `default_rest_time` that are NULL or 0 become the FitNotes globals. Set comments (`Comment.owner_type_id = 1`) become set notes, several joined with ` / `; comments whose set no longer exists are counted in the report, not imported. Supersets, routines and body weight are counted as left out.
6. **Weight display.** `Field.weight.format` shows kg with at most two decimals and no trailing zeros (20412 g shows as `20.41`, 100000 as `100`, 102500 as `102.5`). `parse` accepts a comma or a dot. Storage and the cascade stay in exact grams.
7. **Schema has one copy.** The migration list in `store.dart` holds the real v1 statements. `docs/schema.sql` is generated from it by a test, or the golden test compares a migrated database's `sqlite_master` with `docs/schema.sql` and fails on any difference.
8. **Failed saves.** Keep candidate 1's `StoreWriteFailed` and the screen's retry.
9. **Keep the screen on** while the app is in the foreground (`FLAG_KEEP_SCREEN_ON` in `MainActivity`), as FitNotes offers.
10. **Data menu.** On the history screen: import a FitNotes backup, export a copy of the Setlist database (`Store.copyTo` then save through the file picker), and restore from such a copy (the one action with a confirmation dialog, because it replaces everything).

## Module map

| File | Owns |
| --- | --- |
| `lib/day.dart` | Value types, the `Field` and `ExerciseKind` tables, `DayState`, `Command`, `reduce`, the cascade, focus, add, copy, remove and move rules, `alignLastTime`. Imports only `dart:core`. |
| `lib/store.dart` | Schema, migrations, every SQL statement, whole-day save, previous-session lookup, history paging, exercise catalog, settings, import policy and the `ImportBatch` boundary types. |
| `lib/fitnotes.dart` | FitNotes tables and conventions, `readFitNotes` (rows to `ImportBatch`), `importFitNotes` (isolate, safety copy, `Store.importBatch`). |
| `lib/rest_alarm.dart` | `RestAlarm.show(Rest?)`, backed by a Kotlin method channel that posts a countdown notification and an exact alarm that vibrates at zero. |
| `lib/workout_screen.dart` | The live day: dispatch, undo, save retry, alarm sync, the list, cards, rows and the docked panel. |
| `lib/history_screen.dart` | Paged past days, copy to today, and the data menu. |
| `lib/exercise_picker.dart` | `pickExercise` and the create-exercise dialog. |
| `lib/exercise_history_screen.dart` | One exercise's past sessions with the best estimated one-rep max per session. |
| `lib/drive_backup.dart` | `BackupLink` (the linked file's URI and name, the last success and the last error, kept in `setlist.sqlite.drive-backup.json` beside the database, never in it), the rule that backs up only when the database or its `-wal` file was written after the last success, and the one-at-a-time queue of link, backup, fetch and unlink calls over the `de.schurr.setlist/documents` channel that `Documents.kt` answers through Android's Storage Access Framework. |
| `lib/drive_backup_screen.dart` | The Google Drive backup screen: link, status, back up now, restore, change, stop. |
| `lib/main.dart` | Opens the database and shows today, starts over on today when the app resumes on a later day with no set logged in the last 3 hours, and backs up to the linked file each time the app goes to the background. |

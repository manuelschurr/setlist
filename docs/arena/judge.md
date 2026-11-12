# Arena cross-judge report

Scored 2026-11-12 by an independent reviewer that read both candidates in full. File and line references point into the candidate packages, which were sketches outside this repo; their rationales are `candidate-1.md` and `candidate-2.md` here.

## Scores

**1. Rules.** C1: 5, C2: 4.
- C1: `reduce` takes everything it needs as data: the log time in `LogSet` and the previous session in `AddExercise`. `DayState._` is private and asserts the focus exists. Unknown refs return the state unchanged.
- C2: `DayState.settle` is one clean place that enforces the focus rule. But `reduce` calls SQLite through `EditContext.lastSession`, and `operator []` uses `!`, so a stale undo ref crashes `_log` and `_cascade`.

**2. Persistence.** C1: 4, C2: 3.
- C1: the `app_day` ledger makes a re-import idempotent. It can never overwrite or resurrect a day the lifter saved, and it refreshes days the lifter never touched. Weak spots: it imports `is_pending_update` rows as planned, uses 2.5 kg and 120 s defaults, and reads rest as `default_rest_time ?? 120`, so a 0 becomes 0 s.
- C2: good extras are STRICT tables and a `VACUUM INTO` backup before migrating. But the slot-level `ON CONFLICT DO NOTHING` merge brings back slots or days the lifter deleted, adds FitNotes slots into days made in Setlist, and can never fill in later columns.

**3. Reader load.** C1: 4, C2: 4.
- C1: every flow traces through three files. But the screen carries undo, persist, alarm and lifecycle glue, and the history screen passes `alarm` through without using it.
- C2: `DayController` exposes five members. But `_SlotCard` takes 12 parameters, and `InsertSet` and `InsertSlots` exist only to serve undo.

**4. Undo, rest, last time.** C1: 3, C2: 5.
- C1: any change to the workout clears the undo offer, so a stepper tap on the next set takes away the Undo for the log. Safe but unhelpful. Rest is derived from log times and `RestAlarm.show` keeps the notification in step. "Last time" pairs by raw index, so one added warm-up shifts every row. The recent list and last-time cache are never refreshed.
- C2: undo applies the reverse of the one edit, and a test proves it keeps the stepper tap. `reload` clears the memo, and `alignLastTime` pairs warm-ups with warm-ups. Minus: rest is an in-app ticker only, while the decision log already chose a notification plus an exact alarm.

**5. Fit for v1.** C1: 4, C2: 2.
- C1: all ten kinds already exist, backed by a four-field set and a kind column with no CHECK. A per-set note and default fixes are additive.
- C2: three kinds, a CHECK on kind and no distance column, and no weight-and-time kind, which FitNotes backups use. Absorbing the late facts means a table rebuild in v1.

## Red flags

- C1, split ownership: from history, tapping today pushes a second workout screen for the same day, whose stale state overwrites the newer day on its next whole-day save.
- C2, hand-synced list: the kind CHECK duplicates the enum, and the schema exists in two copies.

## Recommendation

Use C1 as the base. Graft from C2: undo by reverse edit, one writer per day with `reload()` on route return, and `alignLastTime`, plus STRICT tables and the pre-migration `VACUUM INTO` backup.

## Defects the synthesis must fix

- No per-set note in either candidate, though the decision log requires one.
- C1 imports placeholders as planned, while the decision says every past-day set imports as done.
- Import defaults: NULL or 0 increments and rest times must become the owner's globals.
- Converted weights such as 20.4117 kg need rounded display and comma parsing; the cascade stays exact in grams.
- Stale refs: every arm must check its ref exists.
- Keep C1's `StoreWriteFailed` and save retry.
- Replace C1's placeholder `_v1` with the real schema and make the golden `sqlite_master` test real.
- Add an index on `workout_slot (exercise_id)`.

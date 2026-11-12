# Setlist design

Setlist is a strength training log for one lifter on Android, built to replace FitNotes. It works offline, stores everything in one SQLite file on the phone, and uses kilograms.

## The problems it fixes

These come from the owner's own brief about FitNotes.

1. Seeing the rest of today's workout means leaving the current exercise screen and opening another one.
2. After copying a previous workout, raising or lowering the weight or reps means editing every set one by one.
3. Finishing an exercise brings up a confirmation before moving to the next one.
4. Reordering exercises within a workout takes too many steps.

## Done means

On a real Android phone, with a workout copied from a past day:

- The workout screen shows every exercise and every set of the day without navigating anywhere.
- Changing the weight or reps of set 1 once changes the same value on every following planned set of that exercise that still held the old value.
- Logging the last set of an exercise moves the focus to the next planned set, in the next unfinished exercise, with no dialog.
- Dragging an exercise by its handle moves it in one gesture.
- A FitNotes backup imports, and the number of imported sets equals the number of rows in its training log.

## The workout screen

One screen per day. It has two parts.

The list fills the screen above the panel. Each exercise is a card with a header (name, progress such as `2/4` or a check when done, a drag handle, and a menu) and one row per set. A set row shows the set number, the weight, the reps, what the lifter did on that set last time in small muted text, and a check circle. The focused set row is highlighted. A finished exercise collapses to its header with a summary of its top set, and tapping it expands it again. The list ends with an "Add exercise" button. An empty day shows the recent workouts with a "Copy" button on each, because copying a past workout is how the owner starts most sessions.

The panel is docked at the bottom, in thumb reach. It always edits the focused set. It shows the exercise name and set number, a weight stepper and a reps stepper with large buttons (tap the number to type it), and one large "Log set" button. Edits apply at once and the list above shows them. After a set is logged the panel shows the rest countdown for that exercise.

Why a docked panel rather than editing inside each row: the input controls stay in one place with large targets, the system keyboard never covers the list, and the owner already knows the stepper and save pattern from FitNotes. The list is for overview and for picking which set to work on.

## Rules

**Focus.** The focused set is the one the panel edits. When the screen opens, focus goes to the first planned set in workout order. Tapping any set row focuses it. Logging a set moves focus to the next planned set in the same exercise, and if there is none, to the first planned set in the whole workout from the top. That way an exercise skipped earlier (a busy rack) comes back next. If no planned set remains, the panel shows the session summary.

**Cascade.** Changing a field (weight, reps, or seconds) of a set from value `old` to `new` also sets `new` on every later set of the same exercise that is still planned and whose field equals `old`. Done sets never change by cascade. Sets with a different value are left alone, so warm-up sets and back-off sets survive an edit to the working sets. A copied 3 x 5 at 100 kg becomes 3 x 5 at 102.5 kg with one tap on set 1's plus button.

**Log without confirmation.** Logging is one tap. Undo is a snackbar action, not a dialog in front of the action. The check circle on a row logs that set with its current values without moving through the panel.

**Add exercise.** Adding an exercise to a day creates planned sets copied from the last session of that exercise, or one empty set if it was never done. An exercise appears at most once per day, so adding one already in the day scrolls to it.

**Copy a workout.** Copying a past day appends each of its exercises that the target day does not have yet, with all sets copied as planned.

**Reorder.** Each card header has a drag handle. Dragging moves the whole card.

## Data shape

The day is the aggregate. A `Workout` holds the date, a note, and an ordered list of slots. A slot is one exercise in that day with its ordered list of sets. List order is position, so reordering is a list move. Every operation is a pure function from `Workout` to `Workout`, which makes the cascade and focus rules unit-testable and gives undo for free by keeping the previous value.

A set holds weight in kg, reps, seconds, whether it is a warm-up, and its status (`planned` or `done`, with the time it was logged). An exercise has a kind (`weightReps`, `reps`, or `time`), which decides which fields the row and panel show, plus a weight step and a default rest time.

Saving writes the whole day in one transaction, replacing what the database held for that date. Saving the same day twice leaves the same rows. A day with no exercises and no note is deleted.

## Screen details

**Workout screen app bar.** The title is "Today", "Yesterday" or a short date such as "Thu 12 Nov". Tapping it opens a date picker to jump to any day. Actions are History and an overflow with "Workout note" and "Copy a past workout".

**Card header.** Exercise name, progress (`2/4`, or a check when finished), a drag handle, and a menu with History, Edit exercise and Remove. Tapping the header collapses or expands the card. A finished card collapses on its own unless the lifter opened it or the focus is inside it, and shows one summary line such as `4 sets · top 100 × 5`.

**Set row.** Set number (`W` for a warm-up), the values the kind shows (`100 kg × 5`, `1:30`, `2.5 km · 12:00`), the muted last-time value, and a check circle. The focused row has a filled highlight. A note shows under the values in small text. Swiping a row away deletes the set with an Undo snackbar. Long-pressing a row offers warm-up on or off, the note, and delete. Each card ends with "Add set".

**Panel.** The exercise name and "Set 2 of 4", then one stepper per field of the kind, side by side when there are two, with buttons at least 56 dp. Tapping a value opens a numeric dialog that commits once on OK. One full-width button: "Log set" on a planned set, "Next set" on a done one. While resting, a countdown shows in the panel. When nothing is planned, the panel shows the session summary instead.

**Feedback.** Logging, removing and copying each show a snackbar with Undo. Nothing asks for confirmation except restoring a backup, which replaces all data. When the focus moves to another exercise, its card scrolls into view.

**History screen.** Past days newest first, each with the date, the exercise names and the set count. Tapping a day opens it on the same workout screen. Tapping today returns to the home screen instead, so one day never has two screens writing it. A copy button on each day copies it into today through the home screen. The overflow holds the data actions: the Google Drive backup screen, import a FitNotes backup, export a Setlist backup, restore a Setlist backup.

**Google Drive backup.** The lifter links one backup file once, through the system picker's create dialog, usually in Google Drive. From then on, each time the app goes to the background after the database changed, Setlist writes a fresh copy of the whole database over that file, and the Drive app uploads it. The screen shows the file name and the time of the last backup that reached it, or the last error, with Back up now, Restore from this backup (with the restore confirmation), Change file and Stop backing up. Unlinked, it shows one sentence and Choose backup file. A new phone has no link, so it restores through the picker first.

**Exercise history.** From a card's menu: the past sessions of that exercise, newest first, each with its sets and its best estimated one-rep max (Brzycki, the formula FitNotes uses), marked when it set a new best.

**Exercise picker.** A search field with focus on open, the exercises ordered by last use, and a "Create" row for a name that does not exist yet. Creating asks for the name, the kind, an optional category, the weight step and the rest time, prefilled with the defaults.

## Out of scope for the first version

Routines and templates (copying a past day covers how the owner works), supersets, charts, body weight, units other than kg, cloud sync. Each can come later without changing the day aggregate.

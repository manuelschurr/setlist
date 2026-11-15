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
- In a superset, logging a set moves the focus to the next exercise of the round, and the rest countdown starts only when the round is over.
- Dragging an exercise card into a superset's frame adds it to that superset, dragging it out takes it out, and the superset's own handle moves the whole superset.

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

**Copy a workout.** Copying a past day appends each of its exercises that the target day does not have yet, with all sets copied as planned. Its supersets come along. An exercise the target day already has stays where it is, the other exercises of its superset are copied together, and a superset left with one exercise arrives as a plain exercise.

**Reorder.** Each card header has a drag handle. Dragging moves the whole card. A superset has its own handle, on its header strip, that moves the whole superset.

**Supersets.** A superset is two or more exercises done in turn, one set of each per round. An exercise belongs to at most one superset, and a superset never holds another superset. A superset with one exercise does not exist. Whenever an exercise leaves a superset of two, the one left becomes a plain exercise.

**Focus in a superset.** Focus moves after a log under the same condition as for a plain exercise. When it moves from a set of an exercise in a superset, it goes to the next exercise of that superset, in superset order and wrapping to the first, that still has a planned set, and there to its first planned set. When the logged exercise is the only one of its superset with a planned set left, focus goes to its next planned set, as for a plain exercise. When no exercise of the superset has a planned set left, focus goes to the first planned set from the top of the workout.

**Rest in a superset.** Logging a set of an exercise in a superset starts no countdown while an exercise after it in the same superset still has a planned set, because the round is not over. Otherwise the countdown starts and lasts the longest rest of the superset's exercises. In other words, rest comes when the focus goes back up the superset or leaves it.

**Making and changing a superset.** The card menu's "Superset with…" lists the day's exercises that are not in this card's superset. The picked exercise moves to right after this card and joins its superset, or the two start a new one. A picked exercise that was in another superset leaves it, and the list names that superset under the exercise. Dragging does the rest. Dropping an exercise card inside a superset's frame puts it in that superset at that spot, which is also its place in the round. Dropping it outside every frame makes it a plain exercise. A whole superset dropped inside another superset's frame lands right above that superset. Removing an exercise takes it out of its superset too. Adding an exercise always adds a plain one at the end.

## Data shape

The day is the aggregate. A `Workout` holds the date, a note, and an ordered list of entries. An entry is either a slot or a superset. A slot is one exercise in that day with its ordered list of sets. A superset holds two or more slots in round order, and one with fewer cannot be built. List order is position, so reordering is a list move, and the day's slots in order are the entries flattened. In the database each slot row keeps its position and a `joined` flag that means "same superset as the slot before it", which cannot describe a superset of one or a superset whose exercises are apart. Every operation is a pure function from `Workout` to `Workout`, which makes the cascade and focus rules unit-testable and gives undo for free by keeping the previous value.

A set holds weight in kg, reps, seconds, whether it is a warm-up, and its status (`planned` or `done`, with the time it was logged). An exercise has a kind (`weightReps`, `reps`, or `time`), which decides which fields the row and panel show, plus a weight step and a default rest time.

Saving writes the whole day in one transaction, replacing what the database held for that date. Saving the same day twice leaves the same rows. A day with no exercises and no note is deleted.

## Screen details

**Workout screen app bar.** The title is "Today", "Yesterday" or a short date such as "Thu 12 Nov". Tapping it opens a date picker to jump to any day. Actions are History and an overflow with "Workout note" and "Copy a past workout".

**Card header.** Exercise name, progress (`2/4`, or a check when finished), a drag handle, and a menu with History, Edit exercise, Superset with… and Remove. Tapping the header collapses or expands the card. A finished card collapses on its own unless the lifter opened it or the focus is inside it, and shows one summary line such as `4 sets · top 100 × 5`.

**Set row.** Set number (`W` for a warm-up), the values the kind shows (`100 kg × 5`, `1:30`, `2.5 km · 12:00`), the muted last-time value, and a check circle. The focused row has a filled highlight. A note shows under the values in small text. Swiping a row away deletes the set with an Undo snackbar. Long-pressing a row offers warm-up on or off, the note, and delete. Each card ends with "Add set".

**Superset frame.** A superset is a coloured frame around its exercises' cards. A header strip on top reads "Superset" and carries the superset's drag handle. Each exercise inside keeps its own card, with its header, handle, menu, rows and "Add set", and finished exercises collapse one by one as plain ones do. The frame ends in a short cap with clear space below it that belongs to the superset, so a card dragged a little way up from right below the frame lands inside it. While the whole superset is dragged, its exercises fold into the header strip, which shows their names. A card dragged out of a frame floats without the frame, because it may land outside every frame.

**Panel.** The exercise name and "Set 2 of 4", followed in a superset by where the focus goes after this set, as in "Set 2 of 4 · then Rows". The panel asks the same rule the log follows, so the two never disagree. Then one stepper per field of the kind, side by side when there are two, with buttons at least 56 dp. Tapping a value opens a numeric dialog that commits once on OK. One full-width button: "Log set" on a planned set, "Next set" on a done one. While resting, a countdown shows in the panel. When nothing is planned, the panel shows the session summary instead.

**Feedback.** Logging, removing and copying each show a snackbar with Undo. Nothing asks for confirmation except restoring a backup, which replaces all data. When the focus moves to another exercise, its card scrolls into view.

**History screen.** Past days newest first, each with the date, the exercise names and the set count. A superset's names are joined with a plus, as in "Bench + Rows", here and on the copy tiles. Tapping a day opens it on the same workout screen. Tapping today returns to the home screen instead, so one day never has two screens writing it. A copy button on each day copies it into today through the home screen. The overflow holds the data actions: the Google Drive backup screen, import a FitNotes backup, export a Setlist backup, restore a Setlist backup.

**Google Drive backup.** The lifter links one folder once, through the system folder picker. On Drive it must be a folder inside My Drive, picked there or made with the picker's create-folder button, because the picker refuses My Drive itself. Setlist keeps one backup file per week in the folder, named by the Monday that starts the week (`Setlist week of 2026-11-09.sqlite`), so the files sort by date in Drive. Each time the app goes to the background after the database changed, Setlist writes a fresh copy of the whole database over this week's file, and the week's first backup creates that file. Once a week is over, its file never changes again, so a bad change can reach only the current week's file. Setlist never lists the folder and never deletes a backup. When a write to this week's file fails and the folder grant still holds, the same backup creates a new file for the week, which covers a file the lifter deleted, moved or put in the bin in Drive. A folder in the Drive bin gets its own error and no write, because Drive keeps accepting files there until it empties the bin. Leaving the app while a restore picker is open backs up nothing, because the picker itself sends the app to the background, and the state about to be replaced would otherwise land in this week's file. The screen shows the folder, the time of the last backup and the file that holds it, or the last error, with Back up now, Restore latest backup, Restore an earlier week (the system picker, opened in the folder), Change folder and Stop backing up. Unlinked, it explains the weekly files and shows Choose backup folder. A phone upgraded from 0.2 keeps backing up to its single file until the lifter chooses a folder, and the screen leads with that choice. A new phone has no link, so it restores through the picker first.

**Exercise history.** From a card's menu: the past sessions of that exercise, newest first, each with its sets and its best estimated one-rep max (Brzycki, the formula FitNotes uses), marked when it set a new best.

**Exercise picker.** A search field with focus on open, the exercises ordered by last use, and a "Create" row for a name that does not exist yet. Creating asks for the name, the kind, an optional category, the weight step and the rest time, prefilled with the defaults.

## Out of scope for the first version

Routines and templates (copying a past day covers how the owner works), charts, body weight, units other than kg, cloud sync. Each can come later without changing the day aggregate.

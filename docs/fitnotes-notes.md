# FitNotes as observed

Observed on 2026-11-12 on a test phone running FitNotes 25.1, and in a backup taken from it. Screenshots stay out of the repo because they show personal data.

## The four pain points, reproduced

1. The home screen lists the day's exercises and sets, but logging happens on a separate training screen that shows one exercise. To see the others you open a side drawer, which lists only exercise names and set counts.
2. Selecting a set loads it into the weight and reps steppers and turns SAVE and CLEAR into UPDATE and DELETE. Every copied set needs its own select, change, UPDATE.
3. With "Mark Sets Complete" on, ticking the last set of an exercise opens a dialog: "Sets complete. Do you want to move on to the next exercise?" with the next exercise's name and Cancel or Go.
4. Reordering happens in the drawer: "Press-and-hold an exercise to reorder".

Also seen: ticking a set auto-starts the rest timer, and the countdown replaces the alarm icon in the toolbar. Copy Previous Workout opens a calendar where you scroll to the day to copy.

## Settings that matter to Setlist

FitNotes has a global default weight increment and rest timer (`settings.weight_increment`, `settings.rest_timer_seconds`), Mark Sets Complete, Auto-Select Next Set, and Keep Screen On. The importer carries the two defaults over, and Setlist keeps the screen on.

## What a real backup shows

- `user_version` is 22. Many exercises are FitNotes' stock library and were never logged.
- Routines, workout comments, body weight and the workout timer can all be empty for someone who plans by copying past workouts.
- Supersets appear as `WorkoutGroup` rows.
- Some set comments point at sets that no longer exist.
- Past sets are mostly `is_complete` = 1. Copied placeholders that were never ticked stay `is_complete` = 0 with `is_pending_update` = 1.
- Per-exercise `weight_increment` and `default_rest_time` are often NULL or 0, which means "use the global default".
- An exercise's sets can be interleaved by `_id` with another exercise's sets on the same day (supersets, or sets added later). Grouping by exercise and ordering by smallest `_id` matches what the FitNotes home screen shows.

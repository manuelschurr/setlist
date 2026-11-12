# Setlist

Setlist is a strength training log for one lifter on Android, built to replace FitNotes. The whole day sits on one screen, a docked panel edits the highlighted set, an edit to set 1 carries down to the later planned sets that held the same value, logging the last set of an exercise moves on without asking, and each exercise card has a drag handle. It works offline and keeps everything in one SQLite file on the phone.

`docs/design.md` says what the app does and why. `docs/architecture.md` says how the code is laid out.

## Install it on a phone

1. Build the APK on the VPS:

	```bash
	scripts/fl build apk --release --target-platform android-arm64
	```

2. Copy `build/app/outputs/flutter-apk/app-release.apk` to the phone and open it, or install it over adb with `scripts/device.py install build/app/outputs/flutter-apk/app-release.apk`.

The release build is signed with the VPS debug key in `~/.android/debug.keystore`. Android installs an update only when it carries the same signature, so keep that file. If it is lost, uninstall Setlist before installing a new build, which deletes its data, so export a backup first.

## Move your FitNotes history over

1. In FitNotes, open **Settings**, then **Backup**, then **Save Backup**, and save the file to Downloads.
2. In Setlist, open **History**, tap the **Data** menu, then **Import FitNotes backup**, and pick that file.

The import writes one Setlist set per FitNotes set and then lists what it left out, such as superset groups and comments on deleted sets. Sets on past days arrive as done. For today and later days, FitNotes' completion checkbox decides. Running the import again is safe. It refreshes days you have not touched in Setlist and never changes a day you have saved in Setlist.

A Google Drive automatic backup from FitNotes arrives as a zip file. Unzip it first.

## Back up and restore

**History**, then **Data**, then **Export Setlist backup** saves a copy of the database wherever you choose. **Restore Setlist backup** replaces everything with such a copy, after a confirmation. Setlist keeps the replaced database in its own storage as `setlist.sqlite.before-restore-<unix ms>`.

## Develop

`scripts/fl` runs `flutter` under a host-wide lock, because two Gradle builds at once run this 12 GB VPS out of memory. Use it for every Flutter command.

| Command | What it does |
| --- | --- |
| `scripts/fl test` | Runs every test: the day rules, the store, the importer and the screens. |
| `scripts/fl analyze` | Runs the analyzer. |
| `SETLIST_FITNOTES_BACKUP=<file> scripts/fl test test/fitnotes_test.dart` | Also imports a real FitNotes backup and checks one set per `training_log` row. |
| `SETLIST_RENDER_DIR=<dir> scripts/fl test test/render_screens_test.dart` | Draws the main screens to PNGs at the test phone's size, for layout review without a device. |
| `scripts/device.py <command>` | Drives the test phone over adb: `install`, `launch`, `ui` (lists visible labels), `tap <label>`, `shot <file>`. |

`docs/schema.sql` is the database schema as the migrations build it, and `test/store_test.dart` fails if the two differ. `docs/decisions.tsv` logs each design decision with its evidence.

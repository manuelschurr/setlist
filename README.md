# Setlist

Setlist is a strength training log for one lifter on Android, built to replace FitNotes. The whole day sits on one screen, a docked panel edits the highlighted set, an edit to set 1 carries down to the later planned sets that held the same value, logging the last set of an exercise moves on without asking, and each exercise card has a drag handle. It works offline and keeps everything in one SQLite file on the phone.

`docs/design.md` says what the app does and why. `docs/architecture.md` says how the code is laid out.

## Install it on a phone

Install [Obtainium](https://github.com/ImranR98/Obtainium) and add `https://github.com/manuelschurr/setlist` to it. Obtainium watches this repository's releases and installs each new `setlist_<version>_android-arm64.apk`, after Android has asked once whether it may install apps. The APK is for phones with a 64-bit ARM processor, which nearly every phone of the last years has. You can also download the APK from the Releases page and open it.

Every release is signed with the same key, which is what lets a new version install over the old one and keep your data. A Setlist installed from any other build, signed with another key, has to be uninstalled first, and uninstalling deletes its data, so export a backup before you switch.

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
| `SETLIST_DEVICE=<host:port> scripts/device.py <command>` | Drives a phone over adb: `install`, `launch [package]`, `ui` (lists visible labels), `tap <label>`, `shot <file>`. |

Debug builds install as a separate app, `de.schurr.setlist.debug`, labelled Setlist debug, so testing never touches the installed release or its data.

## Release

Run `tools/release-key.sh` once on the build machine. It makes the signing key in `~/.config/setlist/android`, outside the repository. Back that folder up somewhere other than the server: without it, no later release can update an installed Setlist.

`tools/release.sh 0.2.0` publishes version 0.2.0 from a clean `main`. It sets the version in `pubspec.yaml`, tags `v0.2.0`, builds the APK, checks that it carries the release key's signature, pushes, and attaches the APK to a GitHub release. Release notes come from `docs/releases/0.2.0.md` when that file exists, and are generated from the commits otherwise.

`docs/schema.sql` is the database schema as the migrations build it, and `test/store_test.dart` fails if the two differ. `docs/decisions.tsv` logs each design decision with its evidence.

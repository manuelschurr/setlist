#!/usr/bin/env bash
# Publishes a Setlist release where Obtainium finds it: sets the version, tags it, builds the APK signed with the release key, checks the signature, and attaches the APK to a GitHub release.
set -euo pipefail

version=${1:?usage: tools/release.sh <version, such as 0.2.0>}
[[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "version must look like 0.2.0" >&2; exit 1; }
build=$((BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3]))
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

signing=$HOME/.config/setlist/android/signing.properties
[ -f "$signing" ] || { echo "no release key; run tools/release-key.sh once" >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$version" > /dev/null || { echo "v$version exists already" >&2; exit 1; }

sed -i "s/^version: .*/version: $version+$build/" pubspec.yaml
if ! git diff --quiet pubspec.yaml; then
	git commit -q -m "Release $version" -m "Claude-Session: ${CLAUDE_SESSION_URL:-none}" pubspec.yaml
fi
git tag -a "v$version" -m "Setlist $version"

scripts/fl build apk --release --target-platform android-arm64 --build-name "$version" --build-number "$build"
apk=build/app/outputs/flutter-apk/app-release.apk
store=$(sed -n 's/^storeFile=//p' "$signing")
password=$(sed -n 's/^password=//p' "$signing")
expected=$(keytool -list -keystore "$store" -storepass "$password" -v 2>/dev/null | sed -n 's/.*SHA256: //p' | head -1 | tr -d ':' | tr 'A-F' 'a-f')
actual=$(/opt/android-sdk/build-tools/36.0.0/apksigner verify --print-certs "$apk" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
[ "$expected" = "$actual" ] || { echo "the APK is not signed with the release key ($actual)" >&2; exit 1; }

out=$(mktemp -d)/setlist_${version}_android-arm64.apk
cp "$apk" "$out"
git push -q origin main "v$version"
notes=docs/releases/$version.md
if [ -f "$notes" ]; then
	gh release create "v$version" "$out" --title "Setlist $version" --notes-file "$notes"
else
	gh release create "v$version" "$out" --title "Setlist $version" --generate-notes
fi
echo "released v$version with $(basename "$out")"

#!/usr/bin/env bash
# One-time project setup. Generates the standard Flutter Android project around
# TapCast's own native code, then patches Gradle (dependencies, ABIs, signing).
#
# Requirements: Flutter 3.29+ (stable), Android SDK, JDK 17, python3.
# No accounts, API keys or sign-ups are needed.
set -euo pipefail

cd "$(dirname "$0")"

command -v flutter >/dev/null || { echo "flutter not found. Install it from https://docs.flutter.dev/get-started/install"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found (used to patch Gradle)"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Generating Android scaffold"
flutter create --platforms=android --org com.tapcast --project-name tapcast "$tmp/tapcast" >/dev/null

# No-clobber copy: our AndroidManifest.xml, Kotlin sources and icons win.
mkdir -p android
cp -rn "$tmp/tapcast/android/." android/

# Remove what the scaffold generated that we replace:
rm -rf android/app/src/main/kotlin/com/tapcast/tapcast                       # stock MainActivity
rm -f android/app/src/main/res/mipmap-*/ic_launcher.png                     # Flutter logo, replaced by adaptive icon

echo "==> Patching Gradle"
python3 tool/patch_gradle.py android/app/build.gradle.kts

echo "==> Fetching Dart packages"
flutter pub get

cat <<'EOF'

Done. Next:
  flutter run                                   # debug on a connected phone
  flutter build apk --release --split-per-abi   # installable APKs in build/app/outputs/flutter-apk/
EOF

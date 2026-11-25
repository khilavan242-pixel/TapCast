# TapCast

A small Android app that casts YouTube and files from your phone to a DLNA TV.

- Share a video from the YouTube app to TapCast: it plays on the TV and the next videos follow by themselves.
- Browse YouTube inside the app and tap a video to cast it.
- Play videos, songs and pictures from the phone on the TV.
- Runs only while casting. The X on the notification, or swiping the app away, closes it completely.

Build: `bash setup.sh`, then `flutter build apk --release --split-per-abi` (GitHub Actions does this on every push).

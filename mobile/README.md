# Miles — Flutter client

The app itself. What it does and how it is organized lives in the
[root README](../README.md) and [docs/REFERENCE.md](../docs/REFERENCE.md).

```bash
flutter pub get
flutter analyze
flutter test
bash tool/release.sh --play      # Play AAB
bash tool/release.sh --bump      # sideload APK
```

Run `flutter` from this directory; the repo root has no pubspec.yaml. `.env` is
required and never committed; see `.env.example` for the keys. `pubspec.yaml`'s
`version:` build number and `ReleaseGate.buildNumber` move together; a test
enforces the pair.

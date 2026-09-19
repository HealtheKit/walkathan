# Walkathan

A Flutter app for tracking steps during a walkathon event. Users sign in
(Supabase Auth), track their step count via the device pedometer, and view
results on a leaderboard.

Built with Flutter, Riverpod, `go_router`, and Supabase (auth + data).

## Getting started

Install dependencies:

```
flutter pub get
```

Run on a connected device or emulator:

```
flutter run
```

Run static analysis and tests:

```
flutter analyze
flutter test
```

For Android release/Google Play internal-testing build instructions, see
[docs/google-play-release.md](docs/google-play-release.md).

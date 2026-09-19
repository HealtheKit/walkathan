# Google Play Release Guide (Android)

This document covers what is needed to build a signed Android App Bundle
(`.aab`) for a Google Play **internal testing** release, and what to verify
in Play Console. It does not cover publishing itself.

## Package identity

- **applicationId / namespace:** `com.tresundios.walkathon`
- **History:** The repository originally had a mismatch — `applicationId`
  was `com.walkathan.app` while the Gradle `namespace` and the
  `MainActivity.kt` package/directory were `com.tresundios.walkathan`. It
  was briefly aligned to `com.walkathan.app`, then changed again to
  `com.tresundios.walkathon` (per explicit request), with
  `MainActivity.kt` moved to
  `android/app/src/main/kotlin/com/tresundios/walkathon/MainActivity.kt` to
  match.
- **Note:** `android/app/google-services.json` used to exist but has been
  removed (see Firebase note below).
- **App label:** `Tresundios - TEF Walkathon` (`android/app/src/main/AndroidManifest.xml`).
- **Note:** Firebase config files (`android/app/google-services.json`,
  `ios/Runner/GoogleService-Info.plist`, `macos/Runner/GoogleService-Info.plist`,
  and root `firebase.json`) were removed — no Firebase Flutter package was
  declared in `pubspec.yaml` and no `google-services` Gradle plugin was
  applied, so they were inert leftovers. `ios/Podfile.lock` may still list
  stale `Firebase`/`firebase_auth`/`firebase_core` pods from before those
  packages were removed from `pubspec.yaml`; run `cd ios && pod install`
  (or `flutter clean` + a fresh iOS build) to regenerate it without them.
  If Firebase is ever actually integrated, re-add the config files and
  Gradle/CocoaPods plugin at that time.

## Versioning rules

- Version lives in `pubspec.yaml` as `version: X.Y.Z+N`.
  - `X.Y.Z` → Android `versionName` (user-visible).
  - `N` → Android `versionCode` (must strictly increase on every Play
    upload, including internal testing tracks).
- First release is set to `1.0.0+1`.
- For every subsequent upload to Play (even internal testing), bump `+N`.
  Bump `X.Y.Z` for user-facing version changes per semver-ish convention.

## Build commands

```sh
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

Debug builds are unaffected and continue to use Flutter's default debug
signing:

```sh
flutter run
flutter build apk --debug
```

## Release signing (`android/key.properties`)

`android/app/build.gradle` reads signing credentials from
`android/key.properties` if present, and now **fails the build with an
explicit error** if a release build is requested and that file is missing
(no silent fallback to debug signing).

`android/key.properties`, `*.jks`, and `*.keystore` are already listed in
`.gitignore` — never commit them.

### 1. Create an upload keystore (one-time, local only)

```sh
keytool -genkey -v \
  -keystore ~/walkathan-upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias walkathan
```

Follow the prompts to set a store password and key password. Store the
`.jks` file and passwords somewhere safe (e.g. a password manager) — losing
the upload key means you cannot update the app on Play under the same
listing without going through Play's key-loss recovery process.

### 2. Create `android/key.properties`

```properties
storePassword=<your store password>
keyPassword=<your key password>
keyAlias=walkathan
storeFile=/absolute/path/to/walkathan-upload-keystore.jks
```

This file must **not** be committed (already git-ignored).

### 3. Build the release bundle

```sh
flutter build appbundle --release
```

### 4. Locate the output

```
build/app/outputs/bundle/release/app-release.aab
```

Upload this `.aab` to Play Console's internal testing track.

## Permissions audit

Declared in `android/app/src/main/AndroidManifest.xml`:

| Permission | Purpose | Verified usage |
|---|---|---|
| `ACTIVITY_RECOGNITION` | Required on Android 10+ to receive step-count/activity data from the `pedometer` plugin. | Requested via `Permission.activityRecognition` in `lib/pages/content/walk_home/pedometer_provider.dart`. |
| `BODY_SENSORS` | Required for step/pedestrian-status sensor data used by `pedometer`. | Requested via `Permission.sensors` in the same provider. |
| `INTERNET` | Required for all Supabase network calls (auth, data). | Used throughout via `supabase_flutter`. |

No location, camera, contacts, storage, or background-service permissions
are declared or requested — none were added, consistent with the current
feature set (step counting + Supabase auth/data only).

The debug/profile manifests' `INTERNET` permission is a Flutter
tooling requirement (hot reload/VM service) and is not shipped in end-user
release builds beyond what's already declared in the main manifest.

## Secrets / configuration review

- `lib/config/supabase_config.dart` contains a Supabase project URL and a
  **publishable (`sb_publishable_...`) anon key**. This is a public client
  identifier by design (equivalent to Firebase's public API key) and is
  safe to ship in a mobile client — it is not a secret. No service-role or
  other server-side secret was found in the repository.
- No hard-coded private API keys, passwords, or service-role keys were
  found anywhere in `lib/`, `android/`, or `ios/`.
- If you later need per-environment (dev/staging/prod) Supabase projects,
  consider `--dart-define`/`--dart-define-from-file` at build time instead
  of hard-coding multiple URLs, but this was not required for the current
  single-environment setup and was not changed.

## App assets / store listing — TODO

Launcher icons are already configured and generated
(`flutter_icons` in `pubspec.yaml` → `assets/images/logo.png` →
`android/app/src/main/res/mipmap-*`), so no icon work is required for the
app itself.

Still required before submission (not present in this repo — do not
fabricate):

- [ ] **512×512 Play Store icon** (PNG, no alpha) for the Play Console listing.
- [ ] **1024×500 feature graphic** for the Play Console listing.
- [ ] **Genuine screenshots** (phone, and tablet if supporting tablets) taken
      from an actual build.
- [ ] **Privacy policy URL** — required by Play Console for any app that
      requests sensitive permissions (activity recognition counts) or
      handles user accounts. Must be hosted and publicly reachable before
      submission.

## Play Console "Data safety" section — verify against actual dependencies

Based on `pubspec.yaml` (`supabase_flutter`, `pedometer`,
`permission_handler`) declare/verify at minimum:

- **Collected:** Email address / user ID (Supabase Auth).
- **Collected:** Fitness/activity data (step count, from `pedometer` +
  `ACTIVITY_RECOGNITION`/`BODY_SENSORS`).
- **Data shared with third parties:** Supabase (backend processor) — review
  Supabase's DPA/subprocessor terms and disclose accordingly.
- **Data encrypted in transit:** Yes (Supabase uses HTTPS).
- **Data deletion:** confirm whether users can request account/data
  deletion (Play requires an account-deletion path or explanation if the
  app supports account creation).
- Re-verify this list against the actual current codebase before
  submitting — this document reflects dependencies at the time of writing.

## Pre-submission checklist

- [ ] `android/key.properties` created locally (not committed) with a real
      upload keystore.
- [ ] `flutter build appbundle --release` succeeds and produces
      `app-release.aab`.
- [ ] `applicationId` (`com.tresundios.walkathon`) confirmed as final before
      first Play Store upload — it cannot be changed afterwards.
- [ ] Privacy policy published and linked in Play Console.
- [ ] Play Console "Data safety" section filled in per the table above.
- [ ] Store listing assets (icon, feature graphic, screenshots) uploaded.
- [ ] Internal testing track created in Play Console; testers added.
- [ ] `.aab` uploaded to the internal testing track (manual step, not
      automated by this repo).
- [ ] No debug-only code paths, `print`/`debugPrint`-only secrets, or test
      accounts left enabled in the release build.

# Walk workout

A timed walk: set a goal, 3-2-1, live metrics, pause / auto-pause, laps,
finish, summary, save. One walk at a time, visible across the whole app, and
restored if the app is closed.

## What is real and what is simulated

| Part | State |
| --- | --- |
| Session engine, timing, pause / auto-pause, laps, splits, goals, summary | Real |
| Local persistence and recovery (SharedPreferences) | Real |
| Global banner, Walk-tab chip, duplicate-walk prevention | Real |
| GPS, steps, heart rate | **Simulated by default** (`MockLocationService`, `MockStepCounterService`, `MockHeartRateService`) |
| Real GPS and step counter | Written (`data/device_services.dart`), **off by default, not yet run on a phone** |
| Voice coaching, ongoing notification | Interfaces + mocks that record what they would say / show |
| Map | In-app route drawing (`RouteView`), not a map SDK |
| Charts | In-app drawing (`LiveChart`), no chart package |
| Music controls | Disabled placeholder buttons |
| Camera, weather, personal records, image share, TCX | Not built |

With the default settings a walk on a real phone shows an invented route.
Set `walkUseDeviceSensorsProvider` to `true` to use the phone's sensors.

## Structure

```
lib/features/walk_workout/
  domain/        walk_models.dart     entities (SI units), JSON
                 walk_math.dart       pace, calories, zones, auto-pause, GPX
                 walk_services.dart   service interfaces
  data/          mock_services.dart   mock sensors, voice, notification; storage
                 device_services.dart geolocator GPS, step-counter hub
  application/   walk_session_controller.dart   providers + the controller
  presentation/  walk_setup_page.dart, walk_active_page.dart, walk_summary_page.dart
                 walk_ui.dart         navigation, dark theme, ticker, duplicate dialog
                 widgets/             metric_card, goal_progress, route_view, live_chart,
                                      control_bar (+ lock), walk_sheets, walk_status_banner (+ chip)
test/features/walk_workout/           math, controller (incl. recovery), screens
```

## Architecture

Riverpod, because the rest of the app uses it. `walkSessionProvider`
(`WalkSessionController`, a non-autoDispose `Notifier<WalkSession?>`) is the
single source of truth; `null` means no walk. Screens only read it, so the
walk screen can be destroyed and rebuilt at any time.

- **Time comes from timestamps.** Active time is `activeMs` (banked) plus
  `now - lastResumeAt`. The 1-second tick only pulls the next sensor sample
  and refreshes the screen; it is not what keeps time.
- **Stored in SI units.** Units are applied when displaying, so switching
  km / miles mid-walk changes nothing that was recorded.
- **Persistence.** The session is written on every status change and every
  5 s while recording. On start-up it is restored: paused stays paused; a
  walk that was recording continues if the app was away under 2 minutes,
  otherwise it comes back auto-paused (time is banked to the last save, never
  invented); a finished, unsaved walk returns to "save or discard"; a walk
  still in its countdown is dropped.
- **Long walks.** Route and chart points are thinned past 3000 / 1500 items.
- **Rebuilds.** Widgets select the status (`walkStatusProvider`) and let the
  small number widgets listen for the rest.

Routes: `/walk` (setup), `/walk/active`, `/walk/summary`. The banner is in
`AppShell`; the chip wraps the Walk tab icon; tapping the Walk tab while a
walk exists opens that walk.

## Integration points

Every one is a provider in `walk_session_controller.dart` and is marked
`INTEGRATION POINT` in the code.

| Provider | Replace with |
| --- | --- |
| `locationServiceProvider` | geolocator stream (provided), background location |
| `stepCounterServiceProvider` | `StepCounterHub` (provided) |
| `heartRateServiceProvider` | BLE heart-rate strap, Wear OS / Apple Watch companion |
| `voiceCoachProvider` | flutter_tts |
| `walkNotificationProvider` | flutter_local_notifications + Android foreground service; iOS Live Activity |
| `workoutPersistenceProvider` | database + cloud sync (`WalkWorkout.syncStatus`) |
| `walkUserProfileProvider` | the signed-in walker's age, height, weight |
| `CalorieCalculationService` | Health Connect / HealthKit active energy |
| `RouteView` | google_maps_flutter or flutter_map |

## Permissions

Already declared for the rest of the app, nothing added:
Android `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_LOCATION`, `ACTIVITY_RECOGNITION`; iOS
`NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`,
`UIBackgroundModes: location`. A real ongoing notification on Android 13+
also needs `POST_NOTIFICATIONS`.

## Dependencies

None added. Uses `flutter_riverpod`, `go_router`, `shared_preferences`,
`intl`, `geolocator`, and `pedometer` (through `StepCounterHub`).

## Future integrations

Health Connect and HealthKit workout write-back, background GPS with a
foreground service, Bluetooth heart-rate monitors, watch companion, cloud
sync, a real map, text-to-speech, image share, TCX export, keep-screen-awake
(needs a wakelock package), battery indicator.

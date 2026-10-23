# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

StreetSight AR — a Flutter app (Android primary target, iOS project scaffolded but unverified) that overlays turn-by-turn AR walking directions, nearby POI tags, and live camera-based sign translation on a single camera view. No 3D AR engine/plane detection is used for the directional trail — it's a 2D pinhole-camera perspective approximation driven by compass heading + accelerometer pitch (see Architecture below).

## Commands

```bash
flutter pub get                      # install dependencies
flutter devices                      # list targets (phone must have USB debugging on)
flutter run -d <device-id>           # run on a connected device (debug, hot-reload)
flutter analyze                      # static analysis — run after any lib/ change
flutter analyze lib/path/to/file.dart  # analyze a single file
flutter build apk                    # release APK
```

There is no test suite in this repo (`test/` does not exist) — don't assume one when asked to verify a change; rely on `flutter analyze` plus manual device testing.

### Required local setup

- `.env` (gitignored, copy from `.env.example`) must define `GOOGLE_API_KEY` — a Google Cloud key with Places API (New), Cloud Vision, and Cloud Translation v2 enabled. Without it, the app runs entirely on free fallbacks (see Architecture).
- The asset model (`assets/models/mobilenet_v2_1.0_224_quant.tflite` + `imagenet_labels.txt`) is already committed; no download step needed.

## Architecture

### Screen flow
`HomeScreen` (search a destination, pick interest tags, persisted via `shared_preferences`) → on tap, fetches current GPS position + a walking route (`routing.dart`) → pushes `ArScreen` with the destination, route, and interests.

### `ArScreen` (`lib/screens/ar_screen.dart`) — the core of the app
Combines four independent live streams per frame/update: camera image stream, GPS position stream, compass heading stream, and accelerometer stream (for device pitch). Everything in the AR overlay is derived from these, not from any native AR SDK's pose tracking.

- **Scene gate** (`services/scene_gate.dart` + `scene_classifier.dart`): before any AR UI unlocks, `SceneGate.evaluate()` must affirmatively conclude the user is outdoors. It combines three weak signals — an on-device MobileNetV2 ImageNet classifier bucketed by keyword into outdoor/indoor (`scene_classifier.dart`), ARCore VPS availability, and raw GPS accuracy — and requires genuine *positive* evidence (confident outdoor CV score, confirmed VPS, or a tight GPS fix) rather than merely the absence of indoor evidence, since CV and VPS are inconclusive (`null`) far more often than they return a confident answer. The user can always bypass via "I'm outside — continue anyway".
- **Directional trail** (`_arrow` in `ar_screen.dart`): NOT real AR plane detection. It's a hand-rolled pinhole-camera projection — a vanishing point whose screen height tracks smoothed device pitch (from `_onAccel`), with a fixed list of trail distances (`_trailDistancesM`) projected toward it and bent sideways by the heading/bearing turn angle. Screen space reserved for the top/bottom chrome bars (`_topBarReservedH` / `_bottomBarReservedH`) is excluded from where the ground point and translation overlays can render, so OCR false-positives or a short trail can never visually collide with the nav bars.
- **POI tags** (`_poiWidgets`): nearby places (from `poi.dart`/`places_service.dart`, refetched when the user moves >150m) projected onto screen x-position by bearing-vs-heading difference within the assumed camera FOV (`_fov = 60°`), not true AR anchoring.
- **Sign translation** (`_translationWidgets`): throttled to ~1 frame per 1.2s (`_lastOcr`), boxes mapped from upright image space to the cover-fit screen rect.

### Translation: cloud-first, on-device fallback
`services/translation_service.dart` is the single entry point used by `ArScreen`. If `Env.hasGoogleApiKey` and there's network, it calls Cloud Vision (`DOCUMENT_TEXT_DETECTION`) + Cloud Translation v2 over REST; on any failure (no key, offline, quota, parse error) it falls through to on-device ML Kit (`sign_translator.dart`: `TextRecognizer` + `LanguageIdentifier` + `OnDeviceTranslator`, skipping blocks already in English). Both paths normalize to the same `TranslatedBlock` shape so `ArScreen` doesn't need to know which one served a frame.

### Places/routing/POI: Google-first, OSM fallback
Same pattern throughout `places_service.dart`, `routing.dart`, `poi.dart`: if `Env.hasGoogleApiKey` is false, or the Google Places API (New) call throws, fall back to free OpenStreetMap services (Nominatim for search, OSRM demo server for walking routes, Overpass for nearby POIs). This fallback path is what lets the app run with zero API key configured — worth keeping in mind when debugging "why didn't my Google quota get used."

### Native bridge
`lib/services/arcore_channel.dart` talks to `android/app/src/main/kotlin/.../ArCoreGeospatialChannel.kt` over a `MethodChannel` (`streetsight/arcore`) for ARCore VPS availability checks and signing-cert info (used to build `X-Android-Package`/`X-Android-Cert` headers for Android-restricted Google API keys, in `env.dart`). Any channel failure (missing plugin, unsupported device) must be treated as "unknown" (`null`), never coerced to `false` — the scene gate and callers rely on that distinction.

### Frame handling
Camera frames come in as NV21 (`ImageFormatGroup.nv21`). `frame_codec.dart` handles upright-rotation + JPEG encoding/resizing for the pieces that need it (Cloud Vision upload, scene classifier input). Sensor orientation is always passed through explicitly rather than assumed, since `swap = sensorOrientation % 180 == 90` determines whether width/height get swapped for the "upright" size.

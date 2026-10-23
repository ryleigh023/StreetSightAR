# StreetSight AR

Walking directions drawn onto the street in front of you, signs that translate themselves, and a quiet tag on what you pass — all through one camera view.

Flutter. Android is the verified target.

---

## What it does

**Two navigation modes**, chosen on the home screen. They cannot be combined: an ARCore session takes the camera exclusively, so live sign translation cannot run inside one.

| Mode | What it is | Needs |
| --- | --- | --- |
| **AR path** | Chevrons anchored to the real ground plane by ARCore. Tap the floor and the route is laid along it. | ARCore device |
| **Translate** | Route drawn over the camera feed, plus live sign translation and nearby place tags. | Any phone |

**Along the way**
- **Sign translation** — point at a sign and the words are replaced where they stand. Cloud Vision and Cloud Translation when a Google key is present, on-device ML Kit otherwise, including offline once a language pack is downloaded.
- **Storefront recognition** — the OCR already reads every sign in frame, so recognised text is matched against nearby places and the label is pinned to the shopfront the camera actually sees, rather than floating at a bearing estimate.
- **Place tags** — food, history and art near you, surfaced only once you are close enough to see them.

**Guidance that works with your eyes up**
- Spoken directions, one line per manoeuvre, in distance bands rather than exact metres so it never nags.
- Haptic turn cues, a firmer tap for a turn than for a straight on.
- A **tactile compass**: ticks quicken as the phone swings onto the route bearing, so you can follow a turn without looking at the screen at all.
- Pacing follows your measured walking speed — fourteen seconds between cues when standing still, four when hurrying.

**Honesty about what it knows**

Pose confidence is a first-class input to the interface, not a debug value. GPS accuracy, compass steadiness and AR tracking state combine into one score with three behaviours:

| Band | Behaviour |
| --- | --- |
| Solid | Full trail, no status text. A working system should not narrate itself. |
| Hint | Trail halved and dimmed. A long run of chevrons implies certainty about ground we have not localised. |
| Fallback | Nothing drawn on the world. A flat card and the spoken cue carry it, because those stay correct however lost the tracking is. |

A **turn preview cone** appears on the ground only inside the approach window and only where the route actually changes direction, so a long straight stays uncluttered.

---

## Running it

```bash
flutter pub get
flutter run
```

Needs camera and location permissions. The first-run walkthrough explains why before the system dialogs appear.

**No API key required.** Without one, search and routing fall back to OpenStreetMap (Nominatim, OSRM, Overpass) and translation runs entirely on-device. To use Google instead, copy `.env.example` to `.env` and set `GOOGLE_API_KEY` to a key with Places API (New), Cloud Vision and Cloud Translation enabled.

### Demoing it indoors

The product is unreviewable at a desk: GPS indoors does not move, a compass next to a laptop is nonsense, and every cue is driven by changes in both.

Turn on **Demo walk** in preferences. A simulator walks the real route on a timer and drives the actual navigation code — the trail advances, waypoints clear, turns are announced, the tactile compass responds, the arrival summary fires. An amber banner marks the position as simulated, and the setting is never persisted, so it cannot survive into a real walk.

---

## How the overlay is built

The AR path mode uses `ar_flutter_plugin_plus` with horizontal and vertical plane detection. Tapping a detected plane creates an `ARPlaneAnchor`, and chevrons are parented to that single anchor so they share one real-world frame and cannot drift apart. Hits on sparse feature points are ignored on purpose — anchoring to those is what makes AR arrows appear to float in mid-air.

The trail follows the route rather than a bearing. The remaining polyline is projected into AR-local metres, smoothed with a centripetal Catmull-Rom spline, then walked by arc length so spacing is even in metres rather than in curve parameter. Those differ sharply through a bend.

The Translate mode draws its own overlay with a pinhole camera projection from compass heading and device pitch. Pitch is clamped between 12 and 55 degrees, because a phone held upright collapses the ground plane onto the horizon and the whole trail turns into a cluster of specks.

---

## Layout

```
lib/
  screens/      home, onboarding, both navigation modes, preferences, arrival
  services/     routing, places, translation, scene gate, pose confidence,
                guidance, tactile compass, storefront matching, walk simulator
  widgets/      shared overlay pieces
  theme.dart    design tokens
assets/models/  MobileNetV2 scene classifier, ImageNet labels, chevron GLB
```

Both navigation screens, the overlay geometry and the fallback behaviour are documented inline where the reasoning is not obvious from the code.

---

## Known limits

- **No occlusion.** Overlays do not tuck behind people or vehicles. That needs the ARCore Depth API, which the Flutter plugin does not expose.
- **iOS is scaffolded but unverified.** Google ML Kit ships no arm64 simulator slice and Xcode 26 simulators are arm64-only, so the iOS simulator cannot run this at all. A physical device would be needed.
- **No test suite.** Verification is `flutter analyze` plus device testing.

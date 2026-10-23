import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'arcore_channel.dart';
import 'scene_classifier.dart';

/// "Am I actually on a street, not in my house" gate — combines three cheap
/// signals per the agreed B+C approach:
///  B. an on-device CV proxy classifier ([SceneClassifier])
///  C. ARCore's own VPS *coverage* check + raw GPS fix quality
///
/// None of the three is reliable alone. In particular, `checkVpsAvailability`
/// (see `ArCoreGeospatialChannel.kt`) is a purely geographic lookup — "does
/// this lat/lng have Street View-grade imagery" — it says nothing about
/// whether the camera is currently pointed outdoors. A VPS "available"
/// result from inside a building on a well-mapped street is completely
/// normal, so it is only ever used as *negative* evidence (no coverage +
/// bad GPS ⇒ probably indoors), never as positive proof of being outside.
/// GPS can likewise report deceptively tight accuracy indoors via WiFi-based
/// fused location, so a tight reading alone isn't trusted either unless it's
/// also fresh (not a stale fix carried over from when the user was last
/// actually outside).
class SceneGateResult {
  final bool outdoors;
  final String reason;
  final double? cvOutdoorScore;
  final bool? vpsAvailable;
  final double? gpsAccuracyM;
  const SceneGateResult(this.outdoors, this.reason, {this.cvOutdoorScore, this.vpsAvailable, this.gpsAccuracyM});
}

class SceneGate {
  final SceneClassifier classifier;
  SceneGate(this.classifier);

  Future<SceneGateResult> evaluate({
    required CameraImage frame,
    required int sensorOrientation,
    required Position position,
  }) async {
    final cv = await classifier.outdoorScore(frame, sensorOrientation);
    final vps = await ArCoreGeospatial.checkVpsAvailability(position.latitude, position.longitude);
    final acc = position.accuracy;

    // Strong CV signal pointing indoors overrides everything else.
    if (cv != null && cv < 0.3) {
      return SceneGateResult(false, 'This looks like an indoor space.', cvOutdoorScore: cv, vpsAvailable: vps, gpsAccuracyM: acc);
    }
    // No ARCore VPS coverage *and* a poor GPS fix together strongly suggest
    // indoors (outdoors, GPS alone is usually within ~15-30m).
    if (vps == false && acc > 50) {
      return SceneGateResult(false, 'No GPS/VPS signal — are you indoors?', cvOutdoorScore: cv, vpsAvailable: vps, gpsAccuracyM: acc);
    }
    // The checks above only catch *active* evidence of indoors. In practice
    // CV is "null" (inconclusive) for most rooms — it only recognises a
    // handful of ImageNet appliance/furniture classes — so inconclusive must
    // NOT default to "outdoors", or any indoor scene with nothing on the
    // indoor keyword list sails straight through. We require at least one
    // real positive outdoor signal to unlock. VPS "available" is NOT one of
    // them — it's a geographic coverage flag (see class doc), true just as
    // often from inside a building as from the street in front of it. A
    // tight GPS accuracy isn't enough alone either, since WiFi-based fused
    // location can report misleadingly good accuracy indoors — it also has
    // to be a *fresh* fix, not one carried over from when the device was
    // last genuinely outside.
    final strongCvOutdoor = cv != null && cv >= 0.55;
    final fixAgeS = DateTime.now().toUtc().difference(position.timestamp.toUtc()).inSeconds.abs();
    final freshTightGpsFix = acc <= 20 && fixAgeS <= 5;
    if (!strongCvOutdoor && !freshTightGpsFix) {
      return SceneGateResult(false, "Can't confirm you're outside yet.", cvOutdoorScore: cv, vpsAvailable: vps, gpsAccuracyM: acc);
    }
    return SceneGateResult(true, 'Outdoors', cvOutdoorScore: cv, vpsAvailable: vps, gpsAccuracyM: acc);
  }
}

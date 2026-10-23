import 'dart:math' as math;

/// How much the overlay is allowed to claim right now.
///
/// The governing idea, borrowed from how shipping AR navigators behave: pose
/// confidence is a first-class input to the interface, not a debug value.
/// When we are not sure where the user is or which way they face, the honest
/// response is to show *less* and say more, rather than render a confident
/// arrow that happens to point at a wall.
enum PoseBand {
  /// Anchored overlay is trustworthy. Full trail, full opacity.
  solid,

  /// Something is off — weak fix, no plane lock, erratic compass. Show a
  /// thinned, dimmed trail as a hint, and never imply precision.
  hint,

  /// Not good enough to draw on the world. Fall back to a flat card and
  /// spoken guidance, which stay correct regardless of pose.
  fallback,
}

class PoseConfidence {
  /// 0..1. Deliberately a blend rather than a single sensor: any one signal
  /// is routinely unavailable, and treating "unknown" as "bad" would park
  /// the app permanently in fallback.
  final double score;
  final PoseBand band;

  /// Short, user-facing reason for the current band. Empty when solid —
  /// a working system should not narrate itself.
  final String reason;

  const PoseConfidence(this.score, this.band, this.reason);

  static const unknown = PoseConfidence(0.45, PoseBand.hint, 'Finding your position');

  /// [gpsAccuracyM] is the reported horizontal accuracy; null when no fix.
  /// [hasHeading] is whether the compass is producing usable bearings.
  /// [tracking] is the AR runtime's own view, where there is one: true for
  /// a locked plane or normal tracking, false for limited, null when the
  /// screen has no AR session at all.
  /// [headingJitterDeg] is recent compass variability — a needle swinging
  /// through tens of degrees while standing still means magnetic
  /// interference, and bearing-derived overlays cannot be trusted.
  factory PoseConfidence.from({
    required double? gpsAccuracyM,
    required bool hasHeading,
    bool? tracking,
    double headingJitterDeg = 0,
  }) {
    // GPS term. 5 m or better is as good as a phone gets in a street;
    // beyond 40 m the position is barely better than a guess.
    final gps = gpsAccuracyM == null
        ? 0.0
        : (1 - ((gpsAccuracyM - 5) / 35)).clamp(0.0, 1.0).toDouble();

    // Compass term, penalised by jitter rather than by absence alone.
    final heading = !hasHeading ? 0.0 : (1 - (headingJitterDeg / 45)).clamp(0.0, 1.0).toDouble();

    // AR tracking, when there is any. Unknown is treated as neutral, not bad.
    final track = tracking == null ? 0.5 : (tracking ? 1.0 : 0.15);

    // Weighted toward GPS and tracking: a good compass cannot rescue a
    // position that is 60 m out, but a tight fix with a shaky needle still
    // supports a usable trail.
    final score = (gps * 0.4 + heading * 0.25 + track * 0.35).clamp(0.0, 1.0).toDouble();

    final band = score > 0.7
        ? PoseBand.solid
        : score > 0.4
            ? PoseBand.hint
            : PoseBand.fallback;

    final reason = switch (band) {
      PoseBand.solid => '',
      PoseBand.hint => tracking == false
          ? 'Still locking onto the ground'
          : headingJitterDeg > 25
              ? 'Compass is unsteady here'
              : 'Weak position fix',
      PoseBand.fallback => gpsAccuracyM == null
          ? 'Waiting for a position fix'
          : tracking == false
              ? 'Cannot see the ground well enough'
              : 'Signal is too weak to place the path',
    };
    return PoseConfidence(score, band, reason);
  }

  /// How much of the trail to draw. Showing a shorter trail when unsure is
  /// the cheapest way to stop over-claiming: a long run of chevrons reads as
  /// certainty about ground we have not actually localised.
  double get trailFraction => switch (band) {
        PoseBand.solid => 1.0,
        PoseBand.hint => 0.5,
        PoseBand.fallback => 0.0,
      };

  double get overlayOpacity => switch (band) {
        PoseBand.solid => 1.0,
        PoseBand.hint => 0.6,
        PoseBand.fallback => 0.0,
      };

  bool get usesFallbackCard => band == PoseBand.fallback;
}

/// Rolling compass jitter, in degrees.
///
/// A phone held still should report a near-constant bearing. Spread across a
/// short window is a decent proxy for magnetic interference, which is common
/// next to cars, railings and reinforced concrete and is invisible to any
/// accuracy number the platform reports.
class HeadingJitter {
  final _recent = <double>[];
  static const _window = 12;

  void add(double headingDeg) {
    _recent.add(headingDeg);
    if (_recent.length > _window) _recent.removeAt(0);
  }

  /// Circular spread, so the 359°/0° wrap does not read as a 359° swing.
  double get degrees {
    if (_recent.length < 4) return 0;
    var sx = 0.0, sy = 0.0;
    for (final h in _recent) {
      final r = h * math.pi / 180;
      sx += math.cos(r);
      sy += math.sin(r);
    }
    final r = math.sqrt(sx * sx + sy * sy) / _recent.length;
    // Circular standard deviation, converted to degrees.
    if (r >= 1) return 0;
    return math.sqrt(-2 * math.log(r)) * 180 / math.pi;
  }
}

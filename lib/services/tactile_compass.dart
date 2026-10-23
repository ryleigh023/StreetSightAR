import 'dart:async';

import 'package:flutter/services.dart';

import 'settings.dart';

/// Heading feedback through the vibration motor alone.
///
/// Borrowed from indoor AR work that uses haptics as a tactile compass: the
/// phone ticks faster the closer it points to the way you should go, and
/// gives one firm pulse the moment you land on it. The value is that it
/// closes the loop without the screen — you can hold the phone at your side,
/// sweep until it quickens, and walk. That matters for bright sunlight, for
/// anyone who would rather not stare at a display while crossing a road, and
/// for low vision users for whom the overlay is not the primary channel.
///
/// Silence is load-bearing here. Buzzing constantly while someone faces
/// entirely the wrong way teaches them to ignore it, so beyond a wide
/// threshold the motor stays still and only the spoken cue carries.
class TactileCompass {
  Timer? _timer;
  double _turnDeg = 180;
  bool _wasAligned = false;

  /// Beyond this the phone is not meaningfully pointed at the route and the
  /// motor stays quiet.
  static const _silentBeyondDeg = 75.0;

  /// Inside this counts as on-bearing.
  static const _alignedWithinDeg = 12.0;

  void start() {
    stop();
    // Re-evaluated often; the tick itself decides whether to fire, so the
    // cadence can change smoothly as the user sweeps the phone.
    _timer = Timer.periodic(const Duration(milliseconds: 90), (_) => _maybePulse());
  }

  /// Signed angle from where the phone points to where the route goes.
  void update(double turnDeg) => _turnDeg = turnDeg;

  DateTime _lastPulse = DateTime.fromMillisecondsSinceEpoch(0);

  void _maybePulse() {
    if (!settings.tactileCompass || !settings.haptics) return;

    final off = _turnDeg.abs();
    if (off > _silentBeyondDeg) {
      _wasAligned = false;
      return;
    }

    final aligned = off <= _alignedWithinDeg;

    // One firm pulse on arriving at the bearing, rather than a continuing
    // stream — the event is "you found it", not "you are still on it".
    if (aligned && !_wasAligned) {
      _wasAligned = true;
      _lastPulse = DateTime.now();
      HapticFeedback.mediumImpact();
      return;
    }
    if (!aligned) _wasAligned = false;

    // Otherwise tick like a proximity meter: ~1 Hz when barely warm,
    // ~6 Hz just before alignment.
    final warmth = 1 - (off / _silentBeyondDeg); // 0..1
    final intervalMs = (900 - warmth * 740).round();
    if (DateTime.now().difference(_lastPulse).inMilliseconds < intervalMs) return;

    _lastPulse = DateTime.now();
    HapticFeedback.selectionClick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _wasAligned = false;
  }
}

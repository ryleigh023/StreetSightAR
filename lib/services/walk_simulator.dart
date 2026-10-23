import 'dart:async';
import 'dart:math' as math;

import 'geo.dart';

/// One simulated fix: where you are, which way you face, how fast you move.
typedef SimFix = ({LatLng pos, double heading, double speedMs, double accuracyM});

/// Walks a route on a timer so the whole experience can be shown without
/// actually going outside.
///
/// This exists because the product is unreviewable at a desk. GPS indoors
/// does not move, the compass near a laptop is nonsense, and every cue in
/// the app is driven by changes in both. Rather than demonstrate a frozen
/// screen and describe what would happen, this drives the real navigation
/// code with plausible fixes: the trail advances, waypoints clear, turns are
/// announced, the arrival sheet fires. Nothing downstream knows the
/// difference, which is the point — it exercises the actual code path
/// instead of a mock of it.
class WalkSimulator {
  final List<LatLng> path;
  final double speedMs;

  /// How often a fix is emitted. Faster than real GPS, because the demo
  /// should look smooth rather than realistic.
  static const _tick = Duration(milliseconds: 250);

  StreamController<SimFix>? _ctl;
  Timer? _timer;
  double _travelled = 0;
  late final List<double> _cum; // cumulative distance at each vertex

  WalkSimulator(this.path, {this.speedMs = 1.6}) {
    _cum = [0];
    for (var i = 0; i < path.length - 1; i++) {
      _cum.add(_cum.last + distanceM(path[i], path[i + 1]));
    }
  }

  double get totalM => _cum.isEmpty ? 0 : _cum.last;

  Stream<SimFix> start() {
    stop();
    final ctl = _ctl = StreamController<SimFix>.broadcast();
    _travelled = 0;
    _timer = Timer.periodic(_tick, (_) {
      if (path.length < 2) return;
      _travelled += speedMs * _tick.inMilliseconds / 1000;

      // Hold at the destination rather than looping: the arrival state is
      // part of what needs demonstrating.
      final done = _travelled >= totalM;
      final d = done ? totalM : _travelled;

      final at = _pointAt(d);
      final ahead = _pointAt(math.min(d + 2.0, totalM));
      final heading = bearingDeg(at, ahead);

      ctl.add((
        pos: at,
        heading: heading,
        speedMs: done ? 0 : speedMs,
        // A believable urban fix. Deliberately not 1 m: the confidence
        // engine should sit in its normal band during a demo, not an
        // artificially perfect one.
        accuracyM: 8,
      ));
      if (done) stop();
    });
    return ctl.stream;
  }

  LatLng _pointAt(double d) {
    if (path.length < 2) return path.first;
    for (var i = 0; i < _cum.length - 1; i++) {
      if (d <= _cum[i + 1]) {
        final segLen = _cum[i + 1] - _cum[i];
        final t = segLen <= 0 ? 0.0 : (d - _cum[i]) / segLen;
        return LatLng(
          path[i].lat + (path[i + 1].lat - path[i].lat) * t,
          path[i].lng + (path[i + 1].lng - path[i].lng) * t,
        );
      }
    }
    return path.last;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _ctl?.close();
    _ctl = null;
  }
}

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'settings.dart';

/// Spoken and felt turn cues.
///
/// The point of a walking navigator is that you can keep your eyes on the
/// street. Announcements are therefore deliberately sparse: one line per
/// manoeuvre, repeated only when the instruction or the distance band
/// actually changes, so it never nags.
class Guidance {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  /// What was last announced, so an unchanged instruction stays quiet.
  String? _lastSpoken;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum gap between two announcements, whatever changes in between.
  /// Scaled by walking speed: at a stroll the same cue arriving every six
  /// seconds is nagging, while at pace it can arrive too late to act on.
  static const _baseGap = Duration(seconds: 6);
  Duration _gapFor(double speedMs) {
    if (speedMs <= 0.3) return const Duration(seconds: 14); // standing still
    if (speedMs < 0.9) return const Duration(seconds: 9); // ambling
    if (speedMs > 2.0) return const Duration(seconds: 4); // hurrying
    return _baseGap;
  }

  Future<void> init() async {
    if (_ready) return;
    try {
      await _tts.setSpeechRate(0.48); // platform default is hurried for street use
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      _ready = true;
    } catch (_) {
      _ready = false; // no engine on this device; cues degrade to haptics
    }
  }

  /// Distance band rather than exact metres: re-announcing every metre would
  /// be unbearable, and "in 40 metres" is no more useful than "in 50".
  static String _band(double m) {
    if (m < 15) return 'now';
    if (m < 40) return 'in 30 metres';
    if (m < 80) return 'in 50 metres';
    if (m < 150) return 'in 100 metres';
    return 'in ${(m / 100).round() * 100} metres';
  }

  /// Announce the current manoeuvre. Safe to call every frame.
  Future<void> announce({
    required String instruction,
    required double distanceM,
    required bool arrived,
    double speedMs = 1.3,
  }) async {
    if (!settings.voice && !settings.haptics) return;

    final line = arrived ? 'You have arrived' : '$instruction, ${_band(distanceM)}';
    if (line == _lastSpoken) return;
    if (DateTime.now().difference(_lastAt) < _gapFor(speedMs)) return;

    _lastSpoken = line;
    _lastAt = DateTime.now();

    if (settings.haptics) {
      // A turn is worth a firmer tap than a plain "keep going".
      final turning = instruction.toLowerCase().contains('turn');
      await (arrived || turning ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick());
    }
    if (settings.voice && _ready) {
      await _tts.stop(); // drop a stale announcement rather than queueing behind it
      await _tts.speak(line);
    }
  }

  /// One-off line, for things that are not manoeuvres (arrival, route found).
  Future<void> say(String line) async {
    if (!settings.voice || !_ready) return;
    await _tts.stop();
    await _tts.speak(line);
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'geo.dart';
import 'poi.dart';

/// A sign in the camera frame that we believe belongs to a known place.
class StorefrontMatch {
  final Rect box; // where the sign sits, in upright image coordinates
  final Poi poi;
  final String readText; // what the OCR actually saw
  final double score; // 0..1
  final double distanceM;
  const StorefrontMatch({
    required this.box,
    required this.poi,
    required this.readText,
    required this.score,
    required this.distanceM,
  });
}

/// Ties the two vision pipelines that were already running to the place data
/// that was already being fetched.
///
/// The app reads every sign in frame for translation, and separately knows
/// which places are nearby from Places or Overpass. Neither knew about the
/// other, so a POI tag floated at a position estimated purely from bearing
/// and assumed field of view — frequently several metres off the shop it
/// referred to. Matching the recognised text to a nearby place name lets the
/// label be pinned to the actual storefront in the image instead.
///
/// The matching is deliberately strict. A wrong label confidently placed on
/// the wrong building is worse than no label, so a candidate has to clear a
/// high bar on both token overlap and edit distance before it is shown.
class StorefrontMatcher {
  /// Signs further than this from any known place are not worth testing:
  /// a shop name read at 200 m is almost certainly a different branch.
  static const _maxDistanceM = 120.0;

  /// Minimum combined score to accept a match.
  static const _minScore = 0.62;

  /// Strips case, punctuation and the corporate noise that appears on
  /// signage but rarely in place data ("Ltd", "Pvt", "&", "Co").
  static String normalise(String s) {
    final cleaned = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\b(ltd|limited|pvt|private|inc|llc|co|the|and)\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  /// Levenshtein ratio, 0..1. Used alongside token overlap because OCR
  /// errors are usually character-level ("Starhucks"), which token overlap
  /// alone scores as a total miss.
  static double _editRatio(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    final m = a.length, n = b.length;
    var prev = List<int>.generate(n + 1, (i) => i);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final t = prev;
      prev = cur;
      cur = t;
    }
    return 1 - prev[n] / math.max(m, n);
  }

  /// Fraction of the place's own words that appear in the sign. Weighted
  /// this way round on purpose: a sign often carries extra words ("Cafe
  /// Coffee Day — Since 1996"), but a place name rarely carries words the
  /// sign omits.
  static double _tokenOverlap(String sign, String place) {
    final signTokens = sign.split(' ').where((t) => t.length > 2).toSet();
    final placeTokens = place.split(' ').where((t) => t.length > 2).toList();
    if (placeTokens.isEmpty || signTokens.isEmpty) return 0;
    var hit = 0;
    for (final pt in placeTokens) {
      // A token counts if any sign token is close to it, which absorbs
      // single-character OCR slips inside otherwise correct words.
      if (signTokens.any((st) => st == pt || _editRatio(st, pt) > 0.8)) hit++;
    }
    return hit / placeTokens.length;
  }

  /// Best match for one recognised sign, or null if nothing clears the bar.
  static StorefrontMatch? match({
    required Rect box,
    required String text,
    required LatLng me,
    required List<Poi> nearby,
  }) {
    final sign = normalise(text);
    if (sign.length < 3) return null;

    StorefrontMatch? best;
    for (final poi in nearby) {
      final d = distanceM(me, poi.pos);
      if (d > _maxDistanceM) continue;

      final place = normalise(poi.name);
      if (place.isEmpty) continue;

      final overlap = _tokenOverlap(sign, place);
      final edit = _editRatio(sign, place);

      // Overlap carries most of the weight; edit distance rescues names the
      // OCR garbled rather than split.
      var score = overlap * 0.7 + edit * 0.3;

      // Nearer places are likelier to be the one whose sign fills the frame.
      score *= 1 - (d / _maxDistanceM) * 0.25;

      if (score < _minScore) continue;
      if (best == null || score > best.score) {
        best = StorefrontMatch(box: box, poi: poi, readText: text.trim(), score: score, distanceM: d);
      }
    }
    return best;
  }

  /// Matches a whole frame, keeping at most one label per place so a shop
  /// whose name appears on both an awning and a window does not get tagged
  /// twice.
  static List<StorefrontMatch> matchFrame({
    required List<(Rect, String)> signs,
    required LatLng me,
    required List<Poi> nearby,
  }) {
    final byPlace = <String, StorefrontMatch>{};
    for (final (box, text) in signs) {
      final m = match(box: box, text: text, me: me, nearby: nearby);
      if (m == null) continue;
      final key = m.poi.name;
      if (!byPlace.containsKey(key) || m.score > byPlace[key]!.score) {
        byPlace[key] = m;
      }
    }
    return byPlace.values.toList()..sort((a, b) => b.score.compareTo(a.score));
  }
}

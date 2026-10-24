import 'dart:math' as math;

class LatLng {
  final double lat, lng;
  const LatLng(this.lat, this.lng);
}

double _rad(double d) => d * math.pi / 180;
double _deg(double r) => r * 180 / math.pi;

/// Distance in metres (haversine).
double distanceM(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = _rad(b.lat - a.lat), dLng = _rad(b.lng - a.lng);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Initial bearing a -> b in degrees [0, 360).
double bearingDeg(LatLng a, LatLng b) {
  final dLng = _rad(b.lng - a.lng);
  final y = math.sin(dLng) * math.cos(_rad(b.lat));
  final x = math.cos(_rad(a.lat)) * math.sin(_rad(b.lat)) -
      math.sin(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.cos(dLng);
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

/// Smallest signed angle from [from] to [to], in (-180, 180].
double angleDiff(double from, double to) {
  var d = (to - from) % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/// Distance still to walk along [pts], starting from [me] and the vertex at
/// [fromIdx].
///
/// Straight-line distance to the destination is the wrong headline number
/// for navigation: a real walking route detours around blocks, dual
/// carriageways and crossings, so the crow-flies figure can climb for
/// hundreds of metres while you are walking correctly. Measured along the
/// route it falls monotonically, which is what a walker expects and what
/// every shipped navigator shows.
double remainingAlongRoute(List<LatLng> pts, LatLng me, int fromIdx) {
  if (pts.isEmpty) return 0;
  final i = fromIdx.clamp(0, pts.length - 1);
  var total = distanceM(me, pts[i]);
  for (var k = i; k < pts.length - 1; k++) {
    total += distanceM(pts[k], pts[k + 1]);
  }
  return total;
}

import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'geo.dart';

const _ua = {'User-Agent': 'StreetSightAR/1.0 (hackathon prototype)'};

class Place {
  final String name;
  final LatLng pos;
  Place(this.name, this.pos);
}

class WalkRoute {
  final List<LatLng> points;
  final double distanceM;
  final double durationS;
  WalkRoute(this.points, this.distanceM, this.durationS);
}

/// Fallback geocoder (OpenStreetMap Nominatim) used when the Google Places
/// API key is absent or the Places request fails — see [places_service.dart].
Future<List<Place>> osmSearchPlaces(String q, {LatLng? near}) async {
  // Walking search is useless without a location bias. Unbiased, a query
  // like "cafe" returns a café in Niger before one on your street, because
  // Nominatim ranks by prominence over the whole planet.
  //
  // Two passes: first bounded to a box the user could plausibly walk or
  // ride to, then unbounded if that finds nothing — so searching for a
  // named landmark in another city still works.
  Future<List<Place>> run(Map<String, String> extra) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search',
        {'q': q, 'format': 'json', 'limit': '8', ...extra});
    final res = await http.get(uri, headers: _ua).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw Exception('Search failed (${res.statusCode})');
    return (jsonDecode(res.body) as List)
        .map((e) => Place(e['display_name'] as String,
            LatLng(double.parse(e['lat']), double.parse(e['lon']))))
        .toList();
  }

  if (near != null) {
    // ~12 km box. Degrees of longitude shrink with latitude, so the box is
    // corrected by cos(lat) or it becomes a thin sliver near the poles.
    const spanKm = 12.0;
    final dLat = spanKm / 110.574;
    final dLng = spanKm / (111.320 * math.cos(near.lat * math.pi / 180).abs().clamp(0.05, 1.0));
    final box = '${near.lng - dLng},${near.lat - dLat},${near.lng + dLng},${near.lat + dLat}';
    final local = await run({'viewbox': box, 'bounded': '1'});
    if (local.isNotEmpty) {
      local.sort((a, b) => distanceM(near, a.pos).compareTo(distanceM(near, b.pos)));
      return local;
    }
  }
  final any = await run(near == null ? const {} : {'viewbox': '', 'bounded': '0'});
  if (near != null) {
    any.sort((a, b) => distanceM(near, a.pos).compareTo(distanceM(near, b.pos)));
  }
  return any;
}

/// Walking route via the public OSRM demo server.
Future<WalkRoute> walkingRoute(LatLng from, LatLng to) async {
  final uri = Uri.parse('https://routing.openstreetmap.de/routed-foot/route/v1/foot/'
      '${from.lng},${from.lat};${to.lng},${to.lat}?overview=full&geometries=geojson');
  final res = await http.get(uri, headers: _ua).timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) throw Exception('Routing failed (${res.statusCode})');
  final r = (jsonDecode(res.body)['routes'] as List).first;
  final pts = (r['geometry']['coordinates'] as List)
      .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
      .toList();
  return WalkRoute(pts, (r['distance'] as num).toDouble(), (r['duration'] as num).toDouble());
}

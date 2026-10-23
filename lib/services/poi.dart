import 'dart:convert';
import 'package:http/http.dart' as http;
import 'geo.dart';

enum Interest { food, history, art }

extension InterestX on Interest {
  String get label => const {Interest.food: 'Food', Interest.history: 'History', Interest.art: 'Art'}[this]!;
  String get emoji => const {Interest.food: '🍜', Interest.history: '🏛️', Interest.art: '🎨'}[this]!;
  String get osmFilter => switch (this) {
        Interest.food => '["amenity"~"restaurant|cafe|fast_food|street_food"]',
        Interest.history => '["historic"]',
        Interest.art => '["tourism"~"artwork|gallery|museum"]',
      };

  /// Google Places API (New) `includedTypes` for this interest.
  /// https://developers.google.com/maps/documentation/places/web-service/place-types
  List<String> get placeTypes => switch (this) {
        Interest.food => const ['restaurant', 'cafe', 'bakery'],
        Interest.history => const ['historical_landmark', 'monument', 'tourist_attraction'],
        Interest.art => const ['art_gallery', 'museum'],
      };
}

class Poi {
  final String name;
  final Interest kind;
  final LatLng pos;
  Poi(this.name, this.kind, this.pos);
}

/// Fallback nearby-POI lookup (OpenStreetMap Overpass) used when the Google
/// Places API key is absent or the Places request fails — see
/// [places_service.dart].
Future<List<Poi>> osmNearbyPois(LatLng c, Set<Interest> interests, {int radius = 400}) async {
  if (interests.isEmpty) return [];
  final q = StringBuffer('[out:json][timeout:15];(');
  for (final i in interests) {
    q.write('node${i.osmFilter}["name"](around:$radius,${c.lat},${c.lng});');
  }
  q.write(');out 40;');
  final res = await http
      .post(Uri.parse('https://overpass-api.de/api/interpreter'), body: {'data': q.toString()})
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) return [];
  final out = <Poi>[];
  for (final e in jsonDecode(res.body)['elements'] as List) {
    final tags = e['tags'] as Map;
    final kind = interests.firstWhere((i) => switch (i) {
          Interest.food => tags.containsKey('amenity'),
          Interest.history => tags.containsKey('historic'),
          Interest.art => tags.containsKey('tourism'),
        });
    out.add(Poi(tags['name'], kind, LatLng((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble())));
  }
  return out;
}

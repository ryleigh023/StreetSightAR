import 'dart:convert';
import 'package:http/http.dart' as http;
import 'env.dart';
import 'geo.dart';
import 'poi.dart';
import 'routing.dart';

/// Google Places API (New) place search, matching the deck's tech stack.
/// Falls back to OpenStreetMap (osmSearchPlaces/osmNearbyPois) whenever no
/// API key is configured or the Google call itself fails (offline, quota,
/// region not covered, etc.) — see `places_service` usage in the screens.

/// Text search → candidate destinations for the home-screen search box.
/// Primary: Places API (New) `places:searchText`. Fallback: Nominatim.
Future<List<Place>> searchPlaces(String q, {LatLng? near}) async {
  if (!Env.hasGoogleApiKey) return osmSearchPlaces(q, near: near);
  try {
    final res = await http
        .post(
          Uri.parse('https://places.googleapis.com/v1/places:searchText'),
          headers: {
            ...Env.googleHeaders,
            'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,places.location',
          },
          body: jsonEncode({
            'textQuery': q,
            'pageSize': 8,
            // Bias toward where the user actually is. Without this a
            // one-word query like "coffee" is answered globally.
            if (near != null)
              'locationBias': {
                'circle': {
                  'center': {'latitude': near.lat, 'longitude': near.lng},
                  'radius': 8000.0,
                }
              },
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('Places searchText failed (${res.statusCode})');
    final places = (jsonDecode(res.body)['places'] as List?) ?? const [];
    if (places.isEmpty) return [];
    final out = places.map((p) {
      final name = p['displayName']?['text'] ?? p['formattedAddress'] ?? 'Unnamed place';
      final loc = p['location'];
      return Place(name, LatLng((loc['latitude'] as num).toDouble(), (loc['longitude'] as num).toDouble()));
    }).toList();
    if (near != null) {
      out.sort((a, b) => distanceM(near, a.pos).compareTo(distanceM(near, b.pos)));
    }
    return out;
  } catch (_) {
    // Network/quota/parse failure → OSM fallback so search still works.
    return osmSearchPlaces(q, near: near);
  }
}

/// Nearby POIs matching the user's interests, around [c].
/// Primary: Places API (New) `places:searchNearby`. Fallback: Overpass.
Future<List<Poi>> nearbyPois(LatLng c, Set<Interest> interests, {int radius = 400}) async {
  if (interests.isEmpty) return [];
  if (!Env.hasGoogleApiKey) return osmNearbyPois(c, interests, radius: radius);
  try {
    final out = <Poi>[];
    // One request per interest: searchNearby's includedTypes don't carry
    // enough info in the response to map a result back to which interest
    // triggered it, so we keep the kind unambiguous by querying separately.
    for (final interest in interests) {
      final res = await http
          .post(
            Uri.parse('https://places.googleapis.com/v1/places:searchNearby'),
            headers: {
              ...Env.googleHeaders,
              'X-Goog-FieldMask': 'places.displayName,places.location',
            },
            body: jsonEncode({
              'includedTypes': interest.placeTypes,
              'maxResultCount': 10,
              'locationRestriction': {
                'circle': {
                  'center': {'latitude': c.lat, 'longitude': c.lng},
                  'radius': radius.toDouble(),
                }
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) continue;
      for (final p in (jsonDecode(res.body)['places'] as List?) ?? const []) {
        final loc = p['location'];
        out.add(Poi(
          p['displayName']?['text'] ?? 'Unnamed place',
          interest,
          LatLng((loc['latitude'] as num).toDouble(), (loc['longitude'] as num).toDouble()),
        ));
      }
    }
    return out;
  } catch (_) {
    return osmNearbyPois(c, interests, radius: radius);
  }
}

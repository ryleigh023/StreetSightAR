import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'connectivity.dart';
import 'env.dart';
import 'frame_codec.dart';

/// What the vision model concluded about a dish in the camera frame.
class FoodResult {
  final String name; // dish name, in English
  final String? localName; // original-language name, if different
  final String description;
  final List<String> ingredients;
  final List<String> allergens;
  final String? origin; // region / culture it is traditional to
  const FoodResult({
    required this.name,
    this.localName,
    required this.description,
    this.ingredients = const [],
    this.allergens = const [],
    this.origin,
  });
}

class FoodServiceException implements Exception {
  final String message;
  FoodServiceException(this.message);
  @override
  String toString() => message;
}

/// Identifies traditional dishes in a camera frame via an OpenAI vision model.
/// Cloud-only: there is no on-device fallback, so callers get a
/// [FoodServiceException] with a user-presentable message when it can't run.
/// Returns null when the model sees no food in the frame.
class FoodService {
  static const _model = 'gpt-4o-mini';
  static const _maxWidth = 768;

  Future<FoodResult?> identify(CameraImage image, int sensorOrientation, {double? lat, double? lng, String? destination}) async {
    if (!Env.hasOpenAiApiKey) throw FoodServiceException('Add OPENAI_API_KEY to .env to identify food.');
    if (!await hasNetworkLink()) throw FoodServiceException('No internet connection.');

    final jpeg = uprightJpeg(image, sensorOrientation, maxWidth: _maxWidth);
    final where = StringBuffer();
    if (lat != null && lng != null) {
      where.write(' GPS position of the user: ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}.');
    }
    if (destination != null) where.write(' They are heading to: $destination.');
    final regionPrior = where.isEmpty
        ? ''
        : '$where Use the local region only as a soft prior to choose between look-alike dishes '
            '(for example, in South India a bowl of thin tamarind-tomato broth is more likely rasam than '
            'tomato soup, and a lentil-vegetable stew is likely sambar). The photo is always the primary '
            'evidence: never force a local dish onto something that clearly looks like something else, and '
            'name globally recognisable food (pasta, pizza, burgers, sushi) correctly wherever the user is. ';
    final res = await http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${Env.openAiApiKey}',
          },
          body: jsonEncode({
            'model': _model,
            'temperature': 0.2,
            'response_format': {'type': 'json_object'},
            'messages': [
              {
                'role': 'system',
                'content': 'You help tourists recognise traditional cuisine from a camera photo.$regionPrior'
                    'Identify the main food in the photo: a prepared dish, snack, drink, fruit, vegetable or any other edible item. Reply with JSON only: '
                    '{"seen": "brief list of the objects you see", "food_found": bool, "name": "English dish name", "local_name": "name in its original '
                    'language/script or null", "description": "one or two sentences a tourist would find '
                    'useful (what it is, how it tastes, how it is eaten)", "ingredients": ["main ingredients"], '
                    '"allergens": ["common allergens likely present, e.g. peanuts, shellfish, gluten, dairy"], '
                    '"origin": "region or culture it is traditional to, or null"}. '
                    'Raw vegetables, fruit, herbs, spices and single ingredients all count as food: name them (e.g. tomato, onion) and describe them for a tourist. Only set food_found to false if nothing edible is visible. If unsure of the exact dish, give your best '
                    'guess and say so in the description.',
              },
              {
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': 'What dish is this?'},
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(jpeg)}', 'detail': 'low'},
                  },
                ],
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (res.statusCode != 200) {
      throw FoodServiceException(res.statusCode == 401 || res.statusCode == 429
          ? 'OpenAI rejected the request (${res.statusCode}) — check the key and quota.'
          : 'Food lookup failed (${res.statusCode}).');
    }

    debugPrint('[food] ${res.body}');
    debugPrint('[food] usage: ${jsonDecode(res.body)['usage']}');
    final Map<String, dynamic> data;
    try {
      final content = jsonDecode(res.body)['choices'][0]['message']['content'] as String;
      data = jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      throw FoodServiceException('Could not read the food lookup response.');
    }
    final seen = data['seen']?.toString().trim() ?? '';
    final noFood = FoodServiceException(
        seen.isEmpty ? 'No food spotted — point the camera at a dish and try again.' : 'No food spotted. I saw: $seen');
    if (data['food_found'] != true) throw noFood;

    List<String> strings(Object? v) => (v as List?)?.map((e) => e.toString()).toList() ?? const [];
    String? optional(Object? v) {
      final s = v?.toString().trim();
      return (s == null || s.isEmpty || s == 'null') ? null : s;
    }

    final name = optional(data['name']);
    if (name == null) throw noFood;
    return FoodResult(
      name: name,
      localName: optional(data['local_name']),
      description: optional(data['description']) ?? '',
      ingredients: strings(data['ingredients']),
      allergens: strings(data['allergens']),
      origin: optional(data['origin']),
    );
  }
}

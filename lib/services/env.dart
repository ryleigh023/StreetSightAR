import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Loads `.env` (see `.env.example`) and exposes the Google Cloud API key
/// used for Places API (New), Cloud Vision and Cloud Translation.
class Env {
  static Map<String, String> _androidHeaders = const {};

  static Future<void> load() async {
    await dotenv.load(fileName: '.env');
    // An Android-app-restricted key only accepts REST calls that identify
    // the calling app; fetch package + signing SHA-1 from the native side.
    try {
      final info = await const MethodChannel('streetsight/arcore').invokeMapMethod<String, String?>('signingInfo');
      final pkg = info?['package'], sha1 = info?['sha1'];
      if (pkg != null && sha1 != null) {
        _androidHeaders = {'X-Android-Package': pkg, 'X-Android-Cert': sha1};
      }
    } catch (_) {
      // Unrestricted keys work without these headers.
    }
  }

  static String get googleApiKey => dotenv.get('GOOGLE_API_KEY', fallback: '');

  static bool get hasGoogleApiKey =>
      googleApiKey.isNotEmpty && googleApiKey != 'PUT_YOUR_KEY_HERE' && googleApiKey != 'your_google_cloud_api_key_here';

  static String get openAiApiKey => dotenv.get('OPENAI_API_KEY', fallback: '');

  static bool get hasOpenAiApiKey => openAiApiKey.isNotEmpty && openAiApiKey != 'your_openai_api_key_here';

  /// Headers for every Google REST call (Places / Vision / Translate).
  static Map<String, String> get googleHeaders => {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': googleApiKey,
        ..._androidHeaders,
      };
}

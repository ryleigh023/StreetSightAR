import 'package:flutter/services.dart';

/// Bridge to the native Android ARCore Geospatial check — see
/// `android/app/src/main/kotlin/.../ArCoreGeospatialChannel.kt`.
/// Any failure (ARCore not installed, device unsupported, plugin not yet
/// built into this binary) is treated as "unknown", never as "indoors" —
/// VPS coverage is sparse even on real streets, so absence isn't a signal.
class ArCoreGeospatial {
  static const _channel = MethodChannel('streetsight/arcore');

  /// true/false if ARCore could answer, null if it couldn't be asked.
  static Future<bool?> checkVpsAvailability(double lat, double lng) async {
    try {
      final result = await _channel.invokeMethod<bool>('checkVpsAvailability', {'lat': lat, 'lng': lng});
      return result;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }
}

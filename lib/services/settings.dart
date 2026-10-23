import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geo.dart';
import 'poi.dart';
import 'routing.dart';

enum DistanceUnit { metric, imperial }

/// Which screen the primary action opens. The two cannot be combined: an
/// ARCore session owns the camera, so live sign translation cannot run
/// inside it.
enum NavMode {
  ar, // plane-tracked AR path
  translate, // camera overlay with sign translation and nearby places
}

/// App-wide preferences, persisted to [SharedPreferences].
///
/// A single shared instance rather than an injected dependency: these are
/// read from both navigation screens and the home screen, and threading them
/// through every constructor earns nothing here.
class Settings extends ChangeNotifier {
  static const _kUnit = 'unit';
  static const _kMode = 'navMode';
  static const _kInterests = 'interests';
  static const _kRecents = 'recentSearches';
  static const _kSaved = 'savedPlaces';
  static const _kVoice = 'voice';
  static const _kHaptics = 'haptics';
  static const _kOnboarded = 'onboarded';
  static const _kTactile = 'tactileCompass';
  static const _kContrast = 'highContrast';

  DistanceUnit unit = DistanceUnit.metric;
  NavMode mode = NavMode.ar;
  Set<Interest> interests = {Interest.food, Interest.history};
  List<String> recents = [];
  List<Place> saved = [];
  bool voice = true;
  bool haptics = true;

  /// Continuous heading feedback through the vibration motor: ticks quicken
  /// as the phone swings onto the route bearing. Lets someone follow a turn
  /// without looking at the screen at all.
  bool tactileCompass = false;

  /// Heavier, higher-contrast overlay for bright sunlight and for low
  /// vision. Costs elegance, buys legibility.
  bool highContrast = false;

  /// Walks a route on a timer instead of waiting for real GPS movement.
  /// Not persisted: a simulated position should never silently survive into
  /// a real walk.
  bool demoWalk = false;

  /// False until the first-run walkthrough has been completed or skipped.
  bool onboarded = false;

  SharedPreferences? _prefs;

  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();
    unit = DistanceUnit.values.asNameMap()[p.getString(_kUnit)] ?? DistanceUnit.metric;
    mode = NavMode.values.asNameMap()[p.getString(_kMode)] ?? NavMode.ar;

    final savedInterests = p.getStringList(_kInterests);
    if (savedInterests != null) {
      interests = savedInterests
          .map((n) => Interest.values.asNameMap()[n])
          .whereType<Interest>()
          .toSet();
    }
    voice = p.getBool(_kVoice) ?? true;
    haptics = p.getBool(_kHaptics) ?? true;
    onboarded = p.getBool(_kOnboarded) ?? false;
    tactileCompass = p.getBool(_kTactile) ?? false;
    highContrast = p.getBool(_kContrast) ?? false;
    recents = p.getStringList(_kRecents) ?? [];
    saved = (p.getStringList(_kSaved) ?? []).map(_decodePlace).whereType<Place>().toList();
    notifyListeners();
  }

  // --- mutations ---------------------------------------------------------

  Future<void> setUnit(DistanceUnit u) async {
    unit = u;
    await _prefs?.setString(_kUnit, u.name);
    notifyListeners();
  }

  Future<void> setMode(NavMode m) async {
    mode = m;
    await _prefs?.setString(_kMode, m.name);
    notifyListeners();
  }

  Future<void> setVoice(bool v) async {
    voice = v;
    await _prefs?.setBool(_kVoice, v);
    notifyListeners();
  }

  Future<void> setHaptics(bool v) async {
    haptics = v;
    await _prefs?.setBool(_kHaptics, v);
    notifyListeners();
  }

  Future<void> setTactile(bool v) async {
    tactileCompass = v;
    await _prefs?.setBool(_kTactile, v);
    notifyListeners();
  }

  Future<void> setHighContrast(bool v) async {
    highContrast = v;
    await _prefs?.setBool(_kContrast, v);
    notifyListeners();
  }

  void setDemoWalk(bool v) {
    demoWalk = v;
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    onboarded = true;
    await _prefs?.setBool(_kOnboarded, true);
    notifyListeners();
  }

  /// Exposed so the walkthrough can be replayed from preferences.
  Future<void> resetOnboarding() async {
    onboarded = false;
    await _prefs?.setBool(_kOnboarded, false);
    notifyListeners();
  }

  Future<void> toggleInterest(Interest i) async {
    interests.contains(i) ? interests.remove(i) : interests.add(i);
    await _prefs?.setStringList(_kInterests, interests.map((e) => e.name).toList());
    notifyListeners();
  }

  /// Most recent first, de-duplicated case-insensitively, capped so the list
  /// stays glanceable rather than becoming a history log.
  Future<void> pushRecent(String q) async {
    final t = q.trim();
    if (t.isEmpty) return;
    recents.removeWhere((e) => e.toLowerCase() == t.toLowerCase());
    recents.insert(0, t);
    if (recents.length > 6) recents = recents.sublist(0, 6);
    await _prefs?.setStringList(_kRecents, recents);
    notifyListeners();
  }

  Future<void> clearRecents() async {
    recents = [];
    await _prefs?.setStringList(_kRecents, const []);
    notifyListeners();
  }

  bool isSaved(Place p) => saved.any((e) => e.name == p.name);

  Future<void> toggleSaved(Place p) async {
    isSaved(p) ? saved.removeWhere((e) => e.name == p.name) : saved.insert(0, p);
    await _prefs?.setStringList(_kSaved, saved.map(_encodePlace).toList());
    notifyListeners();
  }

  // --- formatting --------------------------------------------------------

  /// Distances in the unit the user picked. Short imperial distances read in
  /// feet rather than fractional miles, which is what a walker expects.
  String formatDistance(double metres) {
    if (unit == DistanceUnit.imperial) {
      final feet = metres * 3.28084;
      if (feet < 1000) return '${feet.round()} ft';
      return '${(metres / 1609.344).toStringAsFixed(1)} mi';
    }
    if (metres < 1000) return '${metres.round()} m';
    return '${(metres / 1000).toStringAsFixed(1)} km';
  }

  static String _encodePlace(Place p) => jsonEncode({'n': p.name, 'a': p.pos.lat, 'o': p.pos.lng});

  static Place? _decodePlace(String s) {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return Place(m['n'] as String, LatLng((m['a'] as num).toDouble(), (m['o'] as num).toDouble()));
    } catch (_) {
      return null; // a malformed entry should drop out, not take the list with it
    }
  }
}

final settings = Settings();

@Tags(['preview'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:streetsight_ar/screens/home_screen.dart';
import 'package:streetsight_ar/screens/onboarding_screen.dart';
import 'package:streetsight_ar/screens/settings_sheet.dart';
import 'package:streetsight_ar/services/geo.dart';
import 'package:streetsight_ar/services/routing.dart';
import 'package:streetsight_ar/services/settings.dart';
import 'package:streetsight_ar/theme.dart';

/// Renders the real screens to PNG so the UI can actually be looked at
/// without a device attached.
///
/// Run with:
///   flutter test test/ui_preview_test.dart --update-goldens
///
/// This is a preview harness, not an assertion suite — it is tagged so a
/// normal `flutter test` run skips it. Reviewing a design by describing it
/// is how you end up shipping something nobody has seen.
Future<void> _loadFonts() async {
  // The widget tester's default font draws every glyph as a box, which makes
  // a screenshot useless for judging type. Arial stands in for the default
  // family so the renders show real text.
  const faces = {
    'Roboto': [
      '/System/Library/Fonts/Supplemental/Arial.ttf',
      '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
    ],
  };
  for (final entry in faces.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      final file = File(path);
      if (!file.existsSync()) continue;
      loader.addFont(file.readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }
}

Widget _app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: home,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.load();
    await _loadFonts();
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('previews/$name.png'));
  }

  testWidgets('onboarding', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(OnboardingScreen(onDone: () {})));
    await tester.pumpAndSettle();
    await shoot(tester, '01_onboarding');

    // Page through to the permission step.
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    await shoot(tester, '02_onboarding_permissions');
  });

  testWidgets('home', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await settings.completeOnboarding();
    await tester.pumpWidget(_app(const HomeScreen()));
    await tester.pumpAndSettle();
    await shoot(tester, '03_home_empty');

    // With saved places and recent searches, which is the state a returning
    // user actually sees.
    await settings.pushRecent('Hindustan University');
    await settings.pushRecent('cafe');
    await settings.toggleSaved(Place('Marina Beach, Chennai', LatLng(13.05, 80.28)));
    await tester.pumpAndSettle();
    await shoot(tester, '04_home_populated');
  });

  testWidgets('preferences', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(
      Builder(builder: (context) {
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: Center(
            child: ElevatedButton(onPressed: () => showSettingsSheet(context), child: const Text('open')),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await shoot(tester, '05_preferences');
  });
}

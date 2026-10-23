import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/env.dart';
import 'services/settings.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Env.load();
  await settings.load();
  runApp(const StreetSightApp());
}

class StreetSightApp extends StatelessWidget {
  const StreetSightApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'StreetSight AR',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const _Root(),
      );
}

/// Shows the walkthrough until it has been completed once, then the home
/// screen. Kept here rather than inside HomeScreen so the first frame the
/// user ever sees is the walkthrough, with no flash of the main UI behind it.
class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  @override
  Widget build(BuildContext context) {
    if (!settings.onboarded) {
      return OnboardingScreen(onDone: () => setState(() {}));
    }
    return const HomeScreen();
  }
}

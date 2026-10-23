import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/settings.dart';
import '../theme.dart';

/// First-run walkthrough: three screens, then permissions.
///
/// Kept to one idea per page with a single forward action. The permission
/// step comes last and explains why each one is needed *before* the system
/// dialog appears — a cold OS prompt with no context is the single biggest
/// cause of people denying camera access and never seeing the product.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  bool _asking = false;
  bool? _cameraOk;
  bool? _locationOk;

  static const _slides = [
    (
      '🧭',
      'Directions on the street itself',
      'Point your phone down the road and the route is drawn onto the ground in front of you. No more guessing which way the blue dot meant.',
    ),
    (
      '🔤',
      'Signs read themselves',
      'Aim at a sign in another language and the words are replaced where they stand, right on the sign. Works offline once a language is downloaded.',
    ),
    (
      '📍',
      'Notice what you walk past',
      'Food, history and art nearby get a quiet tag as you approach. Pick what you care about and ignore the rest.',
    ),
  ];

  bool get _isLast => _page == _slides.length;

  Future<void> _next() async {
    if (settings.haptics) await HapticFeedback.selectionClick();
    if (_page < _slides.length) {
      _pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    } else {
      await _finish();
    }
  }

  Future<void> _requestPermissions() async {
    setState(() => _asking = true);
    try {
      final cam = await Permission.camera.request();
      if (mounted) setState(() => _cameraOk = cam.isGranted);

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      final ok = perm == LocationPermission.always || perm == LocationPermission.whileInUse;
      if (mounted) setState(() => _locationOk = ok);
    } catch (_) {
      if (mounted) {
        setState(() {
          _cameraOk ??= false;
          _locationOk ??= false;
        });
      }
    }
    if (mounted) setState(() => _asking = false);
  }

  Future<void> _finish() async {
    await settings.completeOnboarding();
    widget.onDone();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
        child: SafeArea(
          child: Column(children: [
            // Skip stays available on every page except the last, where the
            // only remaining action is the one that matters.
            SizedBox(
              height: 52,
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (!_isLast)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: TextButton(
                      onPressed: _finish,
                      style: TextButton.styleFrom(foregroundColor: AppColors.inkSoft),
                      child: const Text('Skip'),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final (emoji, title, body) in _slides) _slide(emoji, title, body),
                  _permissionPage(),
                ],
              ),
            ),
            _dots(),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 26, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _asking ? null : _next,
                  child: Text(_isLast ? "Start walking" : 'Next'),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _slide(String emoji, String title, String body) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 132,
          height: 132,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.brandSoft, Color(0xFFFBD9C6)],
            ),
          ),
          alignment: Alignment.center,
          child: Text(emoji, style: const TextStyle(fontSize: 58)),
        ),
        const SizedBox(height: 38),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 25, fontWeight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.6, height: 1.2)),
        const SizedBox(height: 14),
        Text(body,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: AppColors.inkSoft, height: 1.55)),
      ]),
    );
  }

  Widget _permissionPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: Column(children: [
        const SizedBox(height: 10),
        const Text('Two things to allow',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.6)),
        const SizedBox(height: 10),
        const Text('Nothing leaves your phone except the place you search for.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14.5, color: AppColors.inkSoft, height: 1.5)),
        const SizedBox(height: 26),
        _permRow(
          icon: Icons.photo_camera_rounded,
          title: 'Camera',
          body: 'To show the route on the street and read signs.',
          granted: _cameraOk,
        ),
        const SizedBox(height: 12),
        _permRow(
          icon: Icons.my_location_rounded,
          title: 'Location',
          body: 'To know where you are starting from.',
          granted: _locationOk,
        ),
        const SizedBox(height: 22),
        if (_cameraOk == null && _locationOk == null)
          OutlinedButton.icon(
            onPressed: _asking ? null : _requestPermissions,
            icon: _asking
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.lock_open_rounded, size: 18),
            label: Text(_asking ? 'Waiting…' : 'Allow both'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.brandDeep,
              side: const BorderSide(color: AppColors.brand),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          )
        else if (_cameraOk == false || _locationOk == false)
          Column(children: [
            const Text('You can still look around, but the AR view needs both.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.inkSoft, height: 1.4)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: openAppSettings,
              style: TextButton.styleFrom(foregroundColor: AppColors.brandDeep),
              child: const Text('Open app settings'),
            ),
          ])
        else
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.check_circle_rounded, color: AppColors.sage, size: 19),
            SizedBox(width: 8),
            Text('All set', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.ink)),
          ]),
        const SizedBox(height: 10),
      ]),
    );
  }

  Widget _permRow({required IconData icon, required String title, required String body, required bool? granted}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.line),
        boxShadow: kCardShadow,
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: AppColors.brandSoft, borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: AppColors.brand, size: 22),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.ink)),
            const SizedBox(height: 2),
            Text(body, style: const TextStyle(fontSize: 12.5, color: AppColors.inkSoft, height: 1.35)),
          ]),
        ),
        if (granted != null)
          Icon(granted ? Icons.check_circle_rounded : Icons.cancel_rounded,
              color: granted ? AppColors.sage : AppColors.danger, size: 21),
      ]),
    );
  }

  Widget _dots() {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (var i = 0; i <= _slides.length; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: i == _page ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: i == _page ? AppColors.brand : AppColors.line,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
    ]);
  }
}

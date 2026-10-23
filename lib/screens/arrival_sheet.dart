import 'package:flutter/material.dart';

import '../services/routing.dart';
import '../services/settings.dart';
import '../theme.dart';

/// Shown once, when the walk ends.
///
/// Arriving used to be a silent state change in a label. Closing the loop
/// with a named moment is what makes the whole thing feel finished rather
/// than merely stopped.
Future<void> showArrivalSheet(
  BuildContext context, {
  required Place destination,
  required double walkedM,
  required Duration took,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _ArrivalSheet(destination: destination, walkedM: walkedM, took: took),
  );
}

class _ArrivalSheet extends StatelessWidget {
  final Place destination;
  final double walkedM;
  final Duration took;
  const _ArrivalSheet({required this.destination, required this.walkedM, required this.took});

  /// Rough but honest: an average walking stride is about 0.75 m. Presented
  /// as "about" so it never reads as a measured count.
  int get _steps => (walkedM / 0.75).round();

  String get _time {
    final m = took.inMinutes;
    if (m < 1) return 'under a minute';
    if (m < 60) return '$m min';
    return '${took.inHours} h ${m % 60} min';
  }

  @override
  Widget build(BuildContext context) {
    final saved = settings.isSaved(destination);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [AppColors.brandLift, AppColors.brand]),
            ),
            child: const Icon(Icons.flag_rounded, color: Colors.white, size: 40),
          ),
          const SizedBox(height: 18),
          const Text('You made it',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.5)),
          const SizedBox(height: 6),
          Text(destination.name.split(',').first,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5, color: AppColors.inkSoft)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(color: AppColors.brandSoft, borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              _stat(settings.formatDistance(walkedM), 'walked'),
              _divider(),
              _stat(_time, 'on foot'),
              _divider(),
              _stat('~$_steps', 'steps'),
            ]),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => settings.toggleSaved(destination),
                icon: Icon(saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, size: 18),
                label: Text(saved ? 'Saved' : 'Save place'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.brandDeep,
                  side: const BorderSide(color: AppColors.brand),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context); // the sheet
                  Navigator.pop(context); // back to search
                },
                child: const Text('Done'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.inkSoft)),
        ]),
      );

  Widget _divider() => Container(width: 1, height: 30, color: Colors.white.withValues(alpha: 0.7));
}

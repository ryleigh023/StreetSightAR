import 'package:flutter/material.dart';

import '../services/env.dart';
import '../services/poi.dart';
import '../services/settings.dart';
import '../theme.dart';

/// Preferences sheet. Deliberately short: every row here changes something
/// the user can see on the next walk, rather than exposing internals.
Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // Capped and scrollable: the sheet grew past the viewport once guidance
    // and demo options were added, and a bottom sheet does not scroll by
    // itself.
    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Preferences',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.5)),
          const SizedBox(height: 4),
          const Text('These stick between walks.', style: TextStyle(fontSize: 13, color: AppColors.inkSoft)),
          const SizedBox(height: 22),

          _label('Distance units'),
          const SizedBox(height: 10),
          _segment<DistanceUnit>(
            value: settings.unit,
            options: const {DistanceUnit.metric: 'Metres', DistanceUnit.imperial: 'Feet & miles'},
            onChanged: (v) => setState(() => settings.setUnit(v)),
          ),
          const SizedBox(height: 24),

          _label('Default walking mode'),
          const SizedBox(height: 10),
          _segment<NavMode>(
            value: settings.mode,
            options: const {NavMode.ar: 'AR path', NavMode.translate: 'Translate'},
            onChanged: (v) => setState(() => settings.setMode(v)),
          ),
          const SizedBox(height: 8),
          Text(
            settings.mode == NavMode.ar
                ? 'Anchors a 3D path to the real ground. Needs ARCore, and the camera is fully taken over, so sign translation is off in this mode.'
                : 'Draws the route over the camera and reads signs as you pass them. Works on any phone.',
            style: const TextStyle(fontSize: 12.5, color: AppColors.inkSoft, height: 1.45),
          ),
          const SizedBox(height: 24),

          _label('Guidance'),
          const SizedBox(height: 6),
          _switchRow(
            icon: Icons.volume_up_rounded,
            title: 'Spoken directions',
            body: 'One line per turn, so you can keep your eyes on the street.',
            value: settings.voice,
            onChanged: (v) => setState(() => settings.setVoice(v)),
          ),
          _switchRow(
            icon: Icons.vibration_rounded,
            title: 'Haptic turn cues',
            body: 'A firmer tap for a turn than for a straight on.',
            value: settings.haptics,
            onChanged: (v) => setState(() => settings.setHaptics(v)),
          ),
          _switchRow(
            icon: Icons.explore_rounded,
            title: 'Tactile compass',
            body: 'Ticks quicken as the phone swings onto the route, so you can follow a turn without looking.',
            value: settings.tactileCompass,
            onChanged: (v) => setState(() => settings.setTactile(v)),
          ),
          _switchRow(
            icon: Icons.contrast_rounded,
            title: 'High contrast overlay',
            body: 'Heavier path and larger type, for bright sun and low vision.',
            value: settings.highContrast,
            onChanged: (v) => setState(() => settings.setHighContrast(v)),
          ),
          const SizedBox(height: 18),

          _label('Demo walk'),
          const SizedBox(height: 6),
          _switchRow(
            icon: Icons.play_circle_outline_rounded,
            title: 'Simulate walking the route',
            body: 'Moves you along the route on a timer so the whole flow can be shown indoors. Resets when you close the app.',
            value: settings.demoWalk,
            onChanged: (v) => setState(() => settings.setDemoWalk(v)),
          ),
          const SizedBox(height: 22),

          _label('Point out along the way'),
          const SizedBox(height: 10),
          Wrap(spacing: 9, runSpacing: 9, children: [
            for (final i in Interest.values) _interestChip(i),
          ]),
          const SizedBox(height: 24),

          _statusRow(),
          const SizedBox(height: 12),
          Center(
            child: TextButton.icon(
              onPressed: () async {
                await settings.resetOnboarding();
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.replay_rounded, size: 17),
              label: const Text('Replay the walkthrough'),
              style: TextButton.styleFrom(foregroundColor: AppColors.inkSoft),
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _label(String s) => Text(s,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: 0.1));

  /// Sliding two-up selector. Generic so units and mode share one control
  /// rather than two near-identical widgets drifting apart.
  Widget _segment<T>({
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.brandSoft, borderRadius: BorderRadius.circular(15)),
      child: Row(children: [
        for (final e in options.entries)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(e.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: value == e.key ? AppColors.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  e.value,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: value == e.key ? Colors.white : AppColors.brandDeep,
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required String body,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 20, color: value ? AppColors.brand : AppColors.inkSoft),
        const SizedBox(width: 13),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
            const SizedBox(height: 2),
            Text(body, style: const TextStyle(fontSize: 12, color: AppColors.inkSoft, height: 1.35)),
          ]),
        ),
        Switch(value: value, onChanged: onChanged, activeTrackColor: AppColors.brand),
      ]),
    );
  }

  Widget _interestChip(Interest i) {
    final on = settings.interests.contains(i);
    return GestureDetector(
      onTap: () => setState(() => settings.toggleInterest(i)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: BoxDecoration(
          color: on ? AppColors.brand : AppColors.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? AppColors.brand : AppColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(i.emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 8),
          Text(i.label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: on ? Colors.white : AppColors.ink)),
        ]),
      ),
    );
  }

  /// Honest about which data source is actually serving the app. Without a
  /// key everything runs on the free OpenStreetMap fallbacks, and it is
  /// better to say so than to let someone wonder why results look thin.
  Widget _statusRow() {
    final google = Env.hasGoogleApiKey;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(children: [
        Icon(google ? Icons.cloud_done_rounded : Icons.public_rounded,
            size: 20, color: google ? AppColors.sage : AppColors.inkSoft),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(google ? 'Google Places and Translate' : 'OpenStreetMap',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
            const SizedBox(height: 2),
            Text(
              google
                  ? 'Search, routing and sign translation use your API key.'
                  : 'Running on the free fallbacks. Add a Google API key for richer results.',
              style: const TextStyle(fontSize: 12, color: AppColors.inkSoft, height: 1.35),
            ),
          ]),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';

/// Unmissable marker that the position on screen is simulated. A demo that
/// can be mistaken for a live fix is a demo that misleads whoever is
/// watching it, so this is deliberately loud and cannot be dismissed.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          color: const Color(0xFFE8A33D),
          child: SafeArea(
            top: false,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.play_circle_fill_rounded, size: 16, color: Color(0xFF3A2606)),
              const SizedBox(width: 8),
              const Text('Demo walk — simulated position, not live GPS',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF3A2606))),
            ]),
          ),
        ),
      ),
    );
  }
}

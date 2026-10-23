import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../services/geo.dart';
import '../services/places_service.dart';
import '../services/poi.dart';
import '../services/routing.dart';
import '../services/settings.dart';
import '../theme.dart';
import 'ar_nav_screen.dart';
import 'ar_screen.dart';
import 'settings_sheet.dart';

/// One-tap searches for the things people actually look for mid-walk.
/// Typing a destination is the slow path; most walking lookups are a
/// category rather than a name.
const _quickPicks = [
  ('☕', 'Coffee', 'cafe'),
  ('🍜', 'Food', 'restaurant'),
  ('💊', 'Pharmacy', 'pharmacy'),
  ('🏧', 'ATM', 'atm'),
  ('🚉', 'Transit', 'station'),
  ('🌳', 'Parks', 'park'),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _query = TextEditingController();
  List<Place> _results = [];
  bool _busy = false;
  String? _error;
  bool _searched = false;

  /// Where searches are biased from, and what distances are measured
  /// against. Cached because every search needs it and a fresh GPS fix per
  /// keystroke would be both slow and wasteful.
  LatLng? _here;

  @override
  void initState() {
    super.initState();
    settings.addListener(_onSettings);
    _locate();
  }

  /// Best-effort position for search bias. The last known fix is used
  /// immediately so the first search is already local, then a live fix
  /// refines it.
  Future<void> _locate() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) setState(() => _here = LatLng(last.latitude, last.longitude));
      final now = await Geolocator.getCurrentPosition();
      if (mounted) setState(() => _here = LatLng(now.latitude, now.longitude));
    } catch (_) {
      // No fix available — search simply stays unbiased.
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    _query.dispose();
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Still out?';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    if (h < 21) return 'Good evening';
    return 'Out for a walk?';
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    _query.text = q;
    setState(() {
      _busy = true;
      _error = null;
      _searched = true;
    });
    try {
      _results = await searchPlaces(q, near: _here);
      if (_results.isEmpty) {
        _error = 'Nothing came up for "$q". Try a nearby landmark instead.';
      } else {
        await settings.pushRecent(q);
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _go(Place dest, {NavMode? mode}) async {
    final m = mode ?? settings.mode;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception('Location permission is needed to work out the way there.');
      }
      final pos = await Geolocator.getCurrentPosition();
      final route = await walkingRoute(LatLng(pos.latitude, pos.longitude), dest.pos);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => m == NavMode.ar
              ? ArNavScreen(destination: dest, route: route)
              : ArScreen(destination: dest, route: route, interests: settings.interests),
        ),
      );
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasResults = _results.isNotEmpty;
    return Scaffold(
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
        child: Column(children: [
          _header(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
              children: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 18),
                    child: ClipRRect(
                      borderRadius: BorderRadius.all(Radius.circular(99)),
                      child: LinearProgressIndicator(minHeight: 4, backgroundColor: AppColors.brandSoft),
                    ),
                  ),
                if (_error != null) _errorCard(_error!),
                if (hasResults) ...[
                  _section('Results', '${_results.length} found'),
                  const SizedBox(height: 14),
                  for (final p in _results) _placeCard(p),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _results = [];
                        _searched = false;
                        _query.clear();
                      }),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Clear results'),
                      style: TextButton.styleFrom(foregroundColor: AppColors.inkSoft),
                    ),
                  ),
                ] else ...[
                  _section('Quick picks', 'Tap to find one nearby'),
                  const SizedBox(height: 14),
                  _quickGrid(),
                  const SizedBox(height: 28),
                  if (_searched && !_busy && _error == null) _emptyState(),
                  if (settings.saved.isNotEmpty) ...[
                    _section('Saved', '${settings.saved.length} place${settings.saved.length == 1 ? '' : 's'}'),
                    const SizedBox(height: 14),
                    for (final p in settings.saved) _placeCard(p),
                    const SizedBox(height: 16),
                  ],
                  if (settings.recents.isNotEmpty) ...[
                    Row(children: [
                      Expanded(child: _section('Recent', 'Searches you made before')),
                      TextButton(
                        onPressed: settings.clearRecents,
                        style: TextButton.styleFrom(foregroundColor: AppColors.inkSoft),
                        child: const Text('Clear'),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 9,
                      runSpacing: 9,
                      children: [for (final r in settings.recents) _recentChip(r)],
                    ),
                    const SizedBox(height: 28),
                  ],
                  _section('Along the way', 'What we point out as you walk'),
                  const SizedBox(height: 14),
                  _interestRow(),
                  const SizedBox(height: 24),
                  _tipCard(),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  // --- header ------------------------------------------------------------

  Widget _header() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.brandLift, AppColors.brand, AppColors.brandDeep],
          stops: [0, 0.55, 1],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(34)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
      child: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_greeting, style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14.5)),
                const SizedBox(height: 2),
                const Text('Where are we headed?',
                    style: TextStyle(
                        color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
              ]),
            ),
            _headerButton(icon: Icons.tune_rounded, onTap: () => showSettingsSheet(context)),
          ]),
          const SizedBox(height: 20),
          _searchField(),
          const SizedBox(height: 14),
          _modeStrip(),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  Widget _headerButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.white.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(width: 46, height: 46, child: Icon(icon, color: Colors.white, size: 22)),
      ),
    );
  }

  Widget _searchField() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: kCardShadow,
      ),
      child: Row(children: [
        const SizedBox(width: 16),
        const Icon(Icons.search_rounded, color: AppColors.inkSoft, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            style: const TextStyle(color: AppColors.ink, fontSize: 15.5, fontWeight: FontWeight.w500),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search a place or address',
              hintStyle: TextStyle(color: AppColors.inkSoft, fontWeight: FontWeight.w400),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 18),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Material(
            color: AppColors.brand,
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              borderRadius: BorderRadius.circular(13),
              onTap: _busy ? null : () => _search(_query.text),
              child: const SizedBox(
                width: 46,
                height: 46,
                child: Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 21),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  /// Which experience the primary button opens. Surfaced here rather than
  /// buried in settings: the two modes do genuinely different things, and
  /// the choice is worth making per walk.
  Widget _modeStrip() {
    Widget tab(NavMode m, IconData icon, String label) {
      final on = settings.mode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => settings.setMode(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 17, color: on ? AppColors.brandDeep : Colors.white),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      color: on ? AppColors.brandDeep : Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        tab(NavMode.ar, Icons.view_in_ar_rounded, 'AR path'),
        tab(NavMode.translate, Icons.translate_rounded, 'Translate'),
      ]),
    );
  }

  // --- sections ----------------------------------------------------------

  Widget _section(String title, String sub) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style:
              const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.3)),
      const SizedBox(height: 2),
      Text(sub, style: const TextStyle(fontSize: 13, color: AppColors.inkSoft)),
    ]);
  }

  Widget _quickGrid() {
    return LayoutBuilder(builder: (context, box) {
      const gap = 12.0;
      final w = (box.maxWidth - gap * 2) / 3;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final (emoji, label, term) in _quickPicks)
            SizedBox(
              width: w,
              // Shadow on the outside, surface within. Nesting a shadowed
              // box inside a coloured Material paints the shadow over the
              // surface and the card reads grey instead of white.
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.line),
                  boxShadow: kCardShadow,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _busy ? null : () => _search(term),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(children: [
                        // A tinted disc behind each glyph, so six unrelated
                        // emoji read as one set rather than six stickers.
                        Container(
                          width: 46,
                          height: 46,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: AppColors.brandSoft, shape: BoxShape.circle),
                          child: Text(emoji, style: const TextStyle(fontSize: 22)),
                        ),
                        const SizedBox(height: 9),
                        Text(label,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _interestRow() {
    return Row(children: [
      for (final i in Interest.values) ...[
        Expanded(child: _interestTile(i)),
        if (i != Interest.values.last) const SizedBox(width: 12),
      ],
    ]);
  }

  Widget _interestTile(Interest i) {
    final on = settings.interests.contains(i);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: on ? AppColors.brand : AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: on ? AppColors.brand : AppColors.line),
        boxShadow: on ? null : kCardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => settings.toggleInterest(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? Colors.white.withValues(alpha: 0.22) : AppColors.brandSoft,
                  shape: BoxShape.circle,
                ),
                child: Text(i.emoji, style: const TextStyle(fontSize: 19)),
              ),
              const SizedBox(height: 8),
              Text(i.label,
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700, color: on ? Colors.white : AppColors.ink)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _recentChip(String r) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: _busy ? null : () => _search(r),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.history_rounded, size: 15, color: AppColors.inkSoft),
            const SizedBox(width: 7),
            Text(r, style: const TextStyle(fontSize: 13, color: AppColors.ink, fontWeight: FontWeight.w600)),
          ]),
          ),
        ),
      ),
    );
  }

  // --- place card --------------------------------------------------------

  Widget _placeCard(Place p) {
    final parts = p.name.split(',');
    final name = parts.first.trim();
    final sub = parts.length > 1 ? parts.sublist(1).join(',').trim() : 'Tap to walk there';
    final isSaved = settings.isSaved(p);
    final here = _here;
    final away = here == null ? null : distanceM(here, p.pos);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        boxShadow: kCardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _busy ? null : () => _go(p),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: AppColors.brandSoft, borderRadius: BorderRadius.circular(15)),
                child: const Icon(Icons.place_rounded, color: AppColors.brand, size: 23),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink)),
                  const SizedBox(height: 3),
                  Row(children: [
                    // How far, up front. On a walking app this is the single
                    // number that decides whether a result is worth tapping.
                    if (away != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.brandSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(settings.formatDistance(away),
                            style: const TextStyle(
                                fontSize: 11.5, fontWeight: FontWeight.w800, color: AppColors.brandDeep)),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: AppColors.inkSoft)),
                    ),
                  ]),
                ]),
              ),
              IconButton(
                tooltip: isSaved ? 'Remove from saved' : 'Save this place',
                onPressed: () => settings.toggleSaved(p),
                icon: Icon(isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                    color: isSaved ? AppColors.amber : AppColors.inkSoft, size: 22),
              ),
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
                child: Icon(settings.mode == NavMode.ar ? Icons.view_in_ar_rounded : Icons.translate_rounded,
                    color: Colors.white, size: 19),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // --- small pieces ------------------------------------------------------

  Widget _tipCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: AppColors.brandSoft, borderRadius: BorderRadius.circular(20)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('💡', style: TextStyle(fontSize: 20)),
        const SizedBox(width: 13),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Hold the phone up as you walk',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.ink)),
            const SizedBox(height: 4),
            Text(
              settings.mode == NavMode.ar
                  ? 'In AR path mode, pan slowly at the ground, then tap the floor to drop the route.'
                  : 'In Translate mode, point at a sign and the words are replaced where they stand.',
              style: const TextStyle(fontSize: 13, color: AppColors.ink, height: 1.45),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(children: [
        const Text('🧭', style: TextStyle(fontSize: 38)),
        const SizedBox(height: 12),
        const Text('Nothing found',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink, fontSize: 15)),
        const SizedBox(height: 5),
        const Text('Try a nearby landmark, or one of the quick picks.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.inkSoft)),
      ]),
    );
  }

  Widget _errorCard(String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF1E8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF6D3BE)),
      ),
      child: Row(children: [
        const Icon(Icons.info_outline_rounded, color: AppColors.danger, size: 20),
        const SizedBox(width: 11),
        Expanded(
          child: Text(msg.replaceFirst('Exception: ', ''),
              style: const TextStyle(fontSize: 13, color: Color(0xFF7C2D12), height: 1.4)),
        ),
      ]),
    );
  }
}

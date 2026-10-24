import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:ar_flutter_plugin_plus/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_plus/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_plus/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_plus/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_plus/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_plus/models/ar_node.dart';
import 'package:ar_flutter_plugin_plus/widgets/ar_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../widgets/demo_banner.dart';
import 'arrival_sheet.dart';

import '../services/guidance.dart';
import '../services/pose_confidence.dart';
import '../services/tactile_compass.dart';
import '../services/walk_simulator.dart';
import '../services/geo.dart';
import '../services/settings.dart';
import '../services/routing.dart';

/// True AR walking navigation: ARCore/ARKit tracks the real ground plane and
/// the chevrons are anchored to it, so they stay put in the world as the
/// phone moves rather than being redrawn from compass and pitch each frame.
///
/// Note on scope: an AR session owns the camera exclusively. This screen
/// therefore cannot run the live sign translation or the scene classifier,
/// which both consume raw camera frames. Those stay on the non-AR screen.
class ArNavScreen extends StatefulWidget {
  final Place destination;
  final WalkRoute route;
  const ArNavScreen({super.key, required this.destination, required this.route});

  @override
  State<ArNavScreen> createState() => _ArNavScreenState();
}

class _ArNavScreenState extends State<ArNavScreen> {
  ARSessionManager? _session;
  ARObjectManager? _objects;
  ARAnchorManager? _anchors;

  /// The anchor the whole trail hangs off. Replacing it re-lays the trail.
  ARPlaneAnchor? _trailAnchor;
  final List<ARNode> _nodes = [];

  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  LatLng? _me;
  double _heading = 0;
  bool _planeFound = false;
  final _guide = Guidance();
  final _jitter = HeadingJitter();
  final _tactile = TactileCompass();
  WalkSimulator? _sim;
  StreamSubscription<SimFix>? _simSub;
  PoseConfidence _pose = PoseConfidence.unknown;
  double? _gpsAccuracyM;
  final _startedAt = DateTime.now();
  bool _arrivalShown = false;
  bool _placing = false;
  String? _error;

  // --- Trail layout ------------------------------------------------------
  static const _modelUri = 'assets/models/nav_arrow.glb';
  static const _chevronCount = 12;
  static const _spacingM = 1.4; // gap between chevrons, measured along the path
  static const _trailRangeM = 40.0; // route beyond this is not worth anchoring
  static const _modelScale = 1.0;

  @override
  void initState() {
    super.initState();
    _guide.init();
    _tactile.start();
    if (settings.demoWalk) {
      _startDemoWalk();
    } else {
      _startSensors();
    }
  }

  /// Timed walk along the route in place of GPS and compass, so the full
  /// flow can be shown indoors. It drives the same handlers as a real fix.
  void _startDemoWalk() {
    final sim = _sim = WalkSimulator(widget.route.points);
    _simSub = sim.start().listen((f) {
      if (!mounted) return;
      _jitter.add(f.heading);
      _gpsAccuracyM = f.accuracyM;
      setState(() {
        _me = f.pos;
        _heading = f.heading;
        _pose = _poseNow();
      });
      _guide.announce(
        instruction: _instruction.$2,
        distanceM: _remainingM,
        arrived: _arrived,
        speedMs: f.speedMs,
      );
      _tactile.update(_arrived ? 0 : _bearingOffsetRad() * 180 / math.pi);
      _maybeShowArrival();
    });
  }

  Future<void> _startSensors() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _error = 'Location permission is required for navigation.');
        return;
      }
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 2),
      ).listen((p) {
        if (!mounted) return;
        _gpsAccuracyM = p.accuracy;
        setState(() {
          _me = LatLng(p.latitude, p.longitude);
          _pose = _poseNow();
        });
        // Cue off position rather than off build: build runs on every
        // compass tick, which would hammer the announcer for no new
        // information.
        _guide.announce(
          instruction: _instruction.$2,
          distanceM: _remainingM,
          arrived: _arrived,
          speedMs: p.speed.isFinite && p.speed > 0 ? p.speed : 1.3,
        );
        _tactile.update(_arrived ? 0 : _bearingOffsetRad() * 180 / math.pi);
        _maybeShowArrival();
      });
      _compassSub = FlutterCompass.events?.listen((e) {
        if (e.heading == null || !mounted) return;
        final h = (e.heading! + 360) % 360;
        _jitter.add(h);
        setState(() {
          _heading = h;
          _pose = _poseNow();
        });
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Here the AR runtime's own view counts too: a placed trail means ARCore
  /// has a plane locked, which is far stronger evidence than GPS alone.
  PoseConfidence _poseNow() {
    if (settings.demoWalk) return const PoseConfidence(1, PoseBand.solid, '');
    return PoseConfidence.from(
      gpsAccuracyM: _gpsAccuracyM,
      hasHeading: _heading != 0 || _jitter.degrees > 0,
      tracking: _nodes.isNotEmpty ? true : (_planeFound ? null : false),
      headingJitterDeg: _jitter.degrees,
    );
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compassSub?.cancel();
    _simSub?.cancel();
    _sim?.stop();
    _tactile.stop();
    _guide.dispose();
    _session?.dispose();
    super.dispose();
  }

  // --- AR session --------------------------------------------------------

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _session = sessionManager;
    _objects = objectManager;
    _anchors = anchorManager;

    sessionManager.onInitialize(
      // Feature points and the plane grid are shown only while scanning, so
      // the user can see tracking is working. They are turned off the moment
      // the trail is placed, to keep the view clean.
      showFeaturePoints: true,
      showPlanes: true,
      showWorldOrigin: false,
      showAnimatedGuide: false, // we render our own scanning card
      handleTaps: true,
      handlePans: false,
      handleRotation: false,
    );
    objectManager.onInitialize();

    sessionManager.onPlaneOrPointTap = _onPlaneOrPointTapped;
  }

  /// A tap that lands on a detected plane anchors the trail to the real
  /// world at that point. Point (feature) hits are ignored: anchoring the
  /// trail to a sparse feature point rather than a plane is what makes
  /// chevrons appear to float in mid-air.
  Future<void> _onPlaneOrPointTapped(List<ARHitTestResult> hits) async {
    if (_placing) return;
    final hit = hits.where((h) => h.type == ARHitTestResultType.plane).firstOrNull;
    if (hit == null) return;

    setState(() {
      _placing = true;
      _planeFound = true;
    });
    await _layTrail(hit.worldTransform);
    if (mounted) setState(() => _placing = false);
  }

  /// Projects the remaining route into AR-local metres.
  ///
  /// The AR session's -Z is whichever way the camera faced when tracking
  /// started, so world positions have to be rotated out of compass bearings
  /// and into that frame. Returns points as (x = right, z = forward is
  /// negative), matching AR world space.
  List<Offset> _routeInArSpace() {
    final me = _me;
    if (me == null) return const [];
    final rad = _heading * math.pi / 180;
    final cosH = math.cos(rad), sinH = math.sin(rad);

    final out = <Offset>[Offset.zero]; // the walker's own feet
    for (final p in widget.route.points) {
      final east = (p.lng - me.lng) * 111320 * math.cos(me.lat * math.pi / 180);
      final north = (p.lat - me.lat) * 110540;
      final forward = east * sinH + north * cosH;
      final right = east * cosH - north * sinH;
      if (forward * forward + right * right > _trailRangeM * _trailRangeM) break;
      out.add(Offset(right, -forward));
    }
    return out;
  }

  /// Centripetal Catmull-Rom sample. A raw polyline from OSRM turns corners
  /// as hard vertices; dropping arrows straight onto it makes them jolt
  /// through a bend. Smoothing first gives the trail a continuous tangent to
  /// orient each chevron against.
  static Offset _spline(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final t2 = t * t, t3 = t2 * t;
    return (p1 * 2.0 +
            (p2 - p0) * t +
            (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2 +
            (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3) *
        0.5;
  }

  /// Lays chevrons at an even spacing along the smoothed route, each turned
  /// onto the local tangent. Every node is parented to one plane anchor, so
  /// they share a single real-world frame and cannot drift apart.
  ///
  /// This follows the actual route geometry rather than a single bearing to
  /// the next waypoint, so the trail bends through corners the way the
  /// street does instead of pointing through buildings.
  Future<void> _layTrail(Matrix4 origin) async {
    await _clearTrail();

    final anchor = ARPlaneAnchor(transformation: origin);
    final added = await _anchors?.addAnchor(anchor) ?? false;
    if (!added) {
      if (mounted) setState(() => _error = 'Could not anchor to that surface. Try again on open ground.');
      return;
    }
    _trailAnchor = anchor;

    final route = _routeInArSpace();
    final base = origin.getTranslation();

    // Densely sample the spline, then walk it by arc length so spacing is
    // even in metres rather than even in parameter — the two differ sharply
    // wherever the route bends.
    final samples = <Offset>[];
    if (route.length < 2) {
      // No usable route geometry yet: fall back to a straight run along the
      // bearing we do know, so the user still gets a trail.
      final yaw = _bearingOffsetRad();
      for (var i = 0; i <= 40; i++) {
        final d = i * 0.5;
        samples.add(Offset(math.sin(yaw) * d, -math.cos(yaw) * d));
      }
    } else {
      for (var i = 0; i < route.length - 1; i++) {
        final p0 = route[i == 0 ? 0 : i - 1];
        final p1 = route[i];
        final p2 = route[i + 1];
        final p3 = route[i + 2 < route.length ? i + 2 : route.length - 1];
        for (var k = 0; k < 12; k++) {
          samples.add(_spline(p0, p1, p2, p3, k / 12));
        }
      }
      samples.add(route.last);
    }

    var travelled = 0.0;
    var nextDrop = _spacingM; // skip the walker's own feet
    var placed = 0;
    for (var i = 1; i < samples.length && placed < _chevronCount; i++) {
      final seg = samples[i] - samples[i - 1];
      final segLen = seg.distance;
      if (segLen < 1e-4) continue;

      while (travelled + segLen >= nextDrop && placed < _chevronCount) {
        final t = (nextDrop - travelled) / segLen;
        final at = samples[i - 1] + seg * t;

        // Tangent -> yaw about Y. Rotating the model's authored -Z heading
        // by yaw must land on the tangent, which gives atan2(-dx, -dz).
        final yaw = math.atan2(-seg.dx / segLen, -seg.dy / segLen);

        final node = ARNode(
          type: NodeType.localGLB,
          uri: _modelUri,
          name: 'chevron_$placed',
          scale: vm.Vector3.all(_modelScale * (settings.highContrast ? 1.35 : 1.0)),
          position: vm.Vector3(base.x + at.dx, base.y + 0.02, base.z + at.dy),
          rotation: vm.Vector4(0, 1, 0, yaw),
        );
        final ok = await _objects?.addNode(node, planeAnchor: anchor) ?? false;
        if (ok) _nodes.add(node);
        placed++;
        nextDrop += _spacingM;
      }
      travelled += segLen;
    }

    // Trail is down — stop advertising the tracking debug visuals.
    await _session?.onInitialize(
      showFeaturePoints: false,
      showPlanes: false,
      showWorldOrigin: false,
      showAnimatedGuide: false,
      handleTaps: true,
    );
  }

  Future<void> _clearTrail() async {
    for (final n in _nodes) {
      await _objects?.removeNode(n);
    }
    _nodes.clear();
    final a = _trailAnchor;
    if (a != null) await _anchors?.removeAnchor(a);
    _trailAnchor = null;
  }

  /// Angle from the direction the phone faces to the direction of travel.
  double _bearingOffsetRad() {
    final me = _me;
    if (me == null) return 0;
    final pts = widget.route.points;
    final next = pts.isNotEmpty ? pts.first : widget.destination.pos;
    return angleDiff(_heading, bearingDeg(me, next)) * math.pi / 180;
  }

  // --- Derived navigation state -----------------------------------------

  double get _remainingM {
    final me = _me;
    return me == null ? widget.route.distanceM : distanceM(me, widget.destination.pos);
  }

  bool get _arrived => _me != null && _remainingM < 20;

  (IconData, String) get _instruction {
    if (_arrived) return (Icons.flag_rounded, 'You have arrived');
    final turn = _bearingOffsetRad() * 180 / math.pi;
    if (turn > 25) return (Icons.turn_right_rounded, 'Turn right');
    if (turn < -25) return (Icons.turn_left_rounded, 'Turn left');
    return (Icons.straight_rounded, 'Continue this way');
  }

  static String _fmt(double m) => settings.formatDistance(m);

  /// Fires once. Without the latch the sheet would be re-pushed on every
  /// GPS tick for as long as the walker stands at the destination.
  void _maybeShowArrival() {
    if (_arrivalShown || !_arrived || !mounted) return;
    _arrivalShown = true;
    _guide.say('You have arrived');
    showArrivalSheet(
      context,
      destination: widget.destination,
      walkedM: widget.route.distanceM,
      took: DateTime.now().difference(_startedAt),
    );
  }

  // --- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        // The AR view owns the camera; everything else is a Flutter overlay
        // drawn on top of it.
        ARView(
          onARViewCreated: _onARViewCreated,
          planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
        ),
        _Hud(
          pose: _pose,
          instruction: _instruction,
          distance: _fmt(_remainingM),
          destination: widget.destination.name.split(',').first,
          scanning: !_planeFound,
          placing: _placing,
          error: _error,
          onBack: () => Navigator.pop(context),
          onReplace: _nodes.isEmpty ? null : _clearTrail,
        ),
        if (settings.demoWalk) const DemoBanner(),
      ]),
    );
  }
}

/// All of the on-screen chrome. Kept out of the AR widget so the AR stack
/// stays readable and the HUD can be restyled without touching session code.
class _Hud extends StatelessWidget {
  final PoseConfidence pose;
  final (IconData, String) instruction;
  final String distance;
  final String destination;
  final bool scanning;
  final bool placing;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback? onReplace;

  const _Hud({
    required this.pose,
    required this.instruction,
    required this.distance,
    required this.destination,
    required this.scanning,
    required this.placing,
    required this.error,
    required this.onBack,
    required this.onReplace,
  });

  static const _accent = Color(0xFF2B6BF0);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _GlassButton(icon: Icons.arrow_back_rounded, onTap: onBack),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _instructionCard(),
                // Silent at full confidence: a working system should not
                // narrate itself.
                if (pose.band != PoseBand.solid) _poseChip(),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        // Scanning coach. Fades rather than popping, so it does not snatch
        // attention away from the camera feed at the moment a plane locks.
        AnimatedOpacity(
          opacity: scanning ? 1 : 0,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          child: AnimatedSlide(
            offset: scanning ? Offset.zero : const Offset(0, -0.25),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            child: const _ScanningCard(),
          ),
        ),
        const Spacer(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _Glass(
              tint: const Color(0xFFDC2626),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.white, size: 19),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(error!.replaceFirst('Exception: ', ''),
                        style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ),
                ]),
              ),
            ),
          ),
        if (!scanning)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
            child: Row(children: [
              Expanded(child: _destinationPill()),
              if (onReplace != null) ...[
                const SizedBox(width: 12),
                _GlassButton(icon: Icons.refresh_rounded, onTap: onReplace!),
              ],
            ]),
          ),
      ]),
    );
  }

  Widget _poseChip() {
    final poor = pose.band == PoseBand.fallback;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(poor ? Icons.gps_off_rounded : Icons.gps_not_fixed_rounded,
            size: 14, color: poor ? const Color(0xFFE8A33D) : Colors.white70),
        const SizedBox(width: 7),
        Flexible(
          child: Text(pose.reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  Widget _instructionCard() {
    return _Glass(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF3B82F6), _accent]),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(instruction.$1, color: Colors.white, size: 23),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(instruction.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
              const SizedBox(height: 2),
              Text(destination,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.72), fontSize: 12.5)),
            ]),
          ),
          const SizedBox(width: 10),
          _DistancePill(text: distance),
        ]),
      ),
    );
  }

  Widget _destinationPill() {
    return _Glass(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(children: [
          const Icon(Icons.place_rounded, color: Colors.white, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(placing ? 'Placing route…' : destination,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          Text(distance,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// Frosted container: a real backdrop blur behind a translucent fill and a
/// hairline border. The border is what sells the glass — without it the card
/// dissolves into whatever the camera happens to be pointing at.
class _Glass extends StatelessWidget {
  final Widget child;
  final Color? tint;
  final double radius;
  const _Glass({required this.child, this.tint, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: (tint ?? Colors.black).withValues(alpha: tint == null ? 0.28 : 0.55),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _Glass(
      radius: 16,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(width: 48, height: 48, child: Icon(icon, color: Colors.white, size: 22)),
      ),
    );
  }
}

class _DistancePill extends StatelessWidget {
  final String text;
  const _DistancePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF60A5FA), Color(0xFF2B6BF0)]),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x662B6BF0), blurRadius: 14, offset: Offset(0, 3))],
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
    );
  }
}

/// The "find the ground" coach, with a slow sweeping shimmer so it reads as
/// an active instruction rather than a static warning.
class _ScanningCard extends StatefulWidget {
  const _ScanningCard();
  @override
  State<_ScanningCard> createState() => _ScanningCardState();
}

class _ScanningCardState extends State<_ScanningCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _Glass(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              AnimatedBuilder(
                animation: _c,
                builder: (_, child) => Transform.rotate(angle: math.sin(_c.value * math.pi * 2) * 0.35, child: child),
                child: const Icon(Icons.phonelink_ring_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Pan your camera slowly to find the ground',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, height: 1.3)),
              ),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) => LinearProgressIndicator(
                  minHeight: 3,
                  value: null,
                  backgroundColor: Colors.white.withValues(alpha: 0.18),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF60A5FA)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text('Then tap the floor to drop the route',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5)),
          ]),
        ),
      ),
    );
  }
}

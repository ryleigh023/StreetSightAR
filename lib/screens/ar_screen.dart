import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/food_classifier.dart';
import '../services/food_service.dart';
import '../services/geo.dart';
import '../services/guidance.dart';
import '../services/pose_confidence.dart';
import '../services/tactile_compass.dart';
import '../services/walk_simulator.dart';
import '../services/settings.dart';
import '../services/storefront_matcher.dart';
import '../theme.dart';
import 'arrival_sheet.dart';
import '../services/places_service.dart';
import '../services/poi.dart';
import '../services/routing.dart';
import '../services/scene_classifier.dart';
import '../services/scene_gate.dart';
import '../services/sign_translator.dart';
import '../services/translation_service.dart';

const _fov = 60.0; // approx horizontal camera field of view, degrees
// The app's terracotta, so the chrome on this screen belongs to the same
// product as the home screen. The chevrons themselves stay blue and white:
// they have to read as a machine-placed guide against unpredictable street
// colour, which warm tones do not survive.
const _accent = AppColors.brand;
const _warn = AppColors.amber; // allergen chips only

class ArScreen extends StatefulWidget {
  final Place destination;
  final WalkRoute route;
  final Set<Interest> interests;
  const ArScreen({super.key, required this.destination, required this.route, required this.interests});
  @override
  State<ArScreen> createState() => _ArScreenState();
}

class _ArScreenState extends State<ArScreen> {
  CameraController? _cam;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  // Smoothed device pitch (degrees, +down) driving the ground trail's
  // vanishing point — see _arrow(). Starts at a plausible "held up, tilted
  // slightly down" default until the first sensor reading arrives.
  double _pitchDeg = 20;
  DateTime _lastPitchUpdate = DateTime(0);
  final _translator = TranslationService();
  final _sceneClassifier = SceneClassifier();
  late final _gate = SceneGate(_sceneClassifier);

  // Scene gate: navigation UI stays locked until we believe you're outdoors.
  CameraImage? _latestFrame;
  Position? _lastPosition;
  bool _gateRunning = false;
  SceneGateResult? _gateResult;
  bool _bypassGate = false;

  LatLng? _me;
  double _heading = 0;
  int _wp = 0;
  List<Poi> _pois = [];
  LatLng? _poiFetchedAt;

  bool _translateOn = true;
  final _guide = Guidance();
  final _jitter = HeadingJitter();

  /// Signs in the current frame that match a known nearby place.
  List<StorefrontMatch> _storefronts = const [];
  final _tactile = TactileCompass();
  WalkSimulator? _sim;
  StreamSubscription<SimFix>? _simSub;
  PoseConfidence _pose = PoseConfidence.unknown;
  double? _gpsAccuracyM;

  /// Set briefly after a waypoint is cleared, to acknowledge the turn.
  /// Confirming a correct move is what builds trust in an overlay; without
  /// it the user only ever hears from the app when something is wrong.
  DateTime? _afterglowAt;
  final _startedAt = DateTime.now();
  bool _arrivalShown = false;
  bool _ocrBusy = false;
  DateTime _lastOcr = DateTime(0);
  List<TranslatedBlock> _blocks = [];
  Size _imageSize = Size.zero; // upright image size

  // Food identification: one-shot, user-triggered (a cloud call per tap, not per frame).
  final _foodService = FoodService();
  late final _foodOnDevice = FoodClassifier(_sceneClassifier);
  bool _foodBusy = false;
  FoodResult? _food;
  String? _foodMessage; // error / "no food found" text shown in place of a result

  @override
  void initState() {
    super.initState();
    _guide.init();
    _init();
  }

  Future<void> _init() async {
    try {
      await _sceneClassifier.load();
    } catch (_) {
      // Model failed to load → gate falls back to GPS/VPS signals only.
    }
    final cams = await availableCameras();
    final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back);
    final cam = CameraController(back, ResolutionPreset.medium,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
    await cam.initialize();
    await cam.lockCaptureOrientation(DeviceOrientation.portraitUp);
    if (!mounted) {
      await cam.dispose();
      return;
    }
    _cam = cam;
    await cam.startImageStream(_onFrame);
    setState(() {});

    _posSub = Geolocator.getPositionStream(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 2))
        .listen(_onPosition);
    _compassSub = FlutterCompass.events?.listen((e) {
      if (e.heading == null || !mounted) return;
      final h = (e.heading! + 360) % 360;
      _jitter.add(h);
      setState(() {
        _heading = h;
        _pose = _poseNow();
      });
    });
    _accelSub = accelerometerEventStream().listen(_onAccel);
    _tactile.start();
    if (settings.demoWalk) _startDemoWalk();
  }

  /// Replaces the GPS and compass feeds with a timed walk along the route.
  /// Both real subscriptions are cancelled so a stale fix cannot fight the
  /// simulated one.
  void _startDemoWalk() {
    _posSub?.cancel();
    _compassSub?.cancel();
    final sim = _sim = WalkSimulator(widget.route.points);
    _simSub = sim.start().listen((f) {
      if (!mounted) return;
      _jitter.add(f.heading);
      setState(() => _heading = f.heading);
      _applyFix(f.pos, f.accuracyM, f.speedMs);
    });
  }

  // Device pitch from gravity. The on-device test confirmed the ground
  // trail moved the wrong way as the phone tilted, so this is negated from
  // the original atan2(z, y) derivation (which assumed a specific Android
  // axis convention that didn't hold on the test device). _pitchDebug below
  // mirrors the live raw/smoothed values on screen so a future mismatch can
  // be diagnosed from actual numbers instead of another guess-and-flip pass.
  void _onAccel(AccelerometerEvent e) {
    final now = DateTime.now();
    if (now.difference(_lastPitchUpdate).inMilliseconds < 80) return; // ~12 Hz is plenty, avoids jank
    _lastPitchUpdate = now;
    // Clamp the raw reading before blending it in: accelerometer noise (or
    // the phone briefly going near-flat/near-vertical) can otherwise produce
    // wild instantaneous angles that yank the horizon — and with it the
    // whole ground trail — off the actual ground plane for a frame or two.
    final raw = (-math.atan2(e.z, e.y) * 180 / math.pi).clamp(0.0, 45.0);
    // Heavier smoothing (was 0.85/0.15): the trail's anchoring reads as
    // "floaty"/misaligned far more from a jittery horizon than from a
    // slightly laggy one, so favor stability here.
    if (mounted) setState(() => _pitchDeg = _pitchDeg * 0.92 + raw * 0.08);
  }

  Future<void> _runGate() async {
    final frame = _latestFrame, pos = _lastPosition;
    if (_gateRunning || frame == null || pos == null) return;
    _gateRunning = true;
    try {
      final r = await _gate.evaluate(
          frame: frame, sensorOrientation: _cam?.description.sensorOrientation ?? 90, position: pos);
      if (mounted) setState(() => _gateResult = r);
    } catch (_) {
      // Gate itself failed → don't trap the user; treat as inconclusive/outdoors.
      if (mounted) setState(() => _gateResult = const SceneGateResult(true, 'Gate unavailable'));
    } finally {
      _gateRunning = false;
    }
  }

  void _retryGate() {
    setState(() => _gateResult = null);
    _runGate();
  }

  PoseConfidence _poseNow() {
    // A simulated walk has, by construction, a perfect position and
    // heading. Letting the confidence engine derive a band from a real
    // compass sitting on a desk would degrade the overlay in the middle of
    // a recording for reasons that have nothing to do with the demo.
    if (settings.demoWalk) return const PoseConfidence(1, PoseBand.solid, '');
    return PoseConfidence.from(
      gpsAccuracyM: _gpsAccuracyM,
      hasHeading: _heading != 0 || _jitter.degrees > 0,
      headingJitterDeg: _jitter.degrees,
    );
  }

  void _onPosition(Position p) {
    _lastPosition = p;
    _applyFix(LatLng(p.latitude, p.longitude), p.accuracy,
        p.speed.isFinite && p.speed > 0 ? p.speed : 1.3);
  }

  /// Everything downstream of a position fix, whether it came from GPS or
  /// from the demo walker. Keeping one path means the demo exercises the
  /// real navigation logic rather than a parallel imitation of it.
  void _applyFix(LatLng me, double accuracyM, double speedMs) {
    _gpsAccuracyM = accuracyM;
    if (_gateResult == null) _runGate();
    final pts = widget.route.points;
    // Advance to the first waypoint still >12 m ahead.
    var wp = _wp;
    while (wp < pts.length - 1 && distanceM(me, pts[wp]) < 12) {
      wp++;
    }
    // Clearing a waypoint means a turn was taken correctly — acknowledge it.
    if (wp != _wp) {
      _afterglowAt = DateTime.now();
      if (settings.haptics) HapticFeedback.mediumImpact();
    }

    setState(() {
      _me = me;
      _wp = wp;
      _pose = _poseNow();
    });

    // Spoken and felt cues ride the position stream, not the build: build
    // also runs on every compass and accelerometer tick, which carry no new
    // navigational information.
    final remaining = remainingAlongRoute(pts, me, wp);
    final arrived = remaining < 20;
    final turn = angleDiff(_heading, bearingDeg(me, pts[wp]));
    _guide.announce(
      instruction: arrived
          ? 'You have arrived'
          : turn > 25
              ? 'Turn right'
              : turn < -25
                  ? 'Turn left'
                  : 'Continue this direction',
      distanceM: remaining,
      arrived: arrived,
      speedMs: speedMs,
    );
    if (arrived && !_arrivalShown && mounted) {
      _arrivalShown = true;
      showArrivalSheet(
        context,
        destination: widget.destination,
        walkedM: widget.route.distanceM,
        took: DateTime.now().difference(_startedAt),
      );
    }
    if (_poiFetchedAt == null || distanceM(me, _poiFetchedAt!) > 150) {
      _poiFetchedAt = me;
      nearbyPois(me, widget.interests).then((v) {
        if (mounted) setState(() => _pois = v);
      }).catchError((_) {});
    }
  }

  // --- sign translation ---------------------------------------------------
  Future<void> _onFrame(CameraImage img) async {
    _latestFrame = img;
    if (_gateResult == null) {
      _runGate();
      return;
    }
    if (!_navUnlocked) return;
    if (!_translateOn || _ocrBusy || DateTime.now().difference(_lastOcr).inMilliseconds < 1200) return;
    _ocrBusy = true;
    try {
      final r = await _translator.process(img, _cam?.description.sensorOrientation ?? 90);
      if (mounted) {
        // The OCR pass has already read every sign in frame. Cross-checking
        // that text against the places we know are nearby turns two
        // independent pipelines into storefront recognition, and lets a POI
        // label be pinned to the sign the camera actually sees rather than
        // to a bearing estimate.
        final me = _me;
        final matches = me == null || _pois.isEmpty
            ? const <StorefrontMatch>[]
            : StorefrontMatcher.matchFrame(
                signs: [for (final b in r.blocks) (b.box, b.original)],
                me: me,
                nearby: _pois,
              );
        setState(() {
          _blocks = r.blocks;
          _imageSize = r.imageSize;
          _storefronts = matches;
        });
      }
    } catch (_) {
      // Dropped frame; try the next one.
    } finally {
      _lastOcr = DateTime.now();
      _ocrBusy = false;
    }
  }

  Future<void> _identifyFood() async {
    final frame = _latestFrame;
    if (_foodBusy || frame == null) return;
    setState(() {
      _foodBusy = true;
      _food = null;
      _foodMessage = null;
    });
    final orientation = _cam?.description.sensorOrientation ?? 90;
    try {
      FoodResult? r;
      try {
        final pos = _lastPosition;
        r = await _foodService.identify(frame, orientation,
            lat: pos?.latitude, lng: pos?.longitude, destination: widget.destination.name);
      } on FoodServiceException {
        // No OpenAI key, or no network. Fall back to the MobileNet already
        // resident for the scene gate: narrower, but it needs neither, and
        // this feature is most often used exactly where both are missing.
        //
        // Deliberately not rethrowing when the fallback finds nothing. The
        // cloud error is true but unhelpful: the user pointed at something
        // and got told to edit a config file, when the honest answer is that
        // no dish was recognised. Which services are configured is already
        // stated in preferences.
        r = await _foodOnDevice.identify(frame, orientation);
      }
      if (mounted) {
        setState(() {
          _food = r;
          _foodMessage = r == null ? 'No dish recognised. Fill the frame with the food and try again.' : null;
        });
      }
    } on FoodServiceException catch (e) {
      if (mounted) setState(() => _foodMessage = e.message);
    } catch (_) {
      if (mounted) setState(() => _foodMessage = 'Food lookup failed. Try again.');
    } finally {
      if (mounted) setState(() => _foodBusy = false);
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _simSub?.cancel();
    _sim?.stop();
    _tactile.stop();
    _guide.dispose();
    _compassSub?.cancel();
    _accelSub?.cancel();
    _cam?.dispose();
    _translator.dispose();
    _sceneClassifier.dispose();
    super.dispose();
  }

  /// The scene gate exists to stop people using AR indoors. A demo walk is
  /// filmed indoors by definition, so it unlocks too — otherwise the first
  /// thing a recording shows is the gate refusing to open.
  bool get _navUnlocked => _bypassGate || settings.demoWalk || (_gateResult?.outdoors ?? false);

  // TEMPORARY: live pitch readout for calibrating the ground trail's
  // horizon. Tilt the phone down toward the ground and confirm pitchDeg
  // rises toward 45; tilt it back up toward level and confirm it falls
  // toward 0. If it does the opposite, or sits flat regardless of tilt,
  // report the raw ay/az numbers at both positions instead of just "still
  // wrong" — that pins down whether this needs a sign flip, an axis swap,
  // or an offset, instead of another guess. Remove once the trail is
  // confirmed correct on-device.
 

  // --- UI -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pts = widget.route.points;
    final me = _me;
    final remaining =
        me == null ? widget.route.distanceM : remainingAlongRoute(pts, me, _wp);
    final arrived = me != null && remaining < 20;
    final turn = me == null ? 0.0 : angleDiff(_heading, bearingDeg(me, pts[_wp]));
    _tactile.update(arrived ? 0 : turn);

    return Scaffold(
      body: LayoutBuilder(builder: (context, box) {
        final screen = box.biggest;
        return Stack(fit: StackFit.expand, children: [
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: cam.value.previewSize!.height,
                height: cam.value.previewSize!.width,
                child: CameraPreview(cam),
              ),
            ),
          ),
          if (_navUnlocked) ...[
            ..._poiWidgets(screen),
            ..._translationWidgets(screen),
            ..._storefrontWidgets(screen),
            // Overlay density follows pose confidence. At the bottom band
            // nothing is drawn on the world at all — a flat card and the
            // spoken cue stay correct no matter how lost the tracking is.
            // No Opacity wrapper here: _arrow returns a Positioned, and a
            // Positioned must be a direct child of the Stack or its parent
            // data is the wrong type and layout throws every frame. The
            // painter already applies _pose.overlayOpacity itself.
            if (!arrived && !_pose.usesFallbackCard) _arrow(turn, screen),
            if (!arrived && _pose.usesFallbackCard) _fallbackCard(turn, remaining),
            if (!arrived && !_pose.usesFallbackCard) _turnCone(screen),
            if (_afterglowAt != null) _afterglow(),
            _miniMap(screen),
            _bottomBar(remaining, arrived),
            _foodButton(),
            if (_food != null || _foodMessage != null) _foodCard(),
          ] else
            _gateOverlay(),
          _topBar(remaining, arrived),
        ]);
      }),
    );
  }


  // Screen bands reserved for the top/bottom chrome. The trail and any OCR
  // translation overlay are kept clear of these so they never render on top
  // of (or get mistaken for) the nav bars.
  static const _topBarReservedH = 96.0;
  static const _bottomBarReservedH = 290.0;

  // Walks the actual route polyline (not a straight line to the next
  // waypoint) and returns the point [targetD] metres along it from the
  // start, so the trail can bend exactly where the street does. Returns
  // null once the route is shorter than [targetD] — caller stops the trail.
  LatLng? _pointAtPathDistance(List<LatLng> path, double targetD) {
    var acc = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      final segD = distanceM(path[i], path[i + 1]);
      if (segD <= 0) continue;
      if (acc + segD >= targetD) {
        final t = (targetD - acc) / segD;
        return LatLng(path[i].lat + (path[i + 1].lat - path[i].lat) * t,
            path[i].lng + (path[i + 1].lng - path[i].lng) * t);
      }
      acc += segD;
    }
    return null;
  }

  // Projects a ground-plane point — given as metres straight ahead
  // (`forward`) and metres to the right (`lateral`) of the camera's current
  // position/heading — into screen pixels with a standard pinhole camera
  // model: the camera sits `_camHeightM` above the ground, tilted down by
  // the smoothed device pitch (`phiRad`). This is what actually ties the
  // trail to the flat ground plane (correct convergence to the horizon,
  // correct foreshortening) instead of an empirical screen-space curve.
  // Returns null for points behind/at the camera, which aren't projectable.
  /// Pitch actually used for ground projection. The raw reading is honest
  /// but useless at the extremes: near 0° (phone held upright at a wall) the
  /// ground plane runs off to the horizon and everything collapses into a
  /// cluster of specks, and past ~60° the trail falls off the bottom of the
  /// screen. Clamping keeps the overlay legible in both cases.
  double get _trailPitchRad {
    // A demo is filmed with the phone flat on a desk or held casually, and
    // the real pitch then throws the ground plane off the top of the frame
    // entirely. Pin it to a natural held-up-while-walking angle so the path
    // always lands where it would on the street.
    if (settings.demoWalk) return 18 * math.pi / 180;
    return _pitchDeg.clamp(12.0, 55.0) * math.pi / 180;
  }

  Offset? _projectGround(double forward, double lateral, double phiRad, double fx, double fy, Size screen,
      {double heightM = 0}) {
    final drop = _camHeightM - heightM; // how far the point sits below the camera
    final camY = -drop * math.cos(phiRad) + forward * math.sin(phiRad);
    final camZ = drop * math.sin(phiRad) + forward * math.cos(phiRad);
    if (camZ < 0.15) return null;
    return Offset(
      screen.width / 2 + (lateral / camZ) * fx,
      screen.height / 2 - (camY / camZ) * fy,
    );
  }

  // Camera model for every ground projection on this screen.
  static const _camHeightM = 1.3; // approx phone height above ground, held up while walking
  static const _vFovDeg = 70.0; // approx vertical FOV in portrait, degrees

  /// The route as a painted ribbon on the road, with chevrons running along
  /// it — the way Live View and every shipped AR walking navigator draws it.
  ///
  /// Separate floating markers were tried first and read badly: on a
  /// straight they stack into one blob, and they never look like they are
  /// *on* the street. A continuous surface follows the kerb, bends through
  /// corners, and gives the chevrons something to sit on.
  static const _ribbonHalfWidthM = 0.78; // half the painted width
  static const _ribbonStartM = 1.4; // close enough to run off the bottom edge, far
  // enough that the strip is not all foreground
  static const _ribbonStepM = 1.1; // sampling interval along the route
  static const _ribbonRangeM = 26.0; // how far ahead to paint

  Widget _arrow(double turn, Size screen) {
    final aligned = turn.abs() < 20;
    final phiRad = _trailPitchRad;
    final fx = (screen.width / 2) / math.tan(_fov * math.pi / 360);
    final fy = (screen.height / 2) / math.tan(_vFovDeg * math.pi / 360);

    final left = <Offset>[];
    final right = <Offset>[];
    final centre = <Offset>[];
    final widths = <double>[];

    final me = _me;
    if (me != null) {
      final pts = widget.route.points;
      final path = [me, ...pts.sublist(_wp.clamp(0, pts.length))];

      // Ground-plane positions of the route ahead, relative to the camera.
      final ground = <Offset>[];
      for (var d = _ribbonStartM; d <= _ribbonRangeM * _pose.trailFraction; d += _ribbonStepM) {
        final target = _pointAtPathDistance(path, d);
        if (target == null) break;
        final relRad = angleDiff(_heading, bearingDeg(me, target)) * math.pi / 180;
        final dist = distanceM(me, target);
        ground.add(Offset(dist * math.cos(relRad), dist * math.sin(relRad)));
      }

      // Walk the strip, offsetting each sample perpendicular to the local
      // direction of travel to get the two painted edges.
      for (var i = 0; i < ground.length; i++) {
        final here = ground[i];
        final next = i + 1 < ground.length ? ground[i + 1] : null;
        final prev = i > 0 ? ground[i - 1] : null;
        final dir = next != null ? next - here : (prev != null ? here - prev : const Offset(1, 0));
        final len = dir.distance;
        if (len < 1e-3) continue;
        final n = Offset(-dir.dy / len, dir.dx / len); // perpendicular, on the ground

        final l = _projectGround(
            here.dx + n.dx * _ribbonHalfWidthM, here.dy + n.dy * _ribbonHalfWidthM, phiRad, fx, fy, screen);
        final r = _projectGround(
            here.dx - n.dx * _ribbonHalfWidthM, here.dy - n.dy * _ribbonHalfWidthM, phiRad, fx, fy, screen);
        final c = _projectGround(here.dx, here.dy, phiRad, fx, fy, screen);
        if (l == null || r == null || c == null) break; // passed behind the camera

        left.add(l);
        right.add(r);
        centre.add(c);
        widths.add((l - r).distance);
      }
    }

    // Teal while tracking the route, amber while a turn is pending.
    final paint = aligned ? const Color(0xFF17C3DC) : const Color(0xFFFFA724);

    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _TrailPainter(
            left: left,
            right: right,
            centre: centre,
            widths: widths,
            colour: paint,
            opacity: _pose.overlayOpacity,
            // Chevrons crawl forward along the ribbon, which is what makes
            // it read as direction rather than as a painted stripe.
            phase: (DateTime.now().millisecondsSinceEpoch % 2200) / 2200,
          ),
        ),
      ),
    );
  }

  // Markers stay fully hidden until the user is actually close — surfacing
  // every POI within hundreds of metres buried the screen in tags for
  // places nobody could even see yet. Once within range, a marker reveals
  // itself with a line protruding up from its real ground position (see
  // _PoiMarker) rather than just popping in.
  static const _poiRevealRadiusM = 30.48; // 100 ft
  static const _poiLineMaxH = 86.0; // px the reveal line grows to before the label appears

  Iterable<Widget> _poiWidgets(Size screen) sync* {
    final me = _me;
    if (me == null) return;
    final phiRad = _pitchDeg * math.pi / 180;
    final fx = (screen.width / 2) / math.tan(_fov * math.pi / 360);
    final fy = (screen.height / 2) / math.tan(_vFovDeg * math.pi / 360);

    var n = 0;
    final sorted = [..._pois]..sort((a, b) => distanceM(me, a.pos).compareTo(distanceM(me, b.pos)));
    for (final p in sorted) {
      final d = distanceM(me, p.pos);
      if (d > _poiRevealRadiusM) continue;
      final diff = angleDiff(_heading, bearingDeg(me, p.pos));
      if (diff.abs() > _fov / 2 || n >= 5) continue;
      n++;

      // Anchor the marker to the place's actual ground position using the
      // same pinhole projection as the directional trail, so it reads as
      // "planted" at the right spot on the street rather than floating at a
      // fixed screen height.
      final relRad = diff * math.pi / 180;
      final f = d * math.cos(relRad);
      final l = d * math.sin(relRad);
      final ground = _projectGround(f, l, phiRad, fx, fy, screen);
      final anchor = Offset(
        (ground?.dx ?? screen.width / 2 + diff / _fov * screen.width).clamp(20.0, screen.width - 20.0),
        (ground?.dy ?? screen.height * 0.8)
            .clamp(_topBarReservedH + _poiLineMaxH + 40, screen.height - _bottomBarReservedH),
      );

      yield _PoiMarker(
        key: ValueKey('${p.name}_${p.pos.lat}_${p.pos.lng}'),
        anchor: anchor,
        lineMaxH: _poiLineMaxH,
        name: p.name,
        distanceM: d,
        emoji: p.kind.emoji,
        screenWidth: screen.width,
      );
    }
  }

  /// Labels pinned to recognised storefronts.
  ///
  /// Drawn above the sign rather than over it, so the shop's own name stays
  /// readable underneath — the point is to confirm what you are looking at,
  /// not to cover it.
  Iterable<Widget> _storefrontWidgets(Size screen) sync* {
    if (_storefronts.isEmpty || _imageSize == Size.zero) return;
    final scale = math.max(screen.width / _imageSize.width, screen.height / _imageSize.height);
    final dx = (screen.width - _imageSize.width * scale) / 2;
    final dy = (screen.height - _imageSize.height * scale) / 2;

    for (final m in _storefronts) {
      final r = Rect.fromLTRB(m.box.left * scale + dx, m.box.top * scale + dy, m.box.right * scale + dx,
          m.box.bottom * scale + dy);
      if (r.top < _topBarReservedH || r.bottom > screen.height - _bottomBarReservedH) continue;

      final isDestination =
          m.poi.name.toLowerCase() == widget.destination.name.split(',').first.trim().toLowerCase();

      yield Positioned(
        left: (r.center.dx - 110).clamp(6.0, math.max(6.0, screen.width - 226)),
        top: math.max(_topBarReservedH, r.top - 46),
        width: 220,
        child: IgnorePointer(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: (isDestination ? AppColors.brand : Colors.black).withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(isDestination ? Icons.flag_rounded : Icons.storefront_rounded,
                    size: 15, color: Colors.white),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(m.poi.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 7),
                Text(settings.formatDistance(m.distanceM),
                    style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ]),
            ),
            // Small stem down toward the sign it belongs to.
            Container(width: 2, height: 10, color: Colors.white.withValues(alpha: 0.5)),
          ]),
        ),
      );
    }
  }

  Iterable<Widget> _translationWidgets(Size screen) sync* {
    if (!_translateOn || _imageSize == Size.zero) return;
    // Preview is cover-fit: map upright image coords to screen coords.
    final scale = math.max(screen.width / _imageSize.width, screen.height / _imageSize.height);
    final dx = (screen.width - _imageSize.width * scale) / 2;
    final dy = (screen.height - _imageSize.height * scale) / 2;
    for (final b in _blocks) {
      final r = Rect.fromLTRB(b.box.left * scale + dx, b.box.top * scale + dy, b.box.right * scale + dx,
          b.box.bottom * scale + dy);
      // Never draw a translated label over the top/bottom chrome — a noisy
      // OCR false-positive (glare, a reflection, a stray glyph) should not
      // be able to visually replace the nav bars.
      if (r.top < _topBarReservedH || r.bottom > screen.height - _bottomBarReservedH) continue;
      yield Positioned.fromRect(
        rect: r.inflate(4),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(color: const Color(0xE6FFC107), borderRadius: BorderRadius.circular(6)),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Text(b.translated,
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      );
    }
  }

  // The Live View instruction card: a solid blue slab carrying the single
  // next manoeuvre, its distance and the destination. It deliberately does
  // not float over the chevrons — _topBarReservedH keeps that band clear.
  Widget _topBar(double remaining, bool arrived) {
    final turn = _me == null ? 0.0 : angleDiff(_heading, bearingDeg(_me!, widget.route.points[_wp]));
    final (icon, instruction) = arrived
        ? (Icons.flag_rounded, 'You have arrived')
        : turn > 25
            ? (Icons.turn_right_rounded, 'Turn right')
            : turn < -25
                ? (Icons.turn_left_rounded, 'Turn left')
                : (Icons.straight_rounded, 'Continue this direction');

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _circleButton(Icons.arrow_back_rounded, () => Navigator.pop(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2B7CFF), Color(0xFF1A5FD8)],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const [BoxShadow(color: Color(0x45000000), blurRadius: 16, offset: Offset(0, 5))],
                ),
                child: Row(children: [
                  Icon(icon, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(instruction,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                      const SizedBox(height: 2),
                      Row(children: [
                        Text(arrived ? 'Destination reached' : _fmtDistance(remaining),
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.95),
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        if (!arrived) ...[
                          Text(' · ',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                          Expanded(
                            child: Text(widget.destination.name.split(',').first,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
                          ),
                        ],
                      ]),
                    ]),
                  ),
                ]),
              ),
              _confidenceChip(),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  static String _fmtDistance(double m) => settings.formatDistance(m);

  Widget _circleButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 46, height: 46, child: Icon(icon, color: Colors.white, size: 22)),
      ),
    );
  }


  Widget _foodButton() {
    return Positioned(
      // Left side: the mini-map occupies the right corner, and the two were
      // overlapping.
      left: 12,
      bottom: _bottomBarReservedH - 28,
      child: FloatingActionButton(
        heroTag: 'foodFab',
        backgroundColor: Colors.black.withValues(alpha: 0.78),
        onPressed: _foodBusy ? null : _identifyFood,
        child: _foodBusy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : const Icon(Icons.restaurant, color: Colors.white),
      ),
    );
  }

  Widget _foodCard() {
    final f = _food;
    void close() => setState(() {
          _food = null;
          _foodMessage = null;
        });
    Widget chips(String label, List<String> items, Color color) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            for (final i in items)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(10)),
                child: Text(i, style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
          ]),
        );

    return Positioned(
      left: 12,
      right: 12,
      bottom: _bottomBarReservedH + 36,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: f == null
                  ? Text(_foodMessage ?? '', style: const TextStyle(color: Colors.white))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.name,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      if (f.localName != null || f.origin != null)
                        Text([?f.localName, ?f.origin].join(' · '),
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
            ),
            IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                onPressed: close),
          ]),
          if (f != null) ...[
            if (f.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text(f.description, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            if (f.ingredients.isNotEmpty) chips('Contains', f.ingredients, Colors.white),
            if (f.allergens.isNotEmpty) chips('Allergens', f.allergens, _warn),
          ],
        ]),
      ),
    );
  }

  Widget _gateOverlay() {
    final r = _gateResult;
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (r == null) ...[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Checking your surroundings…\nPoint the camera at the street.', textAlign: TextAlign.center),
        ] else ...[
          const Icon(Icons.home_outlined, size: 56),
          const SizedBox(height: 12),
          Text(r.reason, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('AR navigation starts once you step outside.', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: _retryGate, icon: const Icon(Icons.refresh), label: const Text('Check again')),
          TextButton(
            onPressed: () => setState(() => _bypassGate = true),
            child: const Text("I'm outside — continue anyway"),
          ),
        ],
      ]),
    );
  }

  // Circular plan-view inset, the way Live View pairs the camera overlay
  // with a small map. Drawn from the route polyline we already hold rather
  // than from map tiles — there is no map SDK in this app, and a plain
  // vector of the route is what the walker actually needs here.
  static const _miniMapSize = 132.0;

  Widget _miniMap(Size screen) {
    final me = _me;
    if (me == null) return const SizedBox.shrink();
    return Positioned(
      // Bottom-right corner, as in every shipped navigator. Centred, it sat
      // directly on top of the painted route.
      bottom: 104,
      left: screen.width - _miniMapSize - 14,
      width: _miniMapSize,
      height: _miniMapSize,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFF1F3F6),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 18, offset: Offset(0, 4))],
          ),
          child: ClipOval(
            child: CustomPaint(
              painter: _MiniMapPainter(
                me: me,
                heading: _heading,
                route: widget.route.points.sublist(_wp.clamp(0, widget.route.points.length)),
                destination: widget.destination.pos,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A wedge painted on the ground where the next turn begins, widening as
  /// you close on it.
  ///
  /// This is the "cone of certainty" idea: show where the decision happens
  /// rather than firing an arrow off to the horizon. It appears only inside
  /// the approach window, so a long straight stays uncluttered — the cue
  /// arrives when it can still be acted on, and nowhere else.
  static const _coneApproachM = 28.0;
  static const _coneRadiusM = 3.4;

  Widget _turnCone(Size screen) {
    final me = _me;
    if (me == null) return const SizedBox.shrink();
    final pts = widget.route.points;
    if (_wp >= pts.length) return const SizedBox.shrink();

    final corner = pts[_wp];
    final toCorner = distanceM(me, corner);
    if (toCorner > _coneApproachM || toCorner < 2) return const SizedBox.shrink();

    // Only worth drawing where the route actually changes direction.
    final after = _wp + 1 < pts.length ? pts[_wp + 1] : null;
    if (after == null) return const SizedBox.shrink();
    final turnDeg = angleDiff(bearingDeg(me, corner), bearingDeg(corner, after));
    if (turnDeg.abs() < 22) return const SizedBox.shrink();

    final phiRad = _trailPitchRad;
    final fx = (screen.width / 2) / math.tan(_fov * math.pi / 360);
    final fy = (screen.height / 2) / math.tan(_vFovDeg * math.pi / 360);

    // Corner position relative to the camera, on the ground.
    final relRad = angleDiff(_heading, bearingDeg(me, corner)) * math.pi / 180;
    final cf = toCorner * math.cos(relRad);
    final cl = toCorner * math.sin(relRad);

    // The wedge opens along the direction of travel *after* the corner.
    final outRad = angleDiff(_heading, bearingDeg(corner, after)) * math.pi / 180;
    final half = 26 * math.pi / 180;

    final ring = <Offset>[];
    final centre = _projectGround(cf, cl, phiRad, fx, fy, screen);
    if (centre == null) return const SizedBox.shrink();
    ring.add(centre);
    for (var i = 0; i <= 10; i++) {
      final a = outRad - half + (2 * half) * (i / 10);
      final p = _projectGround(
          cf + math.cos(a) * _coneRadiusM, cl + math.sin(a) * _coneRadiusM, phiRad, fx, fy, screen);
      if (p == null) return const SizedBox.shrink();
      ring.add(p);
    }

    // Tightens and brightens as you approach, so it reads as a countdown
    // rather than a static decal.
    final nearness = (1 - toCorner / _coneApproachM).clamp(0.0, 1.0);
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _ConePainter(
            ring: ring,
            colour: const Color(0xFF4DA3FF),
            strength: (0.25 + nearness * 0.6) * _pose.overlayOpacity,
          ),
        ),
      ),
    );
  }

  /// Honest status, shown only when there is something to say. A working
  /// system should not narrate itself, so this disappears entirely at full
  /// confidence.
  Widget _confidenceChip() {
    if (_pose.band == PoseBand.solid) return const SizedBox.shrink();
    final poor = _pose.band == PoseBand.fallback;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: (poor ? Colors.black : Colors.black).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(poor ? Icons.gps_off_rounded : Icons.gps_not_fixed_rounded,
            size: 14, color: poor ? AppColors.amber : Colors.white70),
        const SizedBox(width: 7),
        Text(_pose.reason,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  /// The graceful-degrade path: when pose is too weak to anchor anything,
  /// stop drawing on the world and state the instruction plainly instead.
  Widget _fallbackCard(double turn, double remaining) {
    final (icon, label) = turn > 25
        ? (Icons.turn_right_rounded, 'Turn right')
        : turn < -25
            ? (Icons.turn_left_rounded, 'Turn left')
            : (Icons.straight_rounded, 'Continue this direction');
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 30),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 22),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 44),
          const SizedBox(height: 12),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(_fmtDistance(remaining),
              style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(_pose.reason,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.35)),
        ]),
      ),
    );
  }

  /// Brief confirmation that a turn was taken correctly, then it gets out
  /// of the way.
  Widget _afterglow() {
    final age = DateTime.now().difference(_afterglowAt!);
    if (age > const Duration(milliseconds: 1600)) return const SizedBox.shrink();
    final t = 1 - age.inMilliseconds / 1600;
    return IgnorePointer(
      child: Center(
        child: Opacity(
          opacity: (t * 1.4).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 1 + (1 - t) * 0.5,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sage.withValues(alpha: 0.9),
              ),
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 34),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(double remaining, bool arrived) {
    final mins = (widget.route.durationS * remaining / math.max(widget.route.distanceM, 1) / 60).ceil();
    final eta = DateTime.now().add(Duration(minutes: mins));
    final etaLabel = '${eta.hour.toString().padLeft(2, '0')}:${eta.minute.toString().padLeft(2, '0')}';
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(arrived ? 'Arrived' : '$mins min',
                            style:
                                const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                        Text(arrived ? 'You have arrived' : '${remaining.round()} m · Arrive at $etaLabel',
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                  const Icon(Icons.keyboard_arrow_up, color: Colors.white54),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            FloatingActionButton(
              heroTag: 'translateFab',
              backgroundColor: _translateOn ? _accent : Colors.black.withValues(alpha: 0.78),
              onPressed: () => setState(() {
                _translateOn = !_translateOn;
                _blocks = [];
              }),
              child: Icon(_translateOn ? Icons.translate : Icons.translate_outlined, color: Colors.white),
            ),
          ]),
        ),
      ),
    );
  }
}

// A POI marker that, the first time it's built (i.e. the moment a place
// enters reveal range — see _ArScreenState._poiWidgets), animates a line
// protruding up from its real ground position and fades/slides its label
// in at the top. Keyed per-place by the caller, so it animates exactly
// once per reveal rather than replaying on every rebuild while in range.
class _PoiMarker extends StatelessWidget {
  final Offset anchor;
  final double lineMaxH;
  final String name;
  final double distanceM;
  final String emoji;
  final double screenWidth;
  const _PoiMarker({
    required super.key,
    required this.anchor,
    required this.lineMaxH,
    required this.name,
    required this.distanceM,
    required this.emoji,
    required this.screenWidth,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) {
        final lineH = lineMaxH * t;
        final boxLeft = (anchor.dx - 85).clamp(4.0, screenWidth - 190);
        return Stack(children: [
          // Dot marking exactly where the place is on the ground.
          Positioned(
            left: anchor.dx - 5,
            top: anchor.dy - 5,
            child: Opacity(
              opacity: t,
              child: Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: _accent, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5)),
              ),
            ),
          ),
          // The protruding line itself, growing from the ground point up.
          Positioned(
            left: anchor.dx - 1,
            top: anchor.dy - lineH,
            child: Container(width: 2, height: lineH, color: Colors.white.withValues(alpha: 0.85 * t)),
          ),
          Positioned(
            left: boxLeft,
            top: anchor.dy - lineMaxH - 34,
            child: Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 10),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
                      child: Text(emoji, style: const TextStyle(fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                          Text('${distanceM.round()} m', style: const TextStyle(fontSize: 11, color: Colors.white70)),
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

/// Paints the route as a ground-hugging ribbon with chevrons crawling along
/// it. All geometry arrives already projected, so this is pure compositing
/// over a surface that genuinely lies on the road plane.
class _TrailPainter extends CustomPainter {
  final List<Offset> left, right, centre;
  final List<double> widths; // on-screen ribbon width at each sample
  final Color colour;
  final double opacity;
  final double phase;

  _TrailPainter({
    required this.left,
    required this.right,
    required this.centre,
    required this.widths,
    required this.colour,
    required this.opacity,
    required this.phase,
  });

  Path _ribbon() {
    final p = Path();
    if (left.length < 2) return p;
    p.moveTo(left.first.dx, left.first.dy);
    for (final o in left.skip(1)) {
      p.lineTo(o.dx, o.dy);
    }
    for (final o in right.reversed) {
      p.lineTo(o.dx, o.dy);
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (left.length < 2 || opacity <= 0) return;
    final ribbon = _ribbon();
    final bounds = ribbon.getBounds();

    // Fade the far end out instead of cutting it off at a hard edge, which
    // would read as the path stopping rather than receding.
    canvas.drawPath(
      ribbon,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(bounds.center.dx, bounds.bottom),
          Offset(bounds.center.dx, bounds.top),
          [colour.withValues(alpha: 0.72 * opacity), colour.withValues(alpha: 0.12 * opacity)],
        ),
    );

    // Edge lines, so the ribbon has a defined kerb against busy tarmac.
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white.withValues(alpha: 0.5 * opacity)
      ..strokeJoin = StrokeJoin.round;
    for (final side in [left, right]) {
      final p = Path()..moveTo(side.first.dx, side.first.dy);
      for (final o in side.skip(1)) {
        p.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(p, edge);
    }

    // Chevrons along the centre line, marching away from the viewer.
    for (var i = 1; i < centre.length - 1; i++) {
      // Evenly spaced in sample count, shifted by the animation phase.
      final slot = (i + phase * 3) % 3;
      if (slot >= 1) continue;

      final here = centre[i];
      final ahead = centre[i + 1];
      final dir = ahead - here;
      final len = dir.distance;
      if (len < 1e-3) continue;
      final u = dir / len;
      final v = Offset(-u.dy, u.dx);

      final w = widths[i] * 0.34;
      final tip = here + u * (w * 0.95);
      final a = here - u * (w * 0.35) + v * w;
      final b = here - u * (w * 0.35) - v * w;

      final chevron = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(b.dx, b.dy);

      // Depth fade matches the ribbon beneath, so a distant chevron does not
      // float brighter than the surface it is painted on.
      final t = 1 - i / centre.length;
      canvas.drawPath(
        chevron,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(3.0, w * 0.42)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white.withValues(alpha: (0.35 + 0.55 * t) * opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrailPainter oldDelegate) => true;
}


/// Plan view of the remaining route, rotated so the top of the circle is
/// whichever way the walker is currently facing.
class _MiniMapPainter extends CustomPainter {
  final LatLng me;
  final double heading;
  final List<LatLng> route;
  final LatLng destination;
  _MiniMapPainter({required this.me, required this.heading, required this.route, required this.destination});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.62); // walker sits low, so most of the circle is the road ahead
    final rad = heading * math.pi / 180;
    final cosH = math.cos(rad), sinH = math.sin(rad);

    // Local east/north metres, rotated into "facing up" screen axes.
    Offset toLocal(LatLng p) {
      final east = (p.lng - me.lng) * 111320 * math.cos(me.lat * math.pi / 180);
      final north = (p.lat - me.lat) * 110540;
      return Offset(east * cosH - north * sinH, -(east * sinH + north * cosH));
    }

    // Scale so the next stretch of route fills the circle, within limits —
    // an unclamped fit snaps wildly whenever a waypoint is passed.
    var far = 25.0;
    for (final p in route) {
      far = math.max(far, distanceM(me, p));
    }
    final mPerPx = (far.clamp(25.0, 400.0)) / (size.width * 0.42);

    final pts = [Offset.zero, ...route.map((p) => toLocal(p) / mPerPx)].map((o) => c + o).toList();

    // Route as a dotted blue run, matching the plan view in Live View.
    final dot = Paint()..color = const Color(0xFF2B6BF0);
    for (var i = 0; i < pts.length - 1; i++) {
      final seg = pts[i + 1] - pts[i];
      final n = (seg.distance / 9).floor();
      for (var k = 0; k <= n; k++) {
        final o = pts[i] + seg * (n == 0 ? 0 : k / n);
        canvas.drawCircle(o, 3.6, dot);
      }
    }

    // Destination marker.
    final d = c + toLocal(destination) / mPerPx;
    if (d.dx.isFinite && d.dy.isFinite) {
      canvas.drawCircle(d, 8, Paint()..color = const Color(0xFFDC2626));
      canvas.drawCircle(d, 3, Paint()..color = Colors.white);
    }

    // The walker: a halo plus a chevron pointing up, since the map is
    // already rotated into their heading.
    canvas.drawCircle(c, 17, Paint()..color = Colors.white.withValues(alpha: 0.9));
    final arrow = Path()
      ..moveTo(c.dx, c.dy - 12)
      ..lineTo(c.dx + 8.5, c.dy + 9)
      ..lineTo(c.dx, c.dy + 4.5)
      ..lineTo(c.dx - 8.5, c.dy + 9)
      ..close();
    canvas.drawPath(arrow, Paint()..color = const Color(0xFF1C4FD8));
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter old) => true;
}

/// Fills the turn wedge with a soft radial wash rather than a flat colour,
/// so it reads as a pool of light on the ground instead of a sticker.
class _ConePainter extends CustomPainter {
  final List<Offset> ring; // apex first, then the arc
  final Color colour;
  final double strength;
  _ConePainter({required this.ring, required this.colour, required this.strength});

  @override
  void paint(Canvas canvas, Size size) {
    if (ring.length < 3) return;
    final path = Path()..moveTo(ring.first.dx, ring.first.dy);
    for (final p in ring.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    final bounds = path.getBounds();
    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          colors: [
            colour.withValues(alpha: strength * 0.75),
            colour.withValues(alpha: strength * 0.12),
          ],
        ).createShader(bounds)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = colour.withValues(alpha: strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ConePainter old) => true;
}

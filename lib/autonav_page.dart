part of 'main.dart';

/// Autonav page (swipe down from Wheels; navigation_ws #30): the SLAM map as nav_relay
/// sends it, the robot, Nav2's plan and goal. Tap the map for a goal, drag from the goal
/// for its heading, two fingers pan and pinch-zoom; nothing goes out before GO. GO = mux
/// to autonomous, then the goal; CANCEL = cancel the goal, mux to stop. NAV UP / NAV STOP
/// drive app_bringup_manager through nav_relay; its stages show compact, tap for reasons.
/// One-finger gestures never turn the page: leave through "⌄ Wheels".
class AutonavPage extends StatefulWidget {
  const AutonavPage({
    super.key,
    required this.connected,
    required this.linkText,
    required this.linkColor,
    required this.robot,
    required this.nav,
    required this.map,
    required this.onGo,
    required this.onCancel,
    required this.onNavUp,
    required this.onNavStop,
    required this.onStop,
    this.onWheels,
    this.updates,
    this.liveNav,
  });

  final bool connected;
  final String linkText;
  final Color linkColor;

  /// /teleop/state, null when stale.
  final RobotState? robot;

  /// /teleop/nav/state, possibly stale (checked here).
  final NavState? nav;
  final NavMap? map;
  final void Function(double x, double y, double yaw) onGo;
  final VoidCallback onCancel;
  final VoidCallback onNavUp;
  final VoidCallback onNavStop;
  final VoidCallback onStop;
  final VoidCallback? onWheels;

  /// Notifies when [nav] changes, so the stages dialog stays live.
  final Listenable? updates;

  /// The newest nav state, read when [updates] fires (the widget may lag behind).
  final NavState? Function()? liveNav;

  @override
  State<AutonavPage> createState() => AutonavPageState();
}

enum _Touch { none, tap, heading, pinch }

class AutonavPageState extends State<AutonavPage> {
  MapView? view;
  NavPose? draft; // the goal being placed; sent with GO

  ui.Image? _image;
  Uint8List? _imageFor;

  final _pointers = <int, Offset>{};
  _Touch _touch = _Touch.none;
  Offset _downAt = Offset.zero;
  bool _headingMoved = false;
  Offset? _pinchFocal;
  double? _pinchDist;

  static const _tapSlop = 18.0, _goalGrab = 40.0;

  NavState? get _nav => widget.nav != null && widget.nav!.fresh ? widget.nav : null;

  @override
  void didUpdateWidget(AutonavPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final n = _nav, d = draft, g = n?.goal;
    // the relay has our goal: the draft has done its job
    if (d != null && g != null && (g.x - d.x).abs() < .01 && (g.y - d.y).abs() < .01 && (g.age ?? 99) < 10) {
      if (normalizeAngle(g.yaw - d.yaw).abs() < .01) draft = null;
    }
    _decode();
  }

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _decode() {
    final png = widget.map?.png;
    if (png == null || identical(png, _imageFor)) return;
    _imageFor = png;
    if (png.isEmpty) return;
    () async {
      final codec = await ui.instantiateImageCodec(png);
      final img = (await codec.getNextFrame()).image;
      codec.dispose();
      if (!mounted || !identical(png, _imageFor)) return img.dispose();
      setState(() {
        _image?.dispose();
        _image = img;
      });
    }()
        .catchError((Object _) {}); // a broken PNG: the old picture stays, the next map replaces it
  }

  /// A new size or meta keeps the place and zoom; the first one fits the whole map.
  MapView? _viewFor(Size size) {
    final meta = widget.map?.meta;
    if (meta == null) return null;
    final v = view;
    if (v == null) return view = MapView.fit(meta, size);
    if (v.size != size || !identical(v.meta, meta)) view = v.copyWith(meta: meta, size: size);
    return view;
  }

  // ---------------------------------------------------------------------------------------
  // gestures: raw pointers, so one finger and two fingers are told apart exactly

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      _downAt = e.localPosition;
      _headingMoved = false;
      final d = draft, v = view;
      _touch = d != null && v != null && (v.toScreen(Offset(d.x, d.y)) - e.localPosition).distance < _goalGrab
          ? _Touch.heading
          : _Touch.tap;
    } else {
      _touch = _Touch.pinch;
      _startPinch();
    }
  }

  void _startPinch() {
    final p = _pointers.values.take(2).toList();
    _pinchFocal = (p[0] + p[1]) / 2;
    _pinchDist = (p[0] - p[1]).distance;
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final v = view;
    switch (_touch) {
      case _Touch.tap:
        if ((e.localPosition - _downAt).distance > _tapSlop) _touch = _Touch.none; // a one-finger drag: nothing
      case _Touch.heading:
        final d = draft;
        if (v == null || d == null) return;
        final at = v.toScreen(Offset(d.x, d.y));
        if ((e.localPosition - at).distance < 12) return; // too close to tell a direction
        _headingMoved = true;
        setState(() => draft = NavPose(d.x, d.y, v.yawBetween(at, e.localPosition)));
      case _Touch.pinch:
        if (v == null || _pointers.length < 2) return;
        final p = _pointers.values.take(2).toList();
        final focal = (p[0] + p[1]) / 2, dist = (p[0] - p[1]).distance;
        final scale = _pinchDist! > 1 && dist > 1 ? dist / _pinchDist! : 1.0;
        setState(() => view = v.zoomPan(_pinchFocal!, scale, focal - _pinchFocal!));
        _pinchFocal = focal;
        _pinchDist = dist;
      case _Touch.none:
    }
  }

  void _onUp(PointerEvent e, {bool cancelled = false}) {
    if (_pointers.remove(e.pointer) == null) return;
    final v = view;
    if (!cancelled && v != null && (_touch == _Touch.tap || (_touch == _Touch.heading && !_headingMoved))) {
      _place(v, e.localPosition);
    }
    if (_pointers.isEmpty) {
      _touch = _Touch.none;
    } else if (_touch == _Touch.pinch && _pointers.length >= 2) {
      _startPinch();
    } else {
      _touch = _Touch.none; // a finger left over from a pinch doesn't tap or turn
    }
  }

  /// The goal at [at]; it faces away from the robot (or keeps the old heading).
  void _place(MapView v, Offset at) {
    HapticFeedback.selectionClick();
    final p = v.toMap(at);
    final pose = _nav?.pose;
    final yaw = pose != null && (Offset(pose.x, pose.y) - p).distance > .05
        ? atan2(p.dy - pose.y, p.dx - pose.x)
        : (draft?.yaw ?? 0.0);
    setState(() => draft = NavPose(p.dx, p.dy, yaw));
  }

  // ---------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 40, child: _header()),
            const SizedBox(height: 4),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(flex: 7, child: _mapArea()),
                const SizedBox(width: 12),
                SizedBox(width: 168, child: _side(context)),
              ]),
            ),
          ]),
        ),
      );

  (String, Color) get _nav2Text {
    final n = _nav;
    if (!widget.connected) return ('—', dim);
    if (n == null) return (widget.nav == null ? 'no relay' : 'no state', bad);
    if (n.nav2Up) return ('ready', ok);
    if (n.nav2Ready) return ('server up', warn);
    return ('down', bad);
  }

  Widget _header() {
    final (n2, n2c) = _nav2Text;
    final st = widget.robot;
    return Row(children: [
      const Text('AUTONAV', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
      const SizedBox(width: 12),
      Expanded(
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: widget.linkColor, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Flexible(child: Text(widget.linkText, overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim))),
          const SizedBox(width: 12),
          const Text('Nav2 ', style: TextStyle(color: dim)),
          Flexible(
            flex: 2,
            child: Text('● $n2',
                overflow: TextOverflow.ellipsis, style: TextStyle(color: n2c, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          const Text('mux ', style: TextStyle(color: dim)),
          Flexible(
            flex: 2,
            child: Text(
              st == null ? '—' : '${st.mode.toUpperCase()}${st.source == 'phone' ? '' : ' · ${st.source}'}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700, color: st == null ? dim : _modeColor(st.mode)),
            ),
          ),
        ]),
      ),
      if (widget.onWheels != null)
        TextButton(
          onPressed: widget.onWheels,
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
          child: const Text('⌄ Wheels'),
        ),
    ]);
  }

  Widget _mapArea() => Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: const Color(0xFF0B0D10),
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: LayoutBuilder(builder: (context, c) {
          final v = _viewFor(Size(c.maxWidth, c.maxHeight));
          final n = _nav;
          return _NoPageSwipe(
            child: Listener(
              key: const Key('nav-map-area'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: (e) => _onUp(e, cancelled: true),
              child: Stack(fit: StackFit.expand, children: [
                if (v == null)
                  Center(
                    child: Text(
                      !widget.connected
                          ? 'no link'
                          : _nav == null
                              ? 'waiting for nav_relay…'
                              : 'waiting for the map…',
                      style: const TextStyle(color: dim),
                    ),
                  )
                else ...[
                  Positioned.fromRect(
                    key: const Key('nav-map'),
                    rect: v.imageRect,
                    child: RawImage(image: _image, fit: BoxFit.fill, filterQuality: FilterQuality.none),
                  ),
                  CustomPaint(painter: _PlanPainter(v, n?.plan ?? const [])),
                  if (n?.goal case final g?)
                    _markerAt(v, g, const Key('nav-goal'),
                        _GoalMarker(active: n!.status == 'navigating', color: n.status == 'navigating' ? ok : dim)),
                  if (draft case final d?) _markerAt(v, d, const Key('nav-goal-draft'), const _GoalMarker(draft: true)),
                  if (n?.pose case final p?) _markerAt(v, p, const Key('nav-robot'), const _RobotMarker(), size: 26),
                ],
                Positioned(left: 8, top: 8, right: 8, child: _mapBanner()),
                if (v != null)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Row(children: [
                      _mapButton('⌖ center on robot',
                          n?.pose == null ? null : () => setState(() => view = v.copyWith(center: Offset(n!.pose!.x, n.pose!.y)))),
                      const SizedBox(width: 6),
                      _mapButton('fit', () => setState(() => view = MapView.fit(v.meta, v.size))),
                    ]),
                  ),
              ]),
            ),
          );
        }),
      );

  Widget _markerAt(MapView v, NavPose p, Key key, Widget marker, {double size = 44}) {
    final at = v.toScreen(Offset(p.x, p.y));
    return Positioned(
      key: key,
      left: at.dx - size / 2,
      top: at.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(child: Transform.rotate(angle: v.screenAngle(p.yaw), child: marker)),
    );
  }

  /// What went wrong, on top of the map: a refused command, no robot pose.
  Widget _mapBanner() {
    final n = _nav;
    final lines = <(String, Color)>[
      if (n?.rejected case final r?) ('✗ $r', bad),
      if (n != null && n.pose == null) ('no robot pose${n.poseError == null ? '' : ': ${n.poseError}'}', warn),
    ];
    return IgnorePointer(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (text, color) in lines)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.black.withOpacity(.7), borderRadius: BorderRadius.circular(6)),
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
      ]),
    );
  }

  static Widget _mapButton(String label, VoidCallback? onPressed) => SizedBox(
        height: 30,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.black.withOpacity(.6),
            side: const BorderSide(color: line),
            foregroundColor: Colors.white,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      );

  /// Why the buttons are off; null = they work. nav_relay takes commands only while the
  /// mux source is the phone.
  String? get _offReason {
    final st = widget.robot;
    if (!widget.connected) return 'No link to the robot.';
    if (st == null) return 'No robot state from the mux.';
    if (st.source != 'phone') return 'The robot takes commands from "${st.source}". Only STOP works.';
    if (_nav == null) return 'No state from nav_relay.';
    return null;
  }

  Widget _side(BuildContext context) {
    final n = _nav;
    final off = _offReason;
    final goReason = off ??
        (!n!.nav2Ready
            ? 'Nav2 is not up: NAV UP.'
            : draft == null
                ? 'Tap the map for a goal.'
                : null);
    final d = draft;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _NoPageSwipe(child: _sideButton('NAV UP', off == null ? widget.onNavUp : null, color: ok)),
      const SizedBox(height: 4),
      _NoPageSwipe(child: _sideButton('NAV STOP', off == null ? widget.onNavStop : null, color: bad)),
      const SizedBox(height: 2),
      _stagesLine(context),
      const SizedBox(height: 4),
      Expanded(
        child: _NoPageSwipe(
          child: _bigButton('GO', goReason == null ? () => widget.onGo(d!.x, d.y, d.yaw) : null, color: ok),
        ),
      ),
      const SizedBox(height: 4),
      Expanded(child: _NoPageSwipe(child: _bigButton('CANCEL', off == null ? widget.onCancel : null, color: warn))),
      const SizedBox(height: 2),
      SizedBox(
        height: 34,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (off == null)
            Text(_progress(n!),
                key: const Key('nav-progress'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _statusColor(n.status))),
          if (goReason != null && !(off == null && n?.status == 'navigating'))
            Text(goReason,
                maxLines: off == null ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFDE68A))),
        ]),
      ),
      _NoPageSwipe(child: StopButton(onStop: widget.onStop, height: 46)),
    ]);
  }

  /// "12.4 m · 40 s" while driving, else the status and its reason.
  static String _progress(NavState n) {
    if (n.status == 'navigating') {
      final dist = n.distanceRemaining, eta = n.eta;
      if (dist == null) return 'navigating${n.reason == null ? '' : ': ${n.reason}'}';
      return '${dist.toStringAsFixed(1)} m${eta == null ? '' : ' · ${eta.round()} s'}'
          '${(n.recoveries ?? 0) > 0 ? ' · ${n.recoveries} recov.' : ''}';
    }
    return '${n.status}${n.reason == null ? '' : ': ${n.reason}'}';
  }

  static Color _statusColor(String? s) =>
      {'navigating': accent, 'succeeded': ok, 'aborted': bad, 'canceled': warn}[s] ?? dim;

  static const stageIcons = {
    'ready': '✓',
    'starting': '⟳',
    'pending': '·',
    'warn': '!',
    'failed': '✗',
    'blocked': '⊘',
    'stopped': '–',
  };
  static const stageColors = {
    'ready': ok,
    'starting': accent,
    'pending': dim,
    'warn': warn,
    'failed': bad,
    'blocked': bad,
    'stopped': dim,
  };

  Widget _stagesLine(BuildContext context) {
    final n = _nav;
    final stages = n?.stages ?? const <BringupStage>[];
    return InkWell(
      key: const Key('nav-stages'),
      onTap: n == null ? null : () => _showStages(context),
      child: SizedBox(
        height: 24,
        child: Row(children: [
          const Text('stages ', style: TextStyle(color: dim, fontSize: 12)),
          if (n == null || !n.hasBringup)
            Flexible(
                child: Text(n == null ? '—' : 'no manager',
                    overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim, fontSize: 12)))
          else
            Flexible(
              child: Opacity(
                opacity: n.bringupGone ? .45 : 1,
                child: Text.rich(
                  TextSpan(children: [
                    for (final s in stages)
                      TextSpan(
                          text: stageIcons[s.state] ?? '?',
                          style: TextStyle(color: stageColors[s.state] ?? dim, fontWeight: FontWeight.w800)),
                  ]),
                  overflow: TextOverflow.clip,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 16, letterSpacing: 1),
                ),
              ),
            ),
          const Icon(Icons.chevron_right, size: 16, color: dim),
        ]),
      ),
    );
  }

  Future<void> _showStages(BuildContext context) => showDialog<void>(
        context: context,
        builder: (d) => ListenableBuilder(
          listenable: widget.updates ?? const _Never(),
          builder: (context, _) {
            final n = widget.liveNav?.call() ?? widget.nav;
            final reply = n?.bringupReply;
            return AlertDialog(
              title: Text('Nav2 bringup: ${n?.bringupOverall ?? 'no manager'}'
                  '${n != null && n.bringupGone ? ' (manager silent ${n.bringupAge!.round()} s)' : ''}'),
              content: SizedBox(
                width: 600,
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final s in n?.stages ?? const <BringupStage>[]) _stageTile(s),
                    if (reply != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                            'last ${reply['cmd']}: ${reply['success'] == true ? 'ok' : 'failed'} — ${reply['message'] ?? ''}',
                            style: TextStyle(color: reply['success'] == true ? dim : bad, fontSize: 12)),
                      ),
                  ]),
                ),
              ),
              actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
            );
          },
        ),
      );

  static Widget _stageTile(BringupStage s) {
    final color = stageColors[s.state] ?? dim;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
              width: 20,
              child: Text(stageIcons[s.state] ?? '?',
                  style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800))),
          Expanded(
              child: Text('${s.title}${s.required ? '' : ' (optional)'}',
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(s.state, style: TextStyle(color: color)),
        ]),
        if (s.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Text(s.message, style: TextStyle(color: color, fontSize: 13)),
          ),
        for (final c in s.checks)
          if (c.ok != true || s.state != 'ready')
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text(
                '${c.ok == null ? '…' : c.ok! ? '✓' : '✗'} ${c.label}: ${c.value}${c.hint.isEmpty ? '' : ' — ${c.hint}'}',
                style: TextStyle(color: c.ok == false ? bad : dim, fontSize: 12),
              ),
            ),
      ]),
    );
  }

  static Widget _sideButton(String label, VoidCallback? onPressed, {required Color color}) => SizedBox(
        height: 34,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: panel,
            side: BorderSide(color: onPressed == null ? line : color, width: 2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            foregroundColor: Colors.white,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1)),
        ),
      );

  static Widget _bigButton(String label, VoidCallback? onPressed, {required Color color}) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: onPressed == null ? panel : color.withOpacity(.22),
          side: BorderSide(color: onPressed == null ? line : color, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          foregroundColor: Colors.white,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 3)),
      );
}

class _Never implements Listenable {
  const _Never();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// Nav2's global plan as dots.
class _PlanPainter extends CustomPainter {
  _PlanPainter(this.view, this.plan);

  final MapView view;
  final List<Offset> plan;

  @override
  void paint(Canvas canvas, Size size) {
    if (plan.length < 2) return;
    final dots = Paint()..color = const Color(0xFF38BDF8);
    final pts = [for (final p in plan) view.toScreen(p)];
    // a dot every 6 px along the line, whatever the point spacing
    var carry = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i], seg = (b - a).distance;
      var t = carry;
      while (t < seg) {
        canvas.drawCircle(Offset.lerp(a, b, t / seg)!, 1.8, dots);
        t += 6;
      }
      carry = t - seg;
    }
  }

  @override
  bool shouldRepaint(_PlanPainter old) => old.view != view || old.plan != plan;
}

/// A triangle pointing right (= the robot's heading once rotated).
class _RobotMarker extends StatelessWidget {
  const _RobotMarker();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _RobotPainter());
}

class _RobotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(s.width, s.height / 2)
      ..lineTo(0, 0)
      ..lineTo(s.width * .25, s.height / 2)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(path, Paint()..color = accent);
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_RobotPainter old) => false;
}

/// ◎ with an arrow to the right (= the heading once rotated). [draft]: not sent yet.
class _GoalMarker extends StatelessWidget {
  const _GoalMarker({this.draft = false, this.active = false, this.color = ok});

  final bool draft, active;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GoalPainter(draft ? Colors.white : color, draft));
}

class _GoalPainter extends CustomPainter {
  _GoalPainter(this.color, this.draft);

  final Color color;
  final bool draft;

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero), r = s.width * .3;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(c, r, stroke);
    canvas.drawCircle(c, r * .35, Paint()..color = color);
    canvas.drawLine(c, Offset(s.width, c.dy), stroke);
    canvas.drawPath(
        Path()
          ..moveTo(s.width, c.dy)
          ..lineTo(s.width - 7, c.dy - 5)
          ..lineTo(s.width - 7, c.dy + 5)
          ..close(),
        Paint()..color = color);
    if (draft) canvas.drawCircle(c, r * 1.6, stroke..color = color.withOpacity(.35));
  }

  @override
  bool shouldRepaint(_GoalPainter old) => old.color != color || old.draft != draft;
}

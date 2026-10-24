// Rover teleop: drives the rover through app_teleop's mux when orintwo's command source
// is `phone`. Commands go out at 10 Hz only while the app is in the foreground; leaving
// it, locking the screen or losing Wi-Fi stops the stream, and the robot's deadman
// (0.5 s) stops the rover. Everything shown comes from the robot's /teleop/state.
//
// Two pages: the controls, and the camera (swipe left, or "Camera ›"), where the ZED
// image fills the screen under two transparent controls: a hold-to-drive switch on the
// left and the joystick on the right. The camera streams only while its page is showing.
//
// The whole app is landscape (manifest: sensorLandscape) and never rotates at runtime:
// switching orientation per page resized the PageView mid-swipe and bounced it back to
// the controls page.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'foxglove.dart';

const defaultHost = '10.42.0.1'; // orintwo's access point
const bridgePort = 8765;
const sendPeriod = Duration(milliseconds: 100);

const bg = Color(0xFF0F1115), panel = Color(0xFF1A1D24), line = Color(0xFF2A2F3A);
const ok = Color(0xFF22C55E), warn = Color(0xFFF59E0B), bad = Color(0xFFEF4444);
const accent = Color(0xFF3B82F6), dim = Color(0xFF8B93A5);

const wifi = MethodChannel('navws/wifi');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(MaterialApp(
    title: 'Rover Teleop',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(primary: accent, surface: panel),
    ),
    home: const TeleopPage(),
  ));
}

class TeleopPage extends StatefulWidget {
  const TeleopPage({super.key});

  @override
  State<TeleopPage> createState() => _TeleopPageState();
}

class _TeleopPageState extends State<TeleopPage> with WidgetsBindingObserver {
  static const controlsPage = 0, cameraPage = 1;

  final client = FoxgloveClient();
  final pages = PageController();
  Offset stick = Offset.zero; // x right, y up, both -1..1
  bool deadman = false; // camera page: joystick counts only while this is held
  int page = controlsPage;
  bool foreground = true;
  String host = defaultHost;
  String? pendingMode;
  Timer? sender;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    client.addListener(() => setState(() {
          if (pendingMode == client.state?.mode) pendingMode = null;
        }));
    // AP has no internet: keep sockets on Wi-Fi rather than mobile data
    wifi.invokeMethod('bindToWifi').catchError((_) {});
    SharedPreferences.getInstance().then((prefs) {
      host = prefs.getString('host') ?? defaultHost;
      client.start(_url);
      setState(() {});
    });
    sender = Timer.periodic(sendPeriod, (_) => _send());
  }

  String get _url => 'ws://$host:$bridgePort';

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sender?.cancel();
    client.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    foreground = s == AppLifecycleState.resumed;
    if (!foreground) {
      setState(() {
        stick = Offset.zero;
        deadman = false;
      });
    }
    client.watchCamera(foreground && page == cameraPage);
  }

  void _onPage(int p) {
    setState(() {
      page = p;
      stick = Offset.zero;
      deadman = false;
    });
    client.watchCamera(p == cameraPage && foreground);
  }

  void _send() {
    // in the background nothing is sent, so the robot's deadman stops the rover
    if (!foreground) return;
    final st = client.state;
    final usable = st != null && st.fresh && (page == controlsPage || deadman);
    client.drive(usable ? stick.dy * st.maxLinear : 0, usable ? -stick.dx * st.maxAngular : 0);
  }

  void _setMode(String mode) {
    HapticFeedback.selectionClick();
    setState(() => pendingMode = mode);
    client.setMode(mode);
  }

  void _stop() {
    HapticFeedback.heavyImpact();
    setState(() {
      stick = Offset.zero;
      pendingMode = 'stop';
    });
    client.setMode('stop');
  }

  Future<void> _editHost() async {
    final ctl = TextEditingController(text: host);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Robot address'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(helperText: 'orintwo access point: $defaultHost'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, defaultHost), child: const Text('Default')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Connect')),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    (await SharedPreferences.getInstance()).setString('host', result);
    setState(() => host = result);
    client
      ..stop()
      ..start(_url);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: PageView(
          controller: pages,
          onPageChanged: _onPage,
          // swipe to the camera; back only via "‹ Controls", so steering can't turn the page
          physics: page == cameraPage ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          children: [_controls(), _camera()],
        ),
      );

  RobotState? get _fresh {
    final st = client.state;
    return st != null && st.fresh ? st : null;
  }

  String get _linkText {
    if (client.link != Link.connected) return client.link == Link.connecting ? 'connecting…' : 'no link';
    return _fresh != null ? 'connected' : 'no robot state';
  }

  Color get _linkColor => client.link != Link.connected
      ? bad
      : _fresh != null
          ? ok
          : warn;

  Widget _controls() {
    final st = _fresh;
    final drivable = st != null && st.mode == 'manual' && st.source == 'phone';

    String? warning;
    if (st != null && st.source != 'phone') {
      warning = 'The robot takes commands from "${st.source}". Only STOP works from the phone.';
    } else if (st != null && st.mode != 'manual') {
      warning = 'The joystick drives only in Manual.';
    }

    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: _chip('Link', _linkText, dot: _linkColor)),
          const SizedBox(width: 8),
          Expanded(child: _chip('Robot mode', st?.mode ?? '—', color: st == null ? null : _modeColor(st.mode))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _chip('Command source', st?.source ?? '—')),
          const SizedBox(width: 8),
          Expanded(
              child: _chip(
                  'Robot hears phone',
                  st == null
                      ? '—'
                      : st.hearsPhone
                          ? 'yes (${(st.phoneAge! * 1000).round()} ms)'
                          : 'no')),
        ]),
        if (warning != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF3B2A0A),
              border: Border.all(color: warn),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(warning, style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 13)),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          for (final m in ['autonomous', 'manual', 'stop']) ...[
            if (m != 'autonomous') const SizedBox(width: 8),
            Expanded(child: _modeButton(m, active: st?.mode == m)),
          ],
        ]),
        const Spacer(),
        Listener(
          onPointerDown: (_) => _stop(), // on press, not release
          child: Container(
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bad,
              borderRadius: BorderRadius.circular(36),
              border: Border.all(color: const Color(0xFF7F1D1D), width: 4),
            ),
            child: const Text('STOP', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 3)),
          ),
        ),
        Row(children: [
          Expanded(
            child: TextButton(
              onPressed: _editHost,
              child: Text(client.url, style: const TextStyle(color: dim, fontSize: 12)),
            ),
          ),
          TextButton.icon(
            onPressed: () =>
                pages.animateToPage(cameraPage, duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
            icon: const Icon(Icons.videocam, size: 18),
            label: const Text('Camera ›'),
          ),
        ]),
      ],
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 5, child: status),
            const SizedBox(width: 16),
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Joystick(
                  enabled: drivable,
                  value: page == controlsPage ? stick : Offset.zero,
                  onChanged: (v) => setState(() => stick = v),
                  readout: st == null
                      ? ''
                      : 'v ${(stick.dy * st.maxLinear).toStringAsFixed(2)} m/s   '
                          'ω ${(-stick.dx * st.maxAngular).toStringAsFixed(2)} rad/s',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _camera() {
    final st = _fresh;
    final drivable = st != null && st.mode == 'manual' && st.source == 'phone';
    final status = [
      _linkText,
      if (st != null) st.mode.toUpperCase(),
      if (client.cameraAvailable) '${client.cameraFps.toStringAsFixed(0)} fps',
    ].join('   ·   ');
    String? hint;
    if (st != null && st.source != 'phone') {
      hint = 'Robot takes commands from "${st.source}"';
    } else if (st != null && st.mode != 'manual') {
      hint = 'Set Manual on the controls page to drive';
    }

    return ColoredBox(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        ValueListenableBuilder(
          valueListenable: client.cameraFrame,
          builder: (context, frame, _) => frame == null
              ? Center(
                  child: Text(
                    client.link != Link.connected
                        ? 'no link'
                        : client.cameraAvailable
                            ? 'waiting for camera…'
                            : 'robot has no camera relay',
                    style: const TextStyle(color: dim),
                  ),
                )
              : Image.memory(frame, fit: BoxFit.contain, gaplessPlayback: true),
        ),
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Row(children: [
            TextButton(
              onPressed: () =>
                  pages.animateToPage(controlsPage, duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
              child: const Text('‹ Controls', style: _overlayText),
            ),
            const SizedBox(width: 8),
            Icon(Icons.circle, size: 10, color: _linkColor),
            const SizedBox(width: 6),
            Text(status, style: _overlayText),
            const Spacer(),
            if (hint != null) Text(hint, style: _overlayText.copyWith(color: const Color(0xFFFDE68A))),
          ]),
        ),
        Positioned(
          left: 32,
          bottom: 32,
          child: DeadmanSwitch(
            held: deadman,
            enabled: drivable,
            onChanged: (held) {
              if (held) HapticFeedback.mediumImpact();
              setState(() => deadman = held);
            },
          ),
        ),
        Positioned(
          right: 32,
          bottom: 32,
          width: 200,
          height: 200,
          child: Joystick(
            overlay: true,
            enabled: drivable && deadman,
            value: page == cameraPage ? stick : Offset.zero,
            onChanged: (v) => setState(() => stick = v),
            readout: '',
          ),
        ),
      ]),
    );
  }

  static const _overlayText = TextStyle(
    color: Colors.white,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
  );

  Color _modeColor(String mode) => {'stop': bad, 'manual': accent, 'autonomous': ok}[mode] ?? Colors.white;

  Widget _chip(String label, String value, {Color? dot, Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: const TextStyle(color: dim, fontSize: 11, letterSpacing: .5)),
          const SizedBox(height: 2),
          Row(children: [
            if (dot != null) ...[
              Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color)),
            ),
          ]),
        ]),
      );

  Widget _modeButton(String mode, {required bool active}) {
    final isStop = mode == 'stop';
    return OutlinedButton(
      onPressed: () => isStop ? _stop() : _setMode(mode),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: active ? (isStop ? const Color(0xFF7F1D1D) : const Color(0xFF1E3A8A)) : panel,
        side: BorderSide(
          color: active ? (isStop ? bad : accent) : (pendingMode == mode ? dim : line),
          width: 2,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        foregroundColor: Colors.white,
      ),
      child: Text(mode[0].toUpperCase() + mode.substring(1), style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

/// Swallows horizontal drags that start on a control, so the PageView doesn't turn the
/// page while someone is steering. Raw pointer events still reach the Listener inside.
class _NoPageSwipe extends StatelessWidget {
  const _NoPageSwipe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onHorizontalDragStart: (_) {}, behavior: HitTestBehavior.opaque, child: child);
}

/// Camera page, left thumb: the joystick drives only while this is held.
class DeadmanSwitch extends StatelessWidget {
  const DeadmanSwitch({super.key, required this.held, required this.enabled, required this.onChanged});

  final bool held;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _NoPageSwipe(
        child: Listener(
          onPointerDown: (_) => onChanged(true),
          onPointerUp: (_) => onChanged(false),
          onPointerCancel: (_) => onChanged(false),
          child: Container(
            width: 150,
            height: 150,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: held ? ok.withOpacity(.45) : Colors.white.withOpacity(.12),
              border: Border.all(color: held ? ok : Colors.white.withOpacity(.4), width: 2),
            ),
            child: Text(
              held ? 'DRIVING' : 'HOLD\nto drive',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(enabled ? .95 : .5),
                fontWeight: FontWeight.w700,
                shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
              ),
            ),
          ),
        ),
      );
}

/// Spring-back joystick. Reports x (right) and y (up) in -1..1; releasing returns 0.
/// `overlay`: transparent, for drawing on top of the camera image.
class Joystick extends StatefulWidget {
  const Joystick(
      {super.key,
      required this.enabled,
      required this.value,
      required this.onChanged,
      required this.readout,
      this.overlay = false});

  final bool enabled;
  final Offset value;
  final ValueChanged<Offset> onChanged;
  final String readout;
  final bool overlay;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  int? pointer;

  double _radius(Size size) => min(size.width, size.height) * (widget.overlay ? 0.42 : 0.35);

  void _update(Offset local, Size size) {
    final radius = _radius(size);
    var d = local - size.center(Offset.zero);
    if (d.distance > radius) d = d / d.distance * radius;
    widget.onChanged(Offset(d.dx / radius, -d.dy / radius));
  }

  void _release() {
    pointer = null;
    widget.onChanged(Offset.zero);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Opacity(
          opacity: widget.enabled ? 1 : (widget.overlay ? .6 : .35),
          child: _NoPageSwipe(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                if (pointer != null) return;
                pointer = e.pointer;
                _update(e.localPosition, size);
              },
              onPointerMove: (e) {
                if (e.pointer == pointer) _update(e.localPosition, size);
              },
              onPointerUp: (e) {
                if (e.pointer == pointer) _release();
              },
              onPointerCancel: (e) {
                if (e.pointer == pointer) _release();
              },
              child: CustomPaint(
                size: size,
                painter: _JoystickPainter(widget.value, _radius(size), widget.overlay),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(widget.readout,
                        style: const TextStyle(color: dim, fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                ),
              ),
            ),
          ),
        );
      });
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter(this.value, this.radius, this.overlay);

  final Offset value;
  final double radius;
  final bool overlay;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    if (overlay) {
      canvas.drawCircle(center, radius, Paint()..color = Colors.white.withOpacity(.10));
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = Colors.white.withOpacity(.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    } else {
      final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18));
      canvas.drawRRect(r, Paint()..color = panel);
      canvas.drawRRect(
          r,
          Paint()
            ..color = line
            ..style = PaintingStyle.stroke);
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    final knob = center + Offset(value.dx, -value.dy) * radius;
    canvas.drawCircle(knob, overlay ? 32 : 36, Paint()..color = accent.withOpacity(overlay ? .6 : 1));
  }

  @override
  bool shouldRepaint(_JoystickPainter old) => old.value != value || old.radius != radius;
}

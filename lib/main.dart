// Rover teleop: drives the rover through app_teleop's mux when orintwo's command source
// is `phone`. Commands go out at 10 Hz only while the app is in the foreground; leaving
// it, locking the screen or losing Wi-Fi stops the stream, and the robot's deadman
// (0.5 s) stops the rover. Everything shown comes from the robot's /teleop/state.
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
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
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
  final client = FoxgloveClient();
  Offset stick = Offset.zero; // x right, y up, both -1..1
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
    if (!foreground) setState(() => stick = Offset.zero);
  }

  void _send() {
    // in the background nothing is sent, so the robot's deadman stops the rover
    if (!foreground) return;
    final st = client.state;
    final usable = st != null && st.fresh;
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
  Widget build(BuildContext context) {
    final st = client.state;
    final fresh = st != null && st.fresh;
    final connected = client.link == Link.connected;
    final linkText = !connected
        ? (client.link == Link.connecting ? 'connecting…' : 'no link')
        : fresh ? 'connected' : 'no robot state';
    final linkColor = !connected ? bad : fresh ? ok : warn;
    final drivable = fresh && st.mode == 'manual' && st.source == 'phone';

    String? warning;
    if (fresh && st.source != 'phone') {
      warning = 'The robot takes commands from "${st.source}". Only STOP works from the phone.';
    } else if (fresh && st.mode != 'manual') {
      warning = 'The joystick drives only in Manual.';
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(child: _chip('Link', linkText, dot: linkColor)),
                const SizedBox(width: 8),
                Expanded(child: _chip('Robot mode', fresh ? st.mode : '—', color: fresh ? _modeColor(st.mode) : null)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _chip('Command source', fresh ? st.source : '—')),
                const SizedBox(width: 8),
                Expanded(child: _chip('Robot hears phone',
                    !fresh ? '—' : st.hearsPhone ? 'yes (${(st.phoneAge! * 1000).round()} ms)' : 'no')),
              ]),
              if (warning != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B2A0A),
                    border: Border.all(color: warn),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(warning, style: const TextStyle(color: Color(0xFFFDE68A))),
                ),
              ],
              const SizedBox(height: 12),
              Row(children: [
                for (final m in ['autonomous', 'manual', 'stop']) ...[
                  if (m != 'autonomous') const SizedBox(width: 8),
                  Expanded(child: _modeButton(m, active: fresh && st.mode == m)),
                ],
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: Joystick(
                  enabled: drivable,
                  value: stick,
                  onChanged: (v) => setState(() => stick = v),
                  readout: fresh
                      ? 'v ${(stick.dy * st.maxLinear).toStringAsFixed(2)} m/s   '
                        'ω ${(-stick.dx * st.maxAngular).toStringAsFixed(2)} rad/s'
                      : '',
                ),
              ),
              const SizedBox(height: 12),
              Listener(
                onPointerDown: (_) => _stop(), // on press, not release
                child: Container(
                  height: 84,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bad,
                    borderRadius: BorderRadius.circular(42),
                    border: Border.all(color: const Color(0xFF7F1D1D), width: 4),
                  ),
                  child: const Text('STOP',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 3)),
                ),
              ),
              TextButton(
                onPressed: _editHost,
                child: Text(client.url, style: const TextStyle(color: dim, fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _modeColor(String mode) =>
      {'stop': bad, 'manual': accent, 'autonomous': ok}[mode] ?? Colors.white;

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
      child: Text(mode[0].toUpperCase() + mode.substring(1),
          style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

/// Spring-back joystick. Reports x (right) and y (up) in -1..1; releasing returns 0.
class Joystick extends StatefulWidget {
  const Joystick({super.key, required this.enabled, required this.value,
      required this.onChanged, required this.readout});

  final bool enabled;
  final Offset value;
  final ValueChanged<Offset> onChanged;
  final String readout;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  int? pointer;

  void _update(Offset local, Size size) {
    final radius = min(size.width, size.height) * 0.35;
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
          opacity: widget.enabled ? 1 : .35,
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
              painter: _JoystickPainter(widget.value),
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
        );
      });
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter(this.value);

  final Offset value;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18));
    canvas.drawRRect(r, Paint()..color = panel);
    canvas.drawRRect(r, Paint()
      ..color = line
      ..style = PaintingStyle.stroke);
    final center = size.center(Offset.zero);
    final radius = min(size.width, size.height) * 0.35;
    canvas.drawCircle(center, radius, Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    final knob = center + Offset(value.dx, -value.dy) * radius;
    canvas.drawCircle(knob, 36, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_JoystickPainter old) => old.value != value;
}

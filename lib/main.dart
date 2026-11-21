// Rover teleop: drives the rover through app_teleop's mux when orintwo's command source
// is `phone`. Commands go out at 10 Hz only while the app is in the foreground; leaving
// it, locking the screen or losing Wi-Fi stops the stream, and the robot's deadman
// (0.5 s) stops the rover. Everything shown comes from the robot's /teleop/state.
//
// Four columns, [system, wheels, controls, camera], opening on the controls. Swipe right
// (or "‹ Wheels") for the wheels page:
// arms the rover and switches robot_control's modes through orintwo (/teleop/phone/rover_cmd)
// and shows the modes orintwo tracks (/teleop/rover_state). Swipe left (or "Camera ›") for
// the camera, where the ZED image fills the screen under two transparent controls: a
// hold-to-drive switch on the left and the joystick on the right. The camera streams only
// while its page is showing. Swipe right from the wheels page (or "‹ System") for the
// system page: brings the robots up, stops them, recenters the wheels over ssh to orintwo
// (phone_ctl.sh, navigation_ws #27; system_page.dart, phone_ctl.dart).
//
// The wheels column is a vertical PageView, [autonav, wheels, record]: swipe down from the
// wheels page (or "⌃ Autonav") for the Autonav page, the map with Nav2 goals through
// orintwo's nav_relay (navigation_ws #30; autonav_page.dart, nav.dart). Its map takes
// one-finger taps and drags, so the Autonav page doesn't turn: back only via "⌄ Wheels".
// Swipe up from the wheels page (or "⌄ Record") for the Record page: bags on orintwo
// through phone_ctl.sh record over the System page's ssh (navigation_ws #29;
// record_page.dart, record.dart). Its big STOP stops the recording; the mux STOP is the
// small "MUX STOP" in its header. Back via a swipe down or "⌃ Wheels".
//
// Driving (navigation_ws #37): to a mux with gears (/teleop/state has `gears`) the app sends
// the normalized joystick on /teleop/phone/stick and the robot does the rest (gear speed,
// ramp, speed-dependent steering limit); the camera page shifts with ▲ / ▼ above the
// joystick (/teleop/phone/gear) and shows km/h above the deadman. The app has no cmd_vel
// path: to an older mux (no `gear` in /teleop/state) it sends nothing, the joysticks are off
// and a warning says to update orintwo.
//
// Landscape only (manifest: sensorLandscape); the orientation never changes at runtime.
import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'foxglove.dart';
import 'nav.dart';
import 'phone_ctl.dart';
import 'record.dart';

part 'autonav_page.dart';
part 'record_page.dart';
part 'system_page.dart';

/// /teleop/state without `gear`: a mux from before navigation_ws #37, which the app can't drive.
const oldMuxWarning = 'orintwo runs an old mux without gears — update orintwo (sync + restart app_teleop)';

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
  const TeleopPage({super.key, this.phoneCtl, this.client});

  /// The ssh layer for the system page; null = ssh to orintwo (tests pass a fake).
  final PhoneCtl? phoneCtl;

  /// The bridge client; null = a real one (tests pass a fake).
  final FoxgloveClient? client;

  @override
  State<TeleopPage> createState() => _TeleopPageState();
}

class _TeleopPageState extends State<TeleopPage> with WidgetsBindingObserver {
  // left to right; the index is the PageView page. wheelsPage is the wheels column.
  static const systemPage = 0, wheelsPage = 1, controlsPage = 2, cameraPage = 3;

  // the wheels column, top to bottom
  static const autonavRow = 0, wheelsRow = 1, recordRow = 2;

  late final client = widget.client ?? FoxgloveClient();
  // one ssh layer (key, host order, host-key pin) for the system and record pages
  late final PhoneCtl phoneCtl = widget.phoneCtl ?? SshPhoneCtl(hosts: _sshHosts);
  late final system = SystemController(phoneCtl);
  late final record = RecordController(phoneCtl);
  String sshHost = ''; // typed on the system page; tried after orintwo.local
  final pages = PageController(initialPage: controlsPage);
  final rows = PageController(initialPage: wheelsRow);
  int row = wheelsRow;
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
    client.addListener(_onClient);
    // AP has no internet: keep sockets on Wi-Fi rather than mobile data
    wifi.invokeMethod('bindToWifi').catchError((_) {});
    SharedPreferences.getInstance().then((prefs) {
      host = prefs.getString('host') ?? defaultHost;
      sshHost = prefs.getString('ssh_host') ?? '';
      client.start(_url);
      setState(() {});
    });
    sender = Timer.periodic(sendPeriod, (_) => _send());
  }

  String get _url => 'ws://$host:$bridgePort';

  /// orintwo.local, then a typed address, then the WebSocket's host.
  List<String> _sshHosts() => {sshDefaultHost, if (sshHost.isNotEmpty) sshHost, host}.toList();

  void _onClient() => setState(() {
        if (pendingMode == client.state?.mode) pendingMode = null;
      });

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sender?.cancel();
    system.dispose();
    record.dispose();
    pages.dispose();
    rows.dispose();
    client
      ..removeListener(_onClient) // stop() notifies; this State is already going away
      ..stop();
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
    _watch();
  }

  bool get _onAutonav => page == wheelsPage && row == autonavRow;

  /// Camera and Autonav topics, and `record status`, only while their page shows.
  void _watch() {
    client.watchCamera(foreground && page == cameraPage);
    client.watchNav(foreground && _onAutonav);
    record.setVisible(foreground && page == wheelsPage && row == recordRow);
  }

  void _onPage(int p) {
    setState(() {
      page = p;
      stick = Offset.zero;
      deadman = false;
    });
    _watch();
  }

  void _onRow(int r) {
    setState(() => row = r);
    _watch();
  }

  void _send() {
    // in the background nothing is sent, so the robot's deadman stops the rover
    if (!foreground) return;
    final st = client.state;
    final usable = st != null && st.fresh && (page == controlsPage || deadman);
    // a mux without gears (before navigation_ws #37) gets nothing: the app has no cmd_vel path
    if (st != null && !st.hasGears) return;
    // stick.dx + = right; steer + = left. The mux scales it (gear speed, ramp, lateral limit).
    client.stick(usable ? stick.dy : 0.0, usable ? -stick.dx : 0.0);
  }

  /// ▲ / ▼ on the camera page. The gear shown is the robot's, from /teleop/state.
  void _shift(String dir) {
    HapticFeedback.selectionClick();
    client.shift(dir);
  }

  void _setMode(String mode) {
    HapticFeedback.selectionClick();
    setState(() => pendingMode = mode);
    client.setMode(mode);
  }

  void _roverCmd(String cmd) {
    HapticFeedback.selectionClick();
    client.roverCmd(cmd);
  }

  /// HOLD TO ARM: the mux to manual first, so the rover gets the phone's (zero) commands
  /// on /cmd_vel once robot_control switches to it; then the arm sequence. The delay lets
  /// setMode's three repeats (0/80/160 ms) go out before arm.
  void _arm() {
    _setMode('manual');
    Future.delayed(const Duration(milliseconds: 300), () => client.roverCmd('arm'));
  }

  void _goTo(int p) => pages.animateToPage(p, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  void _goToRow(int r) => rows.animateToPage(r, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  /// GO: the mux to autonomous first (otherwise teleop_mux never passes Nav2's
  /// /cmd_vel_auto on), then the goal once setMode's three repeats (0/80/160 ms) are out.
  void _navGo(double x, double y, double yaw) {
    HapticFeedback.mediumImpact();
    setState(() => pendingMode = 'autonomous');
    client.setMode('autonomous');
    Future.delayed(const Duration(milliseconds: 300), () => client.navGoal(x, y, yaw));
  }

  /// CANCEL: cancel the goal, then the mux to stop.
  void _navCancel() {
    client.navCmd({'cmd': 'cancel'});
    _stop();
  }

  void _navCmd(String cmd) {
    HapticFeedback.selectionClick();
    client.navCmd({'cmd': cmd});
  }

  void _stop() {
    HapticFeedback.heavyImpact();
    setState(() {
      stick = Offset.zero;
      pendingMode = 'stop';
    });
    client.setMode('stop');
  }

  Future<void> _editSshHost() async {
    final ctl = TextEditingController(text: sshHost);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('orintwo ssh address'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
              hintText: 'e.g. 10.144.2.17',
              helperText: 'tried after $sshDefaultHost, before the robot address ($host); empty: none'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    (await SharedPreferences.getInstance()).setString('ssh_host', result);
    setState(() => sshHost = result);
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
          // swipe to the camera; back only via "‹ Controls", so steering can't turn the page.
          // Same for Autonav (the map's gestures): back only via "⌄ Wheels".
          physics: page == cameraPage || _onAutonav ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          children: [
            SystemPage(ctl: system, onWheels: () => _goTo(wheelsPage), onEditHost: _editSshHost),
            PageView(
              controller: rows,
              scrollDirection: Axis.vertical,
              onPageChanged: _onRow,
              physics: row == autonavRow ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
              children: [_autonav(), _wheels(), _record()],
            ),
            _controls(),
            _camera(),
          ],
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
    final drivable = st != null && st.hasGears && st.mode == 'manual' && st.source == 'phone';

    String? warning;
    if (st != null && !st.hasGears) {
      warning = oldMuxWarning;
    } else if (st != null && st.source != 'phone') {
      warning = 'The robot takes commands from "${st.source}". Only STOP works from the phone.';
    } else if (st != null && st.mode != 'manual') {
      warning = 'The joystick drives only in Manual.';
    }

    // the part above STOP scrolls when a long warning wraps on a small phone, so STOP and
    // the page links always stay on screen
    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
            child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(flex: 4, child: _chip('Link', _linkText, dot: _linkColor)),
            const SizedBox(width: 8),
            Expanded(
                flex: 4, child: _chip('Robot mode', st?.mode ?? '—', color: st == null ? null : _modeColor(st.mode))),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: _gearChip(st)),
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
          const SizedBox(height: 8),
        ]))),
        StopButton(onStop: _stop),
        Row(children: [
          TextButton(
            onPressed: () => _goTo(wheelsPage),
            child: const Text('‹ Wheels'),
          ),
          Expanded(
            child: TextButton(
              onPressed: _editHost,
              child: Text(client.url,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim, fontSize: 12)),
            ),
          ),
          TextButton.icon(
            onPressed: () => _goTo(cameraPage),
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
                      : 'throttle ${stick.dy.toStringAsFixed(2)}   steer ${(-stick.dx).toStringAsFixed(2)}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wheels() => WheelsPage(
        connected: client.link == Link.connected,
        linkText: _linkText,
        linkColor: _linkColor,
        robot: _fresh,
        rover: client.roverState,
        onCommand: _roverCmd,
        onArm: _arm,
        onStop: _stop,
        onControls: () => _goTo(controlsPage),
        onSystem: () => _goTo(systemPage),
        onAutonav: () => _goToRow(autonavRow),
        onRecord: () => _goToRow(recordRow),
      );

  Widget _record() => RecordPage(ctl: record, onStop: _stop, onWheels: () => _goToRow(wheelsRow));

  Widget _autonav() => AutonavPage(
        connected: client.link == Link.connected,
        linkText: _linkText,
        linkColor: _linkColor,
        robot: _fresh,
        nav: client.navState,
        map: client.navMap,
        onGo: _navGo,
        onCancel: _navCancel,
        onNavUp: () => _navCmd('bringup_go'),
        onNavStop: () => _navCmd('bringup_stop'),
        onStop: _stop,
        onWheels: () => _goToRow(wheelsRow),
        updates: client,
        liveNav: () => client.navState,
      );

  Widget _camera() {
    final st = _fresh;
    final drivable = st != null && st.hasGears && st.mode == 'manual' && st.source == 'phone';
    final status = [
      _linkText,
      if (st != null) st.mode.toUpperCase(),
      if (client.cameraAvailable) '${client.cameraFps.toStringAsFixed(0)} fps',
    ].join('   ·   ');
    String? hint;
    if (st != null && !st.hasGears) {
      hint = oldMuxWarning;
    } else if (st != null && st.source != 'phone') {
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
              onPressed: () => _goTo(controlsPage),
              child: const Text('‹ Controls', style: _overlayText),
            ),
            const SizedBox(width: 8),
            Icon(Icons.circle, size: 10, color: _linkColor),
            const SizedBox(width: 6),
            Text(status, style: _overlayText),
            const SizedBox(width: 12),
            const Spacer(),
            if (hint != null)
              Flexible(
                flex: 8,
                child: Text(hint,
                    maxLines: 2,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: _overlayText.copyWith(color: const Color(0xFFFDE68A))),
              ),
          ]),
        ),
        // km/h above the deadman, gears above the joystick (navigation_ws #37)
        Positioned(left: 32, bottom: 32 + 150 + 6, child: SpeedReadout(robot: st)),
        Positioned(
          right: 32,
          bottom: 32 + 200 + 6,
          width: 200,
          child: GearControl(robot: st, enabled: st != null && st.source == 'phone', onShift: _shift),
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

/// Controls page, compact: "2 · 1.1" (gear · km/h); "cmd" and dimmed when the speed is
/// the commanded one; "none" for a mux without gears.
Widget _gearChip(RobotState? st) {
  final v = st?.speed;
  final gear = st == null ? '—' : (st.hasGears ? '${st.gear}' : 'none');
  final speed = v == null ? '—' : '${kmh(v.mps)}${v.measured ? '' : ' cmd'}';
  return _chip('Gear · km/h', '$gear · $speed', color: v != null && !v.measured ? dim : null);
}

/// m/s → km/h, one decimal, never "-0.0".
String kmh(double mps) {
  final s = (mps * 3.6).toStringAsFixed(1);
  return s == '-0.0' ? '0.0' : s;
}

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

/// Swallows drags that start on a control, so neither PageView (pages left/right, the
/// wheels column up/down) turns while someone is steering or pressing. Raw pointer events still reach the Listener inside.
class _NoPageSwipe extends StatelessWidget {
  const _NoPageSwipe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
      onHorizontalDragStart: (_) {}, onVerticalDragStart: (_) {}, behavior: HitTestBehavior.opaque, child: child);
}

const _shadow = [Shadow(blurRadius: 4, color: Colors.black)];

/// Camera page, above the deadman: the speed in km/h, big. Measured (/odom_wheels) when
/// the mux has it; else the commanded speed, dimmed, with a "cmd" tag.
class SpeedReadout extends StatelessWidget {
  const SpeedReadout({super.key, required this.robot});

  final RobotState? robot;

  @override
  Widget build(BuildContext context) {
    final v = robot?.speed;
    final measured = v?.measured ?? true;
    final color = Colors.white.withOpacity(v == null || !measured ? .55 : .95);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(v == null ? '—' : kmh(v.mps),
            key: const Key('speed-kmh'),
            style: TextStyle(
                color: color,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
                shadows: _shadow)),
        const SizedBox(width: 4),
        Text('km/h', style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600, shadows: _shadow)),
        if (v != null && !measured) ...[
          const SizedBox(width: 6),
          Container(
            key: const Key('speed-cmd'),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(.4),
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('cmd', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ],
      ],
    );
  }
}

/// Camera page, above the joystick: ▼ [ gear ] ▲ and under it the gear's top speed in
/// km/h (capped by max_linear) and "steering limited" while the mux narrows the steering.
/// The gear shown is the robot's (/teleop/state). A mux without gears: a note only.
class GearControl extends StatelessWidget {
  const GearControl({super.key, required this.robot, required this.enabled, required this.onShift});

  final RobotState? robot;

  /// The mux takes gear changes only from its active source.
  final bool enabled;
  final ValueChanged<String> onShift;

  static const _note = TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, shadows: _shadow);

  @override
  Widget build(BuildContext context) {
    final st = robot;
    if (st == null) return const SizedBox.shrink();
    if (!st.hasGears) {
      return Text('robot has no gears', textAlign: TextAlign.center, style: _note.copyWith(color: warn));
    }
    final gear = st.gear!, top = st.gearSpeed;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _button('▼', const Key('gear-down'), enabled && gear > 1 ? () => onShift('down') : null),
        Container(
          width: 56,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(.35),
            border: Border.all(color: Colors.white.withOpacity(.6), width: 2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('$gear',
              key: const Key('gear-value'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, shadows: _shadow)),
        ),
        _button('▲', const Key('gear-up'), enabled && gear < st.gears.length ? () => onShift('up') : null),
      ]),
      const SizedBox(height: 2),
      Text.rich(
        TextSpan(children: [
          TextSpan(text: top == null ? '' : '≤ ${kmh(top)} km/h'),
          if (st.steerLimited)
            const TextSpan(text: '  ·  steering limited', style: TextStyle(color: Color(0xFFFDE68A))),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _note,
      ),
    ]);
  }

  static Widget _button(String label, Key key, VoidCallback? onPressed) => _NoPageSwipe(
        child: SizedBox(
          width: 52,
          height: 40,
          child: OutlinedButton(
            key: key,
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: Colors.white.withOpacity(.12),
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white.withOpacity(.3),
              side: BorderSide(color: Colors.white.withOpacity(onPressed == null ? .2 : .5), width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(label, style: const TextStyle(fontSize: 18)),
          ),
        ),
      );
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

/// The mux STOP (set_mode stop), shared by the controls, wheels and autonav pages (small,
/// as "MUX STOP", in the record page's header). Fires on press, not release.
class StopButton extends StatelessWidget {
  const StopButton({super.key, required this.onStop, this.height = 72, this.label = 'STOP', this.fontSize = 26});

  final VoidCallback onStop;
  final double height;
  final String label;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => onStop(),
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bad,
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(color: const Color(0xFF7F1D1D), width: height < 40 ? 2 : 4),
          ),
          child: Text(label,
              maxLines: 1,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, letterSpacing: fontSize < 20 ? 1 : 3)),
        ),
      );
}

/// Wheels page (swipe right from the controls, left from the system page): robot_control's modes as orintwo tracks
/// them (/teleop/rover_state) and the mux state on the left, buttons that send
/// /teleop/phone/rover_cmd on the right. orintwo accepts rover_cmd only while the mux's
/// source is `phone`, so the buttons are off otherwise; STOP always works.
class WheelsPage extends StatelessWidget {
  const WheelsPage({
    super.key,
    required this.connected,
    required this.linkText,
    required this.linkColor,
    required this.robot,
    required this.rover,
    required this.onCommand,
    required this.onArm,
    required this.onStop,
    this.onControls,
    this.onSystem,
    this.onAutonav,
    this.onRecord,
  });

  final bool connected;
  final String linkText;
  final Color linkColor;

  /// /teleop/state, null when stale.
  final RobotState? robot;

  /// /teleop/rover_state, possibly stale (checked here).
  final RoverState? rover;
  final ValueChanged<String> onCommand;
  final VoidCallback onArm;
  final VoidCallback onStop;
  final VoidCallback? onControls;
  final VoidCallback? onSystem;
  final VoidCallback? onAutonav;
  final VoidCallback? onRecord;

  static const _gap = SizedBox(height: 6);

  @override
  Widget build(BuildContext context) {
    final rs = rover != null && rover!.fresh ? rover : null;
    final st = robot;

    String? reason;
    if (!connected) {
      reason = 'No link to the robot.';
    } else if (st == null) {
      reason = 'No robot state from the mux.';
    } else if (st.source != 'phone') {
      reason = 'The robot takes commands from "${st.source}". Only STOP works.';
    }
    final enabled = reason == null;
    void Function()? send(String cmd) => enabled ? () => onCommand(cmd) : null;

    final compact = TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8));
    final header = Row(children: [
      if (onSystem != null) TextButton(onPressed: onSystem, style: compact, child: const Text('‹ System')),
      const Text('WHEELS', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 2)),
      const SizedBox(width: 12),
      // link text and banner give way on a narrow phone
      Expanded(
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: linkColor, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(child: Text(linkText, overflow: TextOverflow.ellipsis, style: const TextStyle(color: dim))),
          const SizedBox(width: 12),
          if (rs != null && rs.tracked)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B2A0A),
                    border: Border.all(color: warn),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('⚠ GUESSED STATE',
                      style: TextStyle(color: warn, fontWeight: FontWeight.w700, letterSpacing: .5)),
                ),
              ),
            ),
        ]),
      ),
      if (onAutonav != null) TextButton(onPressed: onAutonav, style: compact, child: const Text('⌃ Autonav')),
      if (onControls != null) TextButton(onPressed: onControls, style: compact, child: const Text('Controls ›')),
    ]);

    final age = rs?.lastCmdAge;
    final status = Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: panel,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('ROBOT_CONTROL', rs == null ? 'no state' : null),
        // robot_control's "autonomous" input means /cmd_vel, i.e. whatever the mux outputs
        // (the phone joystick in mux manual). Not the mux's autonomous (= Nav2) mode.
        _row('Input', {'autonomous': '/cmd_vel (mux)', 'manual': 'manual 5 %'}[rs?.input] ?? rs?.input,
            color: rs?.input == 'autonomous' ? ok : null),
        _row('Steering', rs?.steering?.toUpperCase()),
        // robot_control's own stop: only after it (re)starts, left by ARM. The red STOP is the
        // mux's and shows in the MUX section.
        _row('Motion', {'running': 'RUNNING', 'stopped': 'HELD (until ARM)'}[rs?.motion] ?? rs?.motion,
            color: {'running': ok, 'stopped': bad}[rs?.motion]),
        _row('Last', rs?.lastCmd == null ? null : '${rs!.lastCmd}${age == null ? '' : ' · ${age.round()} s'}'),
        if (rs?.rejected != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Rejected: ${rs!.rejected}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: bad, fontSize: 13)),
          ),
        const Divider(color: line, height: 14),
        _title('MUX', st == null ? 'no state' : null),
        _row('Mode', st == null ? null : '${st.mode.toUpperCase()} · ${st.source}',
            color: st == null ? null : _modeColor(st.mode)),
        _row(
            'Output',
            st == null
                ? null
                : 'vx ${(st.outVx ?? 0).toStringAsFixed(2)}  wz ${(st.outWz ?? 0).toStringAsFixed(2)}'
                    '  max ${st.maxAngular.toStringAsFixed(1)}'),
      ]),
    );

    final buttons = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: _NoPageSwipe(child: _button('Input → /cmd_vel', send('input_auto')))),
      _gap,
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _NoPageSwipe(child: _button('Crab', send('steer_crab'), active: rs?.steering == 'crab'))),
          const SizedBox(width: 6),
          Expanded(
              child: _NoPageSwipe(
                  child: _button('Ackermann', send('steer_ackermann'), active: rs?.steering == 'ackermann'))),
        ]),
      ),
      _gap,
      Expanded(child: _NoPageSwipe(child: HoldToArm(enabled: enabled, onArmed: onArm))),
      _gap,
      Align(
        alignment: Alignment.centerLeft,
        child: _NoPageSwipe(
          child: SizedBox(
            height: 32,
            child: OutlinedButton(
              onPressed: enabled ? () => _confirmReset(context) : null,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: line),
                foregroundColor: dim,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('robot_control restarted'),
            ),
          ),
        ),
      ),
      if (reason != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 13)),
        ),
      const SizedBox(height: 8),
      _NoPageSwipe(child: StopButton(onStop: onStop, height: 60)),
    ]);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 40, child: header),
          const SizedBox(height: 4),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // "⌄ Record" at the bottom edge, where Record is (no room left in the header)
              Expanded(
                flex: 5,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: SingleChildScrollView(child: status)),
                  if (onRecord != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        height: 32,
                        child: TextButton(onPressed: onRecord, style: compact, child: const Text('⌄ Record')),
                      ),
                    ),
                ]),
              ),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: buttons),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('robot_control restarted?'),
        content: const Text('Reset sets the tracked state back to boot defaults (manual / crab / stopped). '
            'It sends nothing to the rover.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes, reset guess')),
        ],
      ),
    );
    if (yes == true) onCommand('reset');
  }

  static Widget _title(String text, String? note) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Text(text, style: const TextStyle(color: dim, fontSize: 11, letterSpacing: .5)),
          if (note != null) ...[
            const SizedBox(width: 8),
            Text(note, style: const TextStyle(color: warn, fontSize: 11)),
          ],
        ]),
      );

  static Widget _row(String label, String? value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          SizedBox(width: 76, child: Text(label, style: const TextStyle(color: dim, fontSize: 14))),
          Expanded(
            child: Text(value ?? '—',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: value == null ? null : color)),
          ),
        ]),
      );

  /// Same look as the controls page's mode buttons; `active` lights it like the robot's mode.
  static Widget _button(String label, VoidCallback? onPressed, {bool active = false}) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? const Color(0xFF1E3A8A) : panel,
          side: BorderSide(color: active ? accent : line, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          foregroundColor: Colors.white,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}

/// Fires `onArmed` once the finger has stayed down for `hold` (fill animation meanwhile);
/// letting go earlier cancels, so a tap can't arm.
class HoldToArm extends StatefulWidget {
  const HoldToArm({super.key, required this.enabled, required this.onArmed, this.hold = const Duration(seconds: 1)});

  final bool enabled;
  final VoidCallback onArmed;
  final Duration hold;

  @override
  State<HoldToArm> createState() => _HoldToArmState();
}

class _HoldToArmState extends State<HoldToArm> with SingleTickerProviderStateMixin {
  late final AnimationController fill = AnimationController(vsync: this, duration: widget.hold)
    ..addStatusListener(_onStatus);
  int? pointer;
  bool fired = false;

  void _onStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || pointer == null || fired) return;
    setState(() => fired = true);
    HapticFeedback.heavyImpact();
    widget.onArmed();
  }

  void _release() {
    pointer = null;
    fill.stop();
    fill.value = 0;
    setState(() => fired = false);
  }

  @override
  void didUpdateWidget(HoldToArm old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && pointer != null) _release();
  }

  @override
  void dispose() {
    fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (!widget.enabled || pointer != null) return;
          pointer = e.pointer;
          fired = false;
          fill.forward(from: 0);
        },
        onPointerUp: (e) {
          if (e.pointer == pointer) _release();
        },
        onPointerCancel: (e) {
          if (e.pointer == pointer) _release();
        },
        child: AnimatedBuilder(
          animation: fill,
          builder: (context, _) => Opacity(
            opacity: widget.enabled ? 1 : .38,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: panel,
                border: Border.all(color: fired ? ok : (pointer != null ? accent : line), width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(fit: StackFit.expand, children: [
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fill.value,
                  child: ColoredBox(color: fired ? ok.withOpacity(.6) : accent.withOpacity(.6)),
                ),
                Center(
                  child: Text(fired ? 'ARM SENT' : 'HOLD TO ARM',
                      style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                ),
              ]),
            ),
          ),
        ),
      );
}

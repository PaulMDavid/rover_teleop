import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rover_teleop/foxglove.dart';
import 'package:rover_teleop/main.dart';
import 'package:rover_teleop/nav.dart';
import 'package:shared_preferences/shared_preferences.dart';

RobotState mux({String source = 'phone', String mode = 'manual'}) => RobotState({
      'mode': mode,
      'mode_by': 'phone',
      'source': source,
      'teleop_age': {'phone': 0.05, 'ground': null},
      'teleop_timeout': 0.5,
      'max_linear': 0.5,
      'max_angular': 1.0,
      'out': {'vx': 0.0, 'vy': 0.0, 'wz': 0.0},
    });

/// 200 × 100 px at 0.1 m, origin (−5, −3): x −5..15, y −3..7.
final meta = MapMeta(seq: 1, stamp: 1763130000.12, resolution: 0.1, width: 200, height: 100, ox: -5, oy: -3);

/// The robot sits on the centre of pixel (40, 70), facing +y.
final robotAt = meta.pixelCentre(40, 70);

NavState nav({
  Map<String, dynamic>? pose,
  bool nav2Ready = true,
  String status = 'idle',
  String? reason,
  Map<String, dynamic>? goal,
  double? dist,
  double? eta,
  String? rejected,
  List<List<double>> plan = const [],
  Map<String, dynamic>? bringup,
}) =>
    NavState({
      'stamp': 1763130001.2,
      'frame_id': 'map',
      'pose': pose ?? {'x': robotAt.dx, 'y': robotAt.dy, 'yaw': pi / 2, 'age': 0.03},
      'pose_error': null,
      'nav2_ready': nav2Ready,
      'status': status,
      'reason': reason,
      'goal': goal,
      'distance_remaining': dist,
      'eta': eta,
      'navigation_time': null,
      'recoveries': dist == null ? null : 0,
      'plan': plan,
      'plan_age': plan.isEmpty ? null : 0.4,
      'bringup': bringup ??
          {
            'overall': 'bringing_up',
            'stamp': 1763130000.9,
            'age': 0.3,
            'stages': [
              {'name': 'slam', 'title': 'SLAM (rtabmap)', 'state': 'ready', 'required': true, 'message': '', 'checks': []},
              {
                'name': 'nav2',
                'title': 'Nav2',
                'state': 'starting',
                'required': true,
                'message': 'waiting for bt_navigator',
                'checks': [
                  {'label': 'bt_navigator active', 'ok': false, 'value': 'inactive', 'hint': 'lifecycle'}
                ]
              },
              {'name': 'camera', 'title': 'ZED', 'state': 'failed', 'required': false, 'message': 'no /zed topic', 'checks': []},
            ],
          },
      'bringup_reply': {'cmd': 'bringup_go', 'success': true, 'message': 'bringup queued', 'age': 5.1},
      'last_cmd': 'goal',
      'last_cmd_age': 2.4,
      'rejected': rejected,
    });

/// A real 200 × 100 PNG (grey with a dark block), as nav_relay would send.
Future<Uint8List> pngMap(WidgetTester t) async => (await t.runAsync(() async {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, 200, 100), Paint()..color = const Color(0xFFFEFEFE));
      c.drawRect(const Rect.fromLTWH(10, 10, 20, 20), Paint()..color = const Color(0xFF000000));
      final img = await rec.endRecording().toImage(200, 100);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    }))!;

const sizes = [Size(640, 360), Size(800, 384), Size(915, 412)];

void setSize(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

class Harness {
  final goals = <List<double>>[];
  final calls = <String>[];

  Widget page({bool connected = true, RobotState? robot, NavState? navState, NavMap? map}) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: AutonavPage(
            connected: connected,
            linkText: connected ? 'connected' : 'no link',
            linkColor: connected ? ok : bad,
            robot: robot,
            nav: navState,
            map: map,
            onGo: (x, y, yaw) => goals.add([x, y, yaw]),
            onCancel: () => calls.add('cancel'),
            onNavUp: () => calls.add('up'),
            onNavStop: () => calls.add('navstop'),
            onStop: () => calls.add('stop'),
            onWheels: () => calls.add('wheels'),
          ),
        ),
      );
}

/// Screen point of the centre of PNG pixel (u, v), from where the map image is drawn.
Offset pixelOnScreen(WidgetTester t, double u, double v) {
  final r = t.getRect(find.byKey(const Key('nav-map')));
  return Offset(r.left + (u + .5) * r.width / meta.width, r.top + (v + .5) * r.height / meta.height);
}

// ---------------------------------------------------------------------------------------
// foxglove frames

Uint8List cdrString(String s) {
  final b = utf8.encode(s);
  final d = ByteData(8 + b.length + 1)
    ..setUint8(1, 1) // CDR little endian
    ..setUint32(4, b.length + 1, Endian.little);
  final out = d.buffer.asUint8List();
  out.setRange(8, 8 + b.length, b);
  return out;
}

Uint8List cdrImage(double stamp, Uint8List png) {
  final w = BytesBuilder();
  void u32(int v) => w.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    u32(s.length + 1);
    w.add(utf8.encode(s));
    w.addByte(0);
    while ((w.length - 4) % 4 != 0) {
      w.addByte(0); // align to 4 within the body (after the encapsulation header)
    }
  }

  w.add([0, 1, 0, 0]);
  final sec = stamp.floor();
  u32(sec);
  u32(((stamp - sec) * 1e9).round());
  str('map');
  str('png');
  u32(png.length);
  w.add(png);
  return w.toBytes();
}

Uint8List messageData(int sub, Uint8List payload) {
  final h = ByteData(13)
    ..setUint8(0, 1)
    ..setUint32(1, sub, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...payload]);
}

/// The real client with the socket replaced by a list.
class WireClient extends FoxgloveClient {
  final sent = <Object>[];
  @override
  bool get isOpen => true;
  @override
  void sendRaw(Object data) => sent.add(data);

  List<Map<String, dynamic>> get ops =>
      [for (final s in sent) if (s is String) jsonDecode(s) as Map<String, dynamic>];

  /// subscription id → channel id of the subscriptions now open.
  Map<int, int> get open {
    final m = <int, int>{};
    for (final o in ops) {
      if (o['op'] == 'subscribe') {
        for (final s in o['subscriptions'] as List) {
          m[s['id'] as int] = s['channelId'] as int;
        }
      } else if (o['op'] == 'unsubscribe') {
        for (final id in o['subscriptionIds'] as List) {
          m.remove(id);
        }
      }
    }
    return m;
  }

  int subFor(int channel) => open.entries.firstWhere((e) => e.value == channel).key;
}

/// Stands in for the bridge in the page tests: records what the app sends.
class FakeClient extends FoxgloveClient {
  final modes = <String>[];
  final navCmds = <Map<String, dynamic>>[];
  final watches = <bool>[];

  @override
  void start(String newUrl) {
    url = newUrl;
    link = Link.connected;
    notifyListeners();
  }

  @override
  void stop() {}
  @override
  void drive(double vx, double wz) {}
  @override
  void watchCamera(bool on) {}
  @override
  void watchNav(bool on) => watches.add(on);
  @override
  void setMode(String mode) => modes.add(mode);
  @override
  void navCmd(Map<String, dynamic> cmd) => navCmds.add(cmd);

  void feed({RobotState? robot, NavState? navState, NavMap? map}) {
    state = robot ?? state;
    this.navState = navState ?? this.navState;
    navMap = map ?? navMap;
    notifyListeners();
  }
}

void main() {
  group('geometry', () {
    test('README pixel formula, origin yaw 0 and rotated', () {
      final m = MapMeta(seq: 3, stamp: 0, resolution: 0.15, width: 834, height: 600, ox: -60, oy: -40);
      // bottom-left pixel = lowest x, lowest y; row 0 = top = highest y
      expect(m.pixelCentre(0, 599).dx, closeTo(-60 + .075, 1e-9));
      expect(m.pixelCentre(0, 599).dy, closeTo(-40 + .075, 1e-9));
      expect(m.pixelCentre(833, 0).dx, closeTo(-60 + 833.5 * .15, 1e-9));
      expect(m.pixelCentre(833, 0).dy, closeTo(-40 + 599.5 * .15, 1e-9));

      final r = MapMeta(seq: 1, stamp: 0, resolution: 1, width: 10, height: 4, ox: 2, oy: 3, oyaw: pi / 2);
      // grid +x is map +y: pixel (u, v) centre = (ox − gy, oy + gx)
      final p = r.pixelCentre(1, 3); // gx 1.5, gy 0.5
      expect(p.dx, closeTo(2 - .5, 1e-9));
      expect(p.dy, closeTo(3 + 1.5, 1e-9));
      final g = r.mapToGrid(p);
      expect(g.dx, closeTo(1.5, 1e-9));
      expect(g.dy, closeTo(.5, 1e-9));
    });

    test('view: screen ↔ map round trip, zoom keeps the focal point', () {
      final v = MapView.fit(meta, const Size(400, 300));
      final p = v.toMap(const Offset(123, 77));
      expect(v.toScreen(p).dx, closeTo(123, 1e-9));
      expect(v.toScreen(p).dy, closeTo(77, 1e-9));
      final z = v.zoomPan(const Offset(123, 77), 2, Offset.zero);
      expect(z.pxPerM, closeTo(v.pxPerM * 2, 1e-9));
      expect(z.toScreen(p).dx, closeTo(123, 1e-6));
      expect(z.toScreen(p).dy, closeTo(77, 1e-6));
      // heading: screen right = +x (yaw 0), screen up = +y (yaw π/2)
      expect(v.yawBetween(Offset.zero, const Offset(10, 0)), closeTo(0, 1e-9));
      expect(v.yawBetween(Offset.zero, const Offset(0, -10)), closeTo(pi / 2, 1e-9));
    });
  });

  group('client', () {
    const chState = 40, chMap = 41, chMeta = 42;
    void advertise(WireClient c) {
      c.handleMessage(jsonEncode({'op': 'serverInfo'}));
      c.handleMessage(jsonEncode({
        'op': 'advertise',
        'channels': [
          {'id': chState, 'topic': '/teleop/nav/state'},
          {'id': chMap, 'topic': '/teleop/nav/map'},
          {'id': chMeta, 'topic': '/teleop/nav/map_meta'},
        ]
      }));
    }

    Map<String, dynamic> metaJson(int seq, double stamp, int bytes) => {
          'seq': seq,
          'stamp': stamp,
          'map_stamp': stamp - .3,
          'frame_id': 'map',
          'resolution': 0.1,
          'width': 200,
          'height': 100,
          'origin': {'x': -5.0, 'y': -3.0, 'yaw': 0.0},
          'downsample': 2,
          'source_resolution': 0.05,
          'source_width': 400,
          'source_height': 200,
          'encoding': 'png',
          'values': {'free': 254, 'occupied': 0, 'unknown': 205},
          'bytes': bytes,
        };

    test('advertises nav_cmd; nav topics only while watched; map+meta paired by stamp', () {
      final c = WireClient();
      advertise(c);
      final adv = c.ops.firstWhere((o) => o['op'] == 'advertise');
      expect((adv['channels'] as List).map((ch) => ch['topic']), contains('/teleop/phone/nav_cmd'));
      expect(c.open.values, isNot(contains(chState)));

      c.watchNav(true);
      expect(c.open.values, containsAll([chState, chMap, chMeta]));
      final png = Uint8List.fromList(List.generate(50, (i) => i));
      c.handleMessage(messageData(c.subFor(chMeta), cdrString(jsonEncode(metaJson(1, 1763130000.12, 50)))));
      expect(c.navMap, isNull); // meta alone isn't a map
      c.handleMessage(messageData(c.subFor(chMap), cdrImage(1763130000.12, png)));
      expect(c.navMap!.meta.seq, 1);
      expect(c.navMap!.png, png);
      expect(c.navMap!.meta.width, 200);

      c.handleMessage(messageData(c.subFor(chState), cdrString(jsonEncode(nav().json))));
      expect(c.navState!.status, 'idle');
      expect(c.navState!.pose!.x, closeTo(robotAt.dx, 1e-9));

      // all fine: no re-subscription
      final asked = c.mapSubscriptions;
      c.checkMap(now: DateTime.now().add(const Duration(seconds: 10)));
      expect(c.mapSubscriptions, asked);

      c.watchNav(false);
      expect(c.open, isEmpty);
      expect(c.navMap, isNotNull); // kept for the next visit
    });

    test('a dropped map image: subscribed again after mapRetry, and on every page open', () {
      final c = WireClient();
      advertise(c);
      c.watchNav(true);
      expect(c.mapSubscriptions, 1);
      final png = Uint8List.fromList([1, 2, 3]);
      c.handleMessage(messageData(c.subFor(chMeta), cdrString(jsonEncode(metaJson(1, 100.5, 3)))));
      c.handleMessage(messageData(c.subFor(chMap), cdrImage(100.5, png)));
      expect(c.navMap!.meta.seq, 1);

      // map #2: the meta comes, its image is dropped by the bridge
      c.handleMessage(messageData(c.subFor(chMeta), cdrString(jsonEncode(metaJson(2, 102.5, 4)))));
      expect(c.navMap!.meta.seq, 1);
      c.checkMap(now: DateTime.now().add(const Duration(seconds: 1)));
      expect(c.mapSubscriptions, 1); // too early
      final oldMapSub = c.subFor(chMap);
      c.checkMap(now: DateTime.now().add(const Duration(seconds: 4)));
      expect(c.mapSubscriptions, 2);
      expect(c.open.values.where((ch) => ch == chMap), hasLength(1));
      expect(c.subFor(chMap), isNot(oldMapSub)); // a fresh subscription id

      // the latched copy arrives on the new subscription (meta first)
      final png2 = Uint8List.fromList([4, 5, 6, 7]);
      c.handleMessage(messageData(c.subFor(chMeta), cdrString(jsonEncode(metaJson(2, 102.5, 4)))));
      c.handleMessage(messageData(c.subFor(chMap), cdrImage(102.5, png2)));
      expect(c.navMap!.meta.seq, 2);
      expect(c.navMap!.png, png2);
      // a late frame on the old subscription is ignored
      c.handleMessage(messageData(oldMapSub, cdrImage(100.5, png)));
      expect(c.navMap!.meta.seq, 2);

      // image without its meta (meta dropped): asks again too
      c.handleMessage(messageData(c.subFor(chMap), cdrImage(104.5, png)));
      expect(c.navMap!.meta.seq, 2);
      c.checkMap(now: DateTime.now().add(const Duration(seconds: 4)));
      expect(c.mapSubscriptions, 3);

      c.watchNav(false);
      c.watchNav(true); // the page opens again: ask for the latched copy
      expect(c.mapSubscriptions, 4);
      c.watchNav(false);
    });

    test('nav_cmd: JSON in a std_msgs/String on its own channel', () {
      final c = WireClient();
      advertise(c);
      final adv = c.ops.firstWhere((o) => o['op'] == 'advertise');
      final ch = (adv['channels'] as List).firstWhere((x) => x['topic'] == '/teleop/phone/nav_cmd')['id'] as int;
      c.navGoal(1.5, -2, pi / 2);
      final b = c.sent.last as Uint8List;
      expect(b[0], 1);
      expect(ByteData.sublistView(b).getUint32(1, Endian.little), ch);
      final msg = jsonDecode(utf8.decode(b.sublist(5))) as Map<String, dynamic>;
      expect(jsonDecode(msg['data'] as String), {'cmd': 'goal', 'x': 1.5, 'y': -2.0, 'yaw': pi / 2});
    });
  });

  group('page', () {
    for (final s in sizes) {
      testWidgets('lays out without overflow at ${s.width.toInt()}x${s.height.toInt()}', (t) async {
        setSize(t, s);
        final h = Harness();
        await t.pumpWidget(h.page(
            robot: mux(),
            navState: nav(status: 'navigating', dist: 12.4, eta: 40, rejected: 'goal refused: active source is ground'),
            map: NavMap(meta, Uint8List(0))));
        expect(t.takeException(), isNull);
        await t.pumpWidget(h.page(connected: false));
        expect(t.takeException(), isNull);
        await t.pumpWidget(h.page(robot: mux(source: 'ground'), navState: nav()));
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('known map + meta: tap → goal at the right map point, robot marker on its pixel', (t) async {
      setSize(t, sizes[1]);
      final png = await pngMap(t);
      final h = Harness();
      await t.pumpWidget(h.page(robot: mux(), navState: nav(), map: NavMap(meta, png)));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // PNG decode
      await t.pump();
      final raw = t.widget<RawImage>(find.descendant(of: find.byKey(const Key('nav-map')), matching: find.byType(RawImage)));
      expect(raw.image?.width, 200);
      expect(raw.image?.height, 100);

      // the PNG is drawn unstretched: one pixel is square on screen
      final r = t.getRect(find.byKey(const Key('nav-map')));
      expect(r.width / r.height, closeTo(2, 1e-6));

      // robot (TF pose) on the centre of pixel (40, 70)
      final robot = t.getCenter(find.byKey(const Key('nav-robot')));
      final want = pixelOnScreen(t, 40, 70);
      expect(robot.dx, closeTo(want.dx, 0.01));
      expect(robot.dy, closeTo(want.dy, 0.01));

      // nothing goes out before GO; GO is off without a goal
      expect(find.text('Tap the map for a goal.'), findsOneWidget);
      await t.tap(find.text('GO'));
      expect(h.goals, isEmpty);

      // tap on the centre of pixel (150, 20) = map (10.05, 4.95)
      await t.tapAt(pixelOnScreen(t, 150, 20));
      await t.pump();
      final goal = t.getCenter(find.byKey(const Key('nav-goal-draft')));
      expect(goal.dx, closeTo(pixelOnScreen(t, 150, 20).dx, 0.01));
      expect(h.goals, isEmpty);
      await t.tap(find.text('GO'));
      expect(h.goals, hasLength(1));
      final p = meta.pixelCentre(150, 20);
      expect(p.dx, closeTo(10.05, 1e-9));
      expect(p.dy, closeTo(4.95, 1e-9));
      expect(h.goals[0][0], closeTo(10.05, 1e-6));
      expect(h.goals[0][1], closeTo(4.95, 1e-6));
      // default heading: away from the robot
      expect(h.goals[0][2], closeTo(atan2(4.95 - robotAt.dy, 10.05 - robotAt.dx), 1e-6));
    });

    testWidgets('drag from the goal sets the heading (REP-103); a drag elsewhere does nothing', (t) async {
      setSize(t, sizes[1]);
      final h = Harness();
      await t.pumpWidget(h.page(robot: mux(), navState: nav(), map: NavMap(meta, Uint8List(0))));
      final at = pixelOnScreen(t, 100, 50);
      await t.tapAt(at);
      await t.pump();

      // drag up = map +y = yaw π/2
      await t.dragFrom(at, const Offset(0, -80));
      await t.pump();
      await t.tap(find.text('GO'));
      expect(h.goals.last[2], closeTo(pi / 2, 1e-6));
      // drag left = −x = yaw π
      await t.dragFrom(at, const Offset(-80, 0));
      await t.pump();
      await t.tap(find.text('GO'));
      expect(h.goals.last[2].abs(), closeTo(pi, 1e-6));
      // the goal didn't move
      expect(h.goals.last[0], closeTo(meta.pixelCentre(100, 50).dx, 1e-6));

      // a one-finger drag away from the goal: no new goal, no pan
      final before = t.getRect(find.byKey(const Key('nav-map')));
      await t.dragFrom(pixelOnScreen(t, 20, 20), const Offset(100, 60));
      await t.pump();
      expect(t.getRect(find.byKey(const Key('nav-map'))), before);
      await t.tap(find.text('GO'));
      expect(h.goals.last[0], closeTo(meta.pixelCentre(100, 50).dx, 1e-6));
    });

    testWidgets('two fingers pan and zoom, and place no goal', (t) async {
      setSize(t, sizes[1]);
      final h = Harness();
      await t.pumpWidget(h.page(robot: mux(), navState: nav(), map: NavMap(meta, Uint8List(0))));
      final r0 = t.getRect(find.byKey(const Key('nav-map')));
      final c = r0.center;
      final a = await t.startGesture(c - const Offset(40, 0), pointer: 1);
      final b = await t.startGesture(c + const Offset(40, 0), pointer: 2);
      for (var i = 1; i <= 4; i++) {
        await a.moveTo(c - Offset(40.0 + 20 * i, 0));
        await b.moveTo(c + Offset(40.0 + 20 * i, 0));
        await t.pump();
      }
      await a.up();
      await b.up();
      await t.pump();
      final r1 = t.getRect(find.byKey(const Key('nav-map')));
      expect(r1.width / r0.width, closeTo(120 / 40, 1e-6)); // finger distance 80 → 240
      expect(r1.center.dx, closeTo(c.dx, 1e-6)); // zoomed about the fingers
      expect(find.byKey(const Key('nav-goal-draft')), findsNothing);

      // pan: both fingers move together
      final p1 = await t.startGesture(c - const Offset(30, 0), pointer: 3);
      final p2 = await t.startGesture(c + const Offset(30, 0), pointer: 4);
      for (var i = 1; i <= 3; i++) {
        await p1.moveTo(c - const Offset(30, 0) + Offset(10.0 * i, 20.0 * i));
        await p2.moveTo(c + const Offset(30, 0) + Offset(10.0 * i, 20.0 * i));
        await t.pump();
      }
      await p1.up();
      await p2.up();
      await t.pump();
      final r2 = t.getRect(find.byKey(const Key('nav-map')));
      expect(r2.left - r1.left, closeTo(30, 1e-6));
      expect(r2.top - r1.top, closeTo(60, 1e-6));
      expect(find.byKey(const Key('nav-goal-draft')), findsNothing);
      expect(h.goals, isEmpty);
    });

    testWidgets('header, stages, progress, rejected reason; stages dialog shows reasons', (t) async {
      setSize(t, sizes[1]);
      final h = Harness();
      await t.pumpWidget(h.page(
        robot: mux(mode: 'autonomous'),
        navState: nav(
          status: 'navigating',
          dist: 12.4,
          eta: 40,
          goal: {'x': 3.0, 'y': 4.0, 'yaw': 1.0, 'age': 2.4},
          plan: [
            [robotAt.dx, robotAt.dy],
            [3.0, 4.0]
          ],
          rejected: 'bringup_go refused: /bringup/go not available (app_bringup_manager running?)',
        ),
        map: NavMap(meta, Uint8List(0)),
      ));
      expect(find.text('AUTONAV'), findsOneWidget);
      expect(find.text('● server up'), findsOneWidget); // action server there, nav2 stage still starting
      expect(find.text('AUTONOMOUS'), findsOneWidget);
      expect(find.text('12.4 m · 40 s'), findsOneWidget);
      expect(find.textContaining('✗ bringup_go refused: /bringup/go not available'), findsOneWidget);
      expect(find.byKey(const Key('nav-goal')), findsOneWidget);
      final stages = t.widget<RichText>(find.descendant(of: find.byKey(const Key('nav-stages')), matching: find.byType(RichText)).at(1));
      expect(stages.text.toPlainText(), '✓⟳✗');

      await t.tap(find.byKey(const Key('nav-stages')));
      await t.pumpAndSettle();
      expect(find.text('Nav2 bringup: bringing_up'), findsOneWidget);
      expect(find.text('waiting for bt_navigator'), findsOneWidget);
      expect(find.text('✗ bt_navigator active: inactive — lifecycle'), findsOneWidget);
      expect(find.text('ZED (optional)'), findsOneWidget);
      expect(find.text('last bringup_go: ok — bringup queued'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();

      // all green
      await t.pumpWidget(h.page(
          robot: mux(),
          navState: nav(bringup: {
            'overall': 'ready',
            'stamp': 1.0,
            'age': 0.2,
            'stages': [
              {'name': 'nav2', 'title': 'Nav2', 'state': 'ready', 'required': true, 'message': '', 'checks': []}
            ]
          }),
          map: NavMap(meta, Uint8List(0))));
      expect(find.text('● ready'), findsOneWidget);
    });

    testWidgets('source not phone or no Nav2: buttons off with the reason, STOP works', (t) async {
      setSize(t, sizes[1]);
      final h = Harness();
      await t.pumpWidget(h.page(robot: mux(source: 'ground'), navState: nav(), map: NavMap(meta, Uint8List(0))));
      expect(find.textContaining('takes commands from "ground"'), findsOneWidget);
      await t.tapAt(pixelOnScreen(t, 100, 50));
      await t.pump();
      for (final b in ['NAV UP', 'NAV STOP', 'GO', 'CANCEL']) {
        await t.tap(find.text(b));
      }
      expect(h.goals, isEmpty);
      expect(h.calls, isEmpty);
      await t.tap(find.text('STOP'));
      expect(h.calls, ['stop']);

      await t.pumpWidget(h.page(robot: mux(), navState: nav(nav2Ready: false), map: NavMap(meta, Uint8List(0))));
      expect(find.text('Nav2 is not up: NAV UP.'), findsOneWidget);
      await t.tap(find.text('GO'));
      expect(h.goals, isEmpty);
      await t.tap(find.text('NAV UP'));
      await t.tap(find.text('NAV STOP'));
      expect(h.calls, ['stop', 'up', 'navstop']);
    });
  });

  group('app', () {
    Future<FakeClient> openApp(WidgetTester t) async {
      setSize(t, sizes[1]);
      SharedPreferences.setMockInitialValues({'host': '127.0.0.1'});
      final c = FakeClient();
      await t.pumpWidget(MaterialApp(home: TeleopPage(client: c)));
      await t.pump();
      c.feed(robot: mux(), navState: nav(), map: NavMap(meta, Uint8List(0)));
      await t.pump();
      return c;
    }

    Future<void> closeApp(WidgetTester t) async {
      await t.pumpWidget(const SizedBox()); // dispose: stops the timers
      await t.pump(const Duration(seconds: 2));
    }

    testWidgets('Autonav sits above Wheels; one-finger drags on it never turn a page', (t) async {
      final c = await openApp(t);
      expect(find.text('Camera ›'), findsOneWidget);
      await t.dragFrom(const Offset(200, 120), const Offset(500, 0));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('WHEELS'), findsOneWidget);

      // swipe down from Wheels (on its header) → Autonav
      await t.drag(find.text('WHEELS'), const Offset(0, 300));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('AUTONAV'), findsOneWidget);
      expect(find.text('WHEELS'), findsNothing);
      expect(c.watches.last, isTrue);

      // one-finger drags in every direction, on the map and next to it
      final map = t.getRect(find.byKey(const Key('nav-map-area')));
      for (final d in const [Offset(400, 0), Offset(-400, 0), Offset(0, 250), Offset(0, -250), Offset(300, 200)]) {
        await t.dragFrom(map.center, d);
        await t.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('AUTONAV'), findsOneWidget);
      }
      await t.drag(find.text('AUTONAV'), const Offset(0, -300)); // the header neither
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('AUTONAV'), findsOneWidget);
      // two fingers neither
      final a = await t.startGesture(map.center - const Offset(30, 0), pointer: 7);
      final b = await t.startGesture(map.center + const Offset(30, 0), pointer: 8);
      for (var i = 1; i <= 5; i++) {
        await a.moveBy(const Offset(60, 40));
        await b.moveBy(const Offset(60, 40));
        await t.pump();
      }
      await a.up();
      await b.up();
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('AUTONAV'), findsOneWidget);
      expect(find.text('STOP'), findsOneWidget); // the mux STOP is on the page

      // "⌄ Wheels" goes back; the nav topics are let go
      await t.tap(find.text('⌄ Wheels'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('WHEELS'), findsOneWidget);
      expect(c.watches.last, isFalse);

      // and "⌃ Autonav" goes up again
      await t.tap(find.text('⌃ Autonav'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('AUTONAV'), findsOneWidget);
      expect(c.watches.last, isTrue);
      await closeApp(t);
    });

    testWidgets('GO = mux autonomous, then the goal; CANCEL = cancel, then mux stop; NAV UP/STOP', (t) async {
      final c = await openApp(t);
      await t.dragFrom(const Offset(200, 120), const Offset(500, 0));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      await t.tap(find.text('⌃ Autonav'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));

      await t.tapAt(pixelOnScreen(t, 150, 20));
      await t.pump();
      await t.tap(find.text('GO'));
      expect(c.modes, ['autonomous']);
      expect(c.navCmds, isEmpty); // the goal waits for set_mode's repeats
      await t.pump(const Duration(milliseconds: 350));
      expect(c.navCmds, hasLength(1));
      expect(c.navCmds[0]['cmd'], 'goal');
      expect(c.navCmds[0]['x'] as double, closeTo(10.05, 1e-6));
      expect(c.navCmds[0]['y'] as double, closeTo(4.95, 1e-6));
      expect(c.navCmds[0].keys, unorderedEquals(['cmd', 'x', 'y', 'yaw']));

      // the relay reports our goal: the draft marker gives way to it
      final g = c.navCmds[0];
      c.feed(navState: nav(status: 'navigating', goal: {'x': g['x'], 'y': g['y'], 'yaw': g['yaw'], 'age': 0.1}));
      await t.pump();
      expect(find.byKey(const Key('nav-goal-draft')), findsNothing);
      expect(find.byKey(const Key('nav-goal')), findsOneWidget);

      await t.tap(find.text('CANCEL'));
      expect(c.navCmds.last, {'cmd': 'cancel'});
      expect(c.modes, ['autonomous', 'stop']);

      await t.tap(find.text('NAV UP'));
      await t.tap(find.text('NAV STOP'));
      expect(c.navCmds.skip(2).toList(), [
        {'cmd': 'bringup_go'},
        {'cmd': 'bringup_stop'}
      ]);
      await t.tap(find.text('STOP'));
      expect(c.modes.last, 'stop');
      await closeApp(t);
    });
  });
}

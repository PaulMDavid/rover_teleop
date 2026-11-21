// Gears (navigation_ws #37): the stick message, ▲ / ▼, the km/h readouts, and the
// fallback for a mux without gears.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rover_teleop/foxglove.dart';
import 'package:rover_teleop/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// /teleop/state as a mux from before #37 sends it.
Map<String, dynamic> oldJson({String source = 'phone', String mode = 'manual', double vx = 0.2}) => {
      'mode': mode,
      'mode_by': 'phone',
      'source': source,
      'teleop_age': {'phone': 0.05, 'ground': null},
      'teleop_timeout': 0.5,
      'max_linear': 0.5,
      'max_angular': 1.0,
      'out': {'vx': vx, 'vy': 0.0, 'wz': 0.35},
    };

/// /teleop/state with the #37 keys.
Map<String, dynamic> gearJson(
        {int gear = 2,
        double? speedMeas = 0.25,
        bool steerLimited = false,
        double maxLinear = 0.8,
        String source = 'phone'}) =>
    {
      ...oldJson(source: source, vx: 0.3),
      'max_linear': maxLinear,
      'gear': gear,
      'gears': [0.15, 0.30, 0.50, 0.80],
      'input': 'stick',
      'v_target': 0.30,
      'kappa_max': 1.0,
      'steer_limited': steerLimited,
      'a_lat_max': 0.5,
      'speed_meas': speedMeas,
      'speed_meas_age': speedMeas == null ? null : 0.05,
    };

class WireClient extends FoxgloveClient {
  final sent = <Object>[];
  @override
  bool get isOpen => true;
  @override
  void sendRaw(Object data) => sent.add(data);

  /// (channel, decoded JSON) of the clientMessageData frames.
  List<(int, Map<String, dynamic>)> get published => [
        for (final s in sent)
          if (s is Uint8List && s[0] == 1)
            (
              ByteData.sublistView(s).getUint32(1, Endian.little),
              jsonDecode(utf8.decode(s.sublist(5))) as Map<String, dynamic>
            )
      ];
}

class FakeClient extends FoxgloveClient {
  final sticks = <(double, double)>[];
  final shifts = <String>[];

  @override
  void start(String newUrl) {
    url = newUrl;
    link = Link.connected;
    notifyListeners();
  }

  @override
  void stop() {}
  @override
  void stick(double throttle, double steer) => sticks.add((throttle, steer));
  @override
  void shift(String gear) => shifts.add(gear);
  @override
  void watchCamera(bool on) {}
  @override
  void watchNav(bool on) {}
  @override
  void setMode(String mode) {}

  void feed(Map<String, dynamic> json) {
    state = RobotState(json);
    notifyListeners();
  }
}

const sizes = [Size(640, 360), Size(800, 384), Size(915, 412)];

void setSize(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Future<FakeClient> openApp(WidgetTester t, Map<String, dynamic> json, {Size size = const Size(800, 384)}) async {
  setSize(t, size);
  SharedPreferences.setMockInitialValues({'host': '127.0.0.1'});
  final c = FakeClient();
  await t.pumpWidget(MaterialApp(home: TeleopPage(client: c)));
  await t.pump();
  c.feed(json);
  await t.pump();
  return c;
}

Future<void> toCamera(WidgetTester t) async {
  await t.tap(find.text('Camera ›'));
  await t.pumpAndSettle(const Duration(milliseconds: 100));
  expect(find.text('‹ Controls'), findsOneWidget);
}

Future<void> closeApp(WidgetTester t) async {
  await t.pumpWidget(const SizedBox()); // dispose: stops the timers
  await t.pump(const Duration(seconds: 2));
}

String kmhText(WidgetTester t) => t.widget<Text>(find.byKey(const Key('speed-kmh'))).data!;

void main() {
  group('state', () {
    test('old mux: no gears, speed = out.vx (commanded)', () {
      final st = RobotState(oldJson());
      expect(st.hasGears, isFalse);
      expect(st.gear, isNull);
      expect(st.gearSpeed, isNull);
      expect(st.steerLimited, isFalse);
      expect(st.speed, (mps: 0.2, measured: false));
    });

    test('new mux: gear, gear speed capped by max_linear, measured speed', () {
      final st = RobotState(gearJson(gear: 4, maxLinear: 0.5));
      expect(st.hasGears, isTrue);
      expect(st.gear, 4);
      expect(st.gears, [0.15, 0.30, 0.50, 0.80]);
      expect(st.gearSpeed, 0.5);
      expect(st.input, 'stick');
      expect(st.speed, (mps: 0.25, measured: true));
      expect(RobotState(gearJson(speedMeas: null)).speed, (mps: 0.3, measured: false));
      // no out: v_target
      expect(RobotState({...gearJson(speedMeas: null)}..remove('out')).speed, (mps: 0.3, measured: false));
    });

    test('kmh: one decimal, no -0.0', () {
      expect(kmh(0.5), '1.8');
      expect(kmh(0.8), '2.9');
      expect(kmh(-0.01), '0.0');
      expect(kmh(-0.5), '-1.8');
    });
  });

  group('wire', () {
    test('stick and gear are advertised and published as Twist / String', () {
      final c = WireClient();
      c.handleMessage(jsonEncode({'op': 'serverInfo', 'name': 'x', 'capabilities': []}));
      final adv = jsonDecode(c.sent.first as String) as Map<String, dynamic>;
      final topics = {for (final ch in adv['channels'] as List) ch['topic']: ch};
      expect(topics['/teleop/phone/stick']['schemaName'], 'geometry_msgs/msg/Twist');
      expect(topics['/teleop/phone/gear']['schemaName'], 'std_msgs/msg/String');
      expect(topics['/teleop/phone/cmd_vel'], isNull); // no cmd_vel path any more
      final stickCh = topics['/teleop/phone/stick']['id'], gearCh = topics['/teleop/phone/gear']['id'];

      c.stick(0.5, -0.25);
      c.stick(3, -3); // clamped
      c.shift('up');
      c.shift('down');
      final p = c.published;
      expect(p[0].$1, stickCh);
      expect(p[0].$2, {
        'linear': {'x': 0.5, 'y': 0.0, 'z': 0.0},
        'angular': {'x': 0.0, 'y': 0.0, 'z': -0.25},
      });
      expect(p[1].$2['linear']['x'], 1.0);
      expect(p[1].$2['angular']['z'], -1.0);
      // records compare maps by identity, so check the fields one by one
      expect(p[2].$1, gearCh);
      expect(p[2].$2, {'data': 'up'});
      expect(p[3].$1, gearCh);
      expect(p[3].$2, {'data': 'down'});
    });
  });

  group('app', () {
    /// Drags the Controls joystick from its centre by `by` and lets the 10 Hz sender run.
    Future<TestGesture> push(WidgetTester t, Offset by) async {
      final g = await t.startGesture(t.getCenter(find.byType(Joystick)));
      await g.moveBy(by);
      await t.pump(const Duration(milliseconds: 250));
      return g;
    }

    testWidgets('new mux: Controls joystick sends the normalized stick, + steer = left', (t) async {
      final c = await openApp(t, gearJson());
      // up and right
      var g = await push(t, const Offset(40, -40));
      var (throttle, steer) = c.sticks.last;
      expect(throttle, greaterThan(0.3));
      expect(steer, lessThan(-0.3));
      expect(throttle, lessThanOrEqualTo(1));
      await g.up();
      await t.pump(const Duration(milliseconds: 250));
      expect(c.sticks.last, (0.0, 0.0));

      // down and left: reverse, steer left
      c.feed(gearJson());
      g = await push(t, const Offset(-40, 40));
      (throttle, steer) = c.sticks.last;
      expect(throttle, lessThan(-0.3));
      expect(steer, greaterThan(0.3));
      await g.up();
      await closeApp(t);
    });

    testWidgets('old mux: Controls joystick off, warning, nothing sent', (t) async {
      final c = await openApp(t, oldJson());
      expect(find.text(oldMuxWarning), findsOneWidget);
      final g = await push(t, const Offset(40, -40));
      expect(c.sticks, isEmpty);
      await g.up();
      await closeApp(t);
    });

    testWidgets('camera: stick goes out only while the deadman is held', (t) async {
      final c = await openApp(t, gearJson());
      await toCamera(t);
      final joy = t.getCenter(find.byType(Joystick));
      var g = await t.startGesture(joy);
      await g.moveBy(const Offset(-40, -40));
      await t.pump(const Duration(milliseconds: 250));
      expect(c.sticks.last, (0.0, 0.0)); // no deadman
      await g.up();

      c.feed(gearJson());
      final dm = await t.startGesture(t.getCenter(find.byType(DeadmanSwitch)), pointer: 7);
      await t.pump();
      g = await t.startGesture(joy, pointer: 8);
      await g.moveBy(const Offset(-40, -40)); // up and left
      await t.pump(const Duration(milliseconds: 250));
      final (throttle, steer) = c.sticks.last;
      expect(throttle, greaterThan(0.3));
      expect(steer, greaterThan(0.3));
      await dm.up();
      await t.pump(const Duration(milliseconds: 250));
      expect(c.sticks.last, (0.0, 0.0));
      await g.up();
      await closeApp(t);
    });

    testWidgets('camera: ▲ / ▼ send up / down; the ends and other sources are off', (t) async {
      final c = await openApp(t, gearJson(gear: 2));
      await toCamera(t);
      expect(t.widget<Text>(find.byKey(const Key('gear-value'))).data, '2');
      expect(find.text('≤ 1.1 km/h'), findsOneWidget);
      await t.tap(find.byKey(const Key('gear-up')));
      await t.tap(find.byKey(const Key('gear-down')));
      expect(c.shifts, ['up', 'down']);

      c.feed(gearJson(gear: 1));
      await t.pump();
      await t.tap(find.byKey(const Key('gear-down')));
      expect(c.shifts, ['up', 'down']); // already in 1

      c.feed(gearJson(gear: 4, steerLimited: true));
      await t.pump();
      expect(find.text('≤ 2.9 km/h  ·  steering limited', findRichText: true), findsOneWidget);
      await t.tap(find.byKey(const Key('gear-up')));
      expect(c.shifts, ['up', 'down']); // already in 4
      await t.tap(find.byKey(const Key('gear-down')));
      expect(c.shifts, ['up', 'down', 'down']);

      c.feed(gearJson(gear: 2, source: 'ground'));
      await t.pump();
      await t.tap(find.byKey(const Key('gear-up')));
      expect(c.shifts, ['up', 'down', 'down']); // the mux takes gears only from its source
      await closeApp(t);
    });

    testWidgets('camera: a mux without gears: no gears, warning, no driving', (t) async {
      final c = await openApp(t, oldJson());
      await toCamera(t);
      expect(find.text('robot has no gears'), findsOneWidget);
      expect(find.text(oldMuxWarning), findsOneWidget);
      expect(find.byKey(const Key('gear-up')), findsNothing);
      expect(find.byKey(const Key('gear-down')), findsNothing);
      final dm = await t.startGesture(t.getCenter(find.byType(DeadmanSwitch)), pointer: 7);
      await t.pump();
      final g = await t.startGesture(t.getCenter(find.byType(Joystick)), pointer: 8);
      await g.moveBy(const Offset(40, -40));
      await t.pump(const Duration(milliseconds: 250));
      expect(c.sticks, isEmpty);
      await g.up();
      await dm.up();
      await closeApp(t);
    });

    testWidgets('km/h: measured, else commanded with "cmd"; Controls chip too', (t) async {
      final c = await openApp(t, gearJson(speedMeas: 0.5));
      expect(find.text('2 · 1.8'), findsOneWidget); // Controls chip
      await toCamera(t);
      expect(kmhText(t), '1.8');
      expect(find.byKey(const Key('speed-cmd')), findsNothing);

      c.feed(gearJson(speedMeas: null)); // out.vx 0.3
      await t.pump();
      expect(kmhText(t), '1.1');
      expect(find.byKey(const Key('speed-cmd')), findsOneWidget);

      c.feed(oldJson(vx: 0.2));
      await t.pump();
      expect(kmhText(t), '0.7');
      expect(find.byKey(const Key('speed-cmd')), findsOneWidget);

      await t.tap(find.text('‹ Controls'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      c.feed(oldJson(vx: 0.2));
      await t.pump();
      expect(find.text('none · 0.7 cmd'), findsOneWidget);
      await closeApp(t);
    });

    for (final s in sizes) {
      testWidgets('Camera and Controls lay out without overflow at ${s.width.toInt()}x${s.height.toInt()}', (t) async {
        final c = await openApp(t, gearJson(steerLimited: true), size: s);
        expect(t.takeException(), isNull);
        await toCamera(t);
        for (final json in [
          gearJson(steerLimited: true),
          gearJson(gear: 4, speedMeas: null, steerLimited: true),
          gearJson(source: 'ground'),
          gearJson(speedMeas: -0.75),
          oldJson(),
          oldJson(mode: 'stop'),
        ]) {
          c.feed(json);
          await t.pump();
          expect(t.takeException(), isNull);
        }
        // the gears sit above the joystick, the km/h above the deadman, not on them
        c.feed(gearJson());
        await t.pump();
        final joy = t.getRect(find.byType(Joystick));
        final gears = t.getRect(find.byType(GearControl));
        final dm = t.getRect(find.byType(DeadmanSwitch));
        final speed = t.getRect(find.byType(SpeedReadout));
        expect(gears.bottom, lessThanOrEqualTo(joy.top));
        expect(speed.bottom, lessThanOrEqualTo(dm.top));
        final top = t.getRect(find.text('‹ Controls'));
        expect(gears.top, greaterThanOrEqualTo(top.bottom));
        expect(speed.top, greaterThanOrEqualTo(top.bottom));
        expect(gears.right, lessThanOrEqualTo(s.width));
        await closeApp(t);
      });
    }

    testWidgets('a drag on a gear button turns no page and shifts nothing', (t) async {
      final c = await openApp(t, gearJson());
      await toCamera(t);
      await t.drag(find.byKey(const Key('gear-up')), const Offset(500, 0));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      await t.drag(find.byKey(const Key('gear-down')), const Offset(0, -300));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('‹ Controls'), findsOneWidget);
      expect(c.shifts, isEmpty);
      await closeApp(t);
    });
  });

  testWidgets('GearControl swallows page swipes even in a swipeable PageView', (t) async {
    setSize(t, sizes[1]);
    final shifts = <String>[];
    final pages = PageController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PageView(controller: pages, children: [
          Center(
              child: SizedBox(
                  width: 200, child: GearControl(robot: RobotState(gearJson()), enabled: true, onShift: shifts.add))),
          const Center(child: Text('page 2')),
        ]),
      ),
    ));
    await t.drag(find.byKey(const Key('gear-up')), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(pages.page, 0);
    expect(shifts, isEmpty);
    // control: a drag next to it does turn the page
    await t.dragFrom(const Offset(100, 50), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(pages.page, 1);
  });
}

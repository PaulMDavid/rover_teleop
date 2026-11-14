import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rover_teleop/foxglove.dart';
import 'package:rover_teleop/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

RobotState mux({String source = 'phone', String mode = 'manual'}) => RobotState({
      'mode': mode,
      'mode_by': 'phone',
      'source': source,
      'teleop_age': {'phone': 0.05, 'ground': null},
      'teleop_timeout': 0.5,
      'max_linear': 0.5,
      'max_angular': 1.0,
      'out': {'vx': 0.2, 'vy': 0.0, 'wz': 0.35},
    });

RoverState rover({bool tracked = true, String steering = 'crab', String? rejected}) => RoverState({
      'tracked': tracked,
      'input': 'autonomous',
      'steering': steering,
      'motion': 'running',
      'last_cmd': 'arm',
      'last_cmd_age': 4.2,
      'last_cmd_by': 'phone',
      'presses': 3,
      'rejected': rejected,
    });

class Harness {
  final cmds = <String>[];
  int arms = 0, stops = 0;

  Widget page({bool connected = true, RobotState? robot, RoverState? rov}) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: WheelsPage(
            connected: connected,
            linkText: connected ? 'connected' : 'no link',
            linkColor: connected ? ok : bad,
            robot: robot,
            rover: rov,
            onCommand: cmds.add,
            onArm: () => arms++,
            onStop: () => stops++,
          ),
        ),
      );
}

/// Phone landscape sizes (logical px): a small one and a common one.
const sizes = [Size(640, 360), Size(800, 384), Size(915, 412)];

void setSize(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  for (final s in sizes) {
    testWidgets('lays out without overflow at ${s.width.toInt()}x${s.height.toInt()}', (t) async {
      setSize(t, s);
      final h = Harness();
      await t.pumpWidget(h.page(robot: mux(), rov: rover(rejected: 'source is ground, not phone')));
      expect(t.takeException(), isNull);
      await t.pumpWidget(h.page(connected: false));
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('shows tracked state, guessed banner, mux line, rejected reason', (t) async {
    setSize(t, sizes[1]);
    final h = Harness();
    await t.pumpWidget(h.page(robot: mux(), rov: rover(rejected: 'wrong source')));
    expect(find.text('⚠ GUESSED STATE'), findsOneWidget);
    expect(find.text('AUTONOMOUS'), findsOneWidget);
    expect(find.text('CRAB'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('arm · 4 s'), findsOneWidget);
    expect(find.text('manual · phone'), findsOneWidget);
    expect(find.text('vx 0.20  wz 0.35  max 1.0'), findsOneWidget);
    expect(find.text('Rejected: wrong source'), findsOneWidget);

    await t.pumpWidget(h.page(robot: mux(), rov: rover(tracked: false)));
    expect(find.text('⚠ GUESSED STATE'), findsNothing);
  });

  testWidgets('no rover state: dashes, no banner', (t) async {
    setSize(t, sizes[1]);
    final h = Harness();
    await t.pumpWidget(h.page(robot: mux()));
    expect(find.text('⚠ GUESSED STATE'), findsNothing);
    expect(find.text('—'), findsNWidgets(4)); // input, steering, motion, last
  });

  testWidgets('buttons send the #23 command strings', (t) async {
    setSize(t, sizes[1]);
    final h = Harness();
    await t.pumpWidget(h.page(robot: mux(), rov: rover()));
    await t.tap(find.text('Input → /cmd_vel'));
    await t.tap(find.text('Ackermann'));
    await t.tap(find.text('Crab'));
    await t.tap(find.text('Resume'));
    expect(h.cmds, ['input_auto', 'steer_ackermann', 'steer_crab', 'resume']);

    await t.tap(find.text('Reset'));
    await t.pumpAndSettle();
    expect(find.text('robot_control restarted?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(h.cmds.last, 'resume');
    await t.tap(find.text('Reset'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Reset'));
    await t.pumpAndSettle();
    expect(h.cmds.last, 'reset');
  });

  testWidgets('HOLD TO ARM: a tap or a short hold does nothing, 1 s fires once', (t) async {
    setSize(t, sizes[1]);
    final h = Harness();
    await t.pumpWidget(h.page(robot: mux(), rov: rover()));
    final arm = find.text('HOLD TO ARM');

    await t.tap(arm);
    await t.pump(const Duration(seconds: 2));
    expect(h.arms, 0);

    // the fill starts on the next frame; pump() draws it, then 0.9 s of holding
    var g = await t.startGesture(t.getCenter(arm));
    await t.pump();
    await t.pump(const Duration(milliseconds: 900));
    expect(h.arms, 0);
    await g.up();
    await t.pump(const Duration(seconds: 2));
    expect(h.arms, 0);

    g = await t.startGesture(t.getCenter(arm));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 600));
    expect(h.arms, 1);
    expect(find.text('ARM SENT'), findsOneWidget);
    await t.pump(const Duration(seconds: 2)); // still held: no second arm
    await g.up();
    await t.pump();
    expect(h.arms, 1);
    expect(find.text('HOLD TO ARM'), findsOneWidget);
  });

  testWidgets('source not phone: buttons off with a reason, STOP still works', (t) async {
    setSize(t, sizes[1]);
    final h = Harness();
    await t.pumpWidget(h.page(robot: mux(source: 'ground'), rov: rover()));
    expect(find.textContaining('takes commands from "ground"'), findsOneWidget);
    await t.tap(find.text('Input → /cmd_vel'));
    await t.tap(find.text('Resume'));
    final g = await t.startGesture(t.getCenter(find.text('HOLD TO ARM')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(milliseconds: 600));
    await g.up();
    expect(h.cmds, isEmpty);
    expect(h.arms, 0);

    await t.tap(find.text('STOP'));
    expect(h.stops, 1);
  });

  testWidgets('no link: buttons off with a reason', (t) async {
    setSize(t, sizes[1]);
    final h = Harness();
    await t.pumpWidget(h.page(connected: false));
    expect(find.text('No link to the robot.'), findsOneWidget);
    await t.tap(find.text('Resume'));
    expect(h.cmds, isEmpty);
    await t.tap(find.text('STOP'));
    expect(h.stops, 1);
  });

  testWidgets('app opens on Controls; swipe right shows Wheels; a drag on a button keeps the page', (t) async {
    setSize(t, sizes[1]);
    SharedPreferences.setMockInitialValues({'host': '127.0.0.1'});
    await t.pumpWidget(const MaterialApp(home: TeleopPage()));
    await t.pump();
    expect(find.text('Camera ›'), findsOneWidget);
    expect(find.text('WHEELS'), findsNothing);

    // swipe right, starting on the status column (not a control)
    await t.dragFrom(const Offset(200, 120), const Offset(500, 0));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('WHEELS'), findsOneWidget);
    expect(find.text('Camera ›'), findsNothing);

    // a horizontal drag starting on a button doesn't turn the page
    await t.drag(find.text('Resume'), const Offset(-500, 0));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('WHEELS'), findsOneWidget);

    // swipe left from the status column goes back to Controls
    await t.dragFrom(const Offset(200, 200), const Offset(-500, 0));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Camera ›'), findsOneWidget);

    await t.pumpWidget(const SizedBox()); // dispose: stops the client's timers
    await t.pump(const Duration(seconds: 2));
  });
}

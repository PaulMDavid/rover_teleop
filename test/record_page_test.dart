// Record page (navigation_ws #29) against the JSON-lines contract of `phone_ctl.sh
// record …` (navigation_ws src/app_teleop/README.md, "Recording from the phone").
// fixtures/record_presets.jsonl is the real `record_drive.sh presets` output of
// scripts/record/presets.yaml (PR #35); the other lines are the README's examples, with
// the "…" lists filled in, and the real refused/busy lines of phone_ctl_lib.sh.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rover_teleop/foxglove.dart';
import 'package:rover_teleop/main.dart';
import 'package:rover_teleop/phone_ctl.dart';
import 'package:rover_teleop/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

final presetLines = File('test/fixtures/record_presets.jsonl').readAsLinesSync();

const topicLines = [
  '{"step": "topics", "state": "running", "reason": "sampling every live topic for 3 s", "t": 0.0}',
  '{"step": "topics", "state": "ok", "reason": "/imu/data", "t": 7.9, "topic": {"name": "/imu/data", "type": "sensor_msgs/msg/Imu", "hz": 499.7, "mbps": 0.1612}}',
  '{"step": "topics", "state": "ok", "reason": "/mip/ekf/status", "t": 7.9, "topic": {"name": "/mip/ekf/status", "type": "microstrain_inertial_msgs/msg/MipFilterStatus", "hz": null, "mbps": null}}',
  '{"step": "topics", "state": "ok", "reason": "/ouster/points", "t": 7.9, "topic": {"name": "/ouster/points", "type": "sensor_msgs/msg/PointCloud2", "hz": 10.0, "mbps": 25.6}}',
  '{"step": "topics", "state": "ok", "reason": "/tf_static", "t": 7.9, "topic": {"name": "/tf_static", "type": "tf2_msgs/msg/TFMessage", "hz": 0.0, "mbps": 0.0}}',
  '{"step": "topics", "state": "ok", "reason": "4 topics; 4 topics, 3 sampled for 3 s", "t": 7.9, "count": 4}',
  '{"done": true, "ok": true}',
];

const startWarnLines = [
  '{"step": "preflight", "state": "running", "reason": "checking /mnt/ssd", "t": 0.0}',
  '{"step": "preflight", "state": "ok", "reason": "412.3 GB free on /mnt/ssd", "t": 0.1, "free_gb": 412.3}',
  '{"step": "sensors", "state": "running", "reason": "zed: docker start zed2i_rec", "t": 0.3}',
  '{"step": "sensors", "state": "warn", "reason": "no messages after 90 s: /odom_wheels; recording anyway (topics are picked up when they appear)", "t": 97.2, "silent": ["/odom_wheels"]}',
  '{"step": "record", "state": "running", "reason": "docker run rec_drive", "t": 97.3}',
  '{"step": "record", "state": "ok", "reason": "recording drive_2026-11-20_130412: 52/53 topics subscribed (others are picked up when they appear)", "t": 105.4, "bag": "drive_2026-11-20_130412", "preset": "drive", "subscribed": 52, "topics": ["/imu/data"]}',
  '{"done": true, "ok": true}',
];

const startFailLines = [
  '{"step": "preflight", "state": "fail", "reason": "only 12.0 GB free on /mnt/ssd (need 20)", "t": 0.1, "free_gb": 12.0}',
  '{"step": "sensors", "state": "skipped", "reason": "", "t": 0.1}',
  '{"step": "record", "state": "skipped", "reason": "", "t": 0.1}',
  '{"done": true, "ok": false}',
];

const busyLines = [
  '{"step": "command", "state": "fail", "reason": "busy: another phone_ctl command is running", "t": 0.0}',
  '{"done": true, "ok": false}',
];

const refusedLines = [
  '{"step": "command", "state": "fail", "reason": "refused: -/not/there: not in the selection", "t": 0.0}',
  '{"done": true, "ok": false}',
];

String statusLine({
  bool recording = true,
  List<String>? silent = const ['/zed2i/zed_node/left/color/rect/image/compressed'],
  List<String> unclosed = const [],
  int elapsed = 761,
  double? leftH = 10.4,
}) =>
    jsonEncode({
      'step': 'status',
      'state': (silent?.isNotEmpty ?? false) || unclosed.isNotEmpty ? 'warn' : 'ok',
      'reason': recording ? 'recording drive_2026-11-20_130412 …' : 'not recording',
      't': 0.4,
      'recording': recording,
      'bag': 'drive_2026-11-20_130412',
      'preset': 'drive',
      'elapsed_s': recording ? elapsed : null,
      'size_mb': recording ? 8400.2 : null,
      'rate_mbps': recording ? 11.03 : null,
      'input_mbps': recording ? 12.1 : null,
      'free_gb': 412.3,
      'left_h': recording ? leftH : null,
      'topics': recording ? 53 : 0,
      'silent': recording ? silent : [],
      'unwatched': <String>[],
      'unclosed': unclosed,
    });

/// README example line, verbatim.
const readmeStatus =
    '{"step": "status", "state": "warn", "reason": "recording drive_2026-11-20_130412 00:12:41, 8400.2 MB, 11.03 MB/s, 412.3 GB free; no messages for 8 s: /zed2i/zed_node/left/color/rect/image/compressed", "t": 0.4, "recording": true, "bag": "drive_2026-11-20_130412", "preset": "drive", "elapsed_s": 761, "size_mb": 8400.2, "rate_mbps": 11.03, "input_mbps": 12.1, "free_gb": 412.3, "left_h": 10.4, "topics": 53, "silent": ["/zed2i/zed_node/left/color/rect/image/compressed"], "unwatched": [], "unclosed": []}';

const stopLines = [
  '{"step": "stop", "state": "running", "reason": "SIGINT to rec_drive; waiting for drive_2026-11-20_130412 to close", "t": 0.1, "bag": "drive_2026-11-20_130412"}',
  '{"step": "stop", "state": "running", "reason": "closing drive_2026-11-20_130412: compressing the last chunk, writing metadata", "t": 10.2}',
  '{"step": "stop", "state": "ok", "reason": "drive_2026-11-20_130412 closed: 20012.3 MB, 00:40:53, 2443615 messages in 17 files", "t": 14.8, "bag": "drive_2026-11-20_130412", "size_mb": 20012.3, "duration_s": 2452.9, "messages": 2443615, "files": 17}',
  '{"done": true, "ok": true}',
];

/// Stands in for ssh. A verb in [script] plays its lines, then fails with its exit code
/// like SshPhoneCtl (SshCommandFailed) when that isn't 0; any other verb is a stream the
/// test feeds by hand ([open]).
class FakeRecordCtl implements PhoneCtl {
  final verbs = <String>[];
  final cancelled = <String>[];
  final script = <String, (List<String>, int)>{};
  final open = <String, StreamController<String>>{};
  Object? error; // thrown by the next manual stream instead of lines

  @override
  Stream<String> run(String verb, {void Function(String host)? onConnected}) {
    verbs.add(verb);
    final s = script[verb];
    if (s != null) return _play(s.$1, s.$2);
    late final StreamController<String> c;
    c = StreamController<String>(onCancel: () {
      if (!c.isClosed) cancelled.add(verb); // closed = ended by itself
    });
    open[verb] = c;
    final e = error;
    if (e != null) {
      error = null;
      scheduleMicrotask(() {
        c.addError(e);
        c.close();
      });
    }
    return c.stream;
  }

  Stream<String> _play(List<String> lines, int code) async* {
    for (final l in lines) {
      yield l;
    }
    if (code != 0) throw SshCommandFailed(code, '');
  }

  void feed(String verb, List<String> lines) => lines.forEach(open[verb]!.add);
  Future<void> end(String verb) => open[verb]!.close();

  @override
  Future<String> publicKey() async => 'ssh-ed25519 AAAAC3NzaFAKE rover_teleop-phone';
  @override
  Future<String?> pinnedHostKey() async => null;
  @override
  Future<void> trustHostKey(String offered) async {}
}

FakeRecordCtl fakeWithPresets() => FakeRecordCtl()..script['record presets'] = (presetLines, 0);

const sizes = [Size(640, 360), Size(800, 384), Size(915, 412)];

void setSize(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget page(RecordController c, {List<String>? muxStops}) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: RecordPage(ctl: c, onStop: () => muxStops?.add('stop'), onWheels: () {})),
    );

Future<void> settle() => pumpEventQueue();

Text textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key)));

void main() {
  group('controller', () {
    test('presets: groups, presets, quiet_ok; drive preselected with all its topics', () async {
      final f = fakeWithPresets();
      final c = RecordController(f, retryDelay: Duration.zero);
      await c.loadPresets();
      expect(c.groups.map((g) => g.name), ['gq7', 'zed_cam', 'zed_imu', 'wheels', 'misc', 'ouster']);
      expect(c.presets.map((p) => p.name), ['drive', 'minimal', 'lidar']);
      expect(c.quietOk, contains('/tf_static'));
      expect(c.preset, 'drive');
      expect(c.selected.toList(), c.presets.first.topics);
      expect(c.groupState(c.groups.first), isTrue);
      expect(c.groupState(c.groups.last), isFalse); // ouster: not in drive
      expect(c.startCommand, 'record start drive');
    });

    test('selection → preset plus +/topic and -/topic', () async {
      final c = RecordController(fakeWithPresets(), retryDelay: Duration.zero);
      await c.loadPresets();
      final misc = c.groups.firstWhere((g) => g.name == 'misc');
      c.setGroup(misc, false);
      c.setTopic('/ouster/points', true);
      c.setTopic('/my/extra', true);
      expect(c.startCommand, 'record start drive +/ouster/points +/my/extra -/diagnostics -/rosout');
      expect(c.extraTopics, ['/my/extra']);
      final ouster = c.groups.firstWhere((g) => g.name == 'ouster');
      expect(c.groupState(ouster), isNull); // one of two
      c.setTopic('/rosout', true);
      expect(c.startCommand, 'record start drive +/ouster/points +/my/extra -/diagnostics');
      // another preset: back to its topics
      c.selectPreset('lidar');
      expect(c.startCommand, 'record start lidar');
      expect(c.groupState(ouster), isTrue);
      c.selectPreset('minimal');
      expect(c.groupState(c.groups.firstWhere((g) => g.name == 'zed_cam')), isFalse);
    });

    test('start with silent sensors: amber outcome, progress lines, then status attaches', () async {
      final f = fakeWithPresets()..script['record start drive'] = (startWarnLines, 0);
      final c = RecordController(f, retryDelay: Duration.zero);
      c.setVisible(true);
      await settle();
      f.feed('record status', [statusLine(recording: false)]);
      await f.end('record status');
      await settle();
      expect(c.recording, isFalse);
      expect(f.verbs, ['record presets', 'record status']); // not recording: no re-attach

      final progress = <String?>[];
      c.addListener(() => progress.add(c.opLine));
      expect(c.canStart, isTrue);
      await c.start();
      expect(progress, containsAll(['zed: docker start zed2i_rec', 'docker run rec_drive']));
      expect(c.op, isNull);
      expect(c.outcome!.level, 'warn');
      expect(c.outcome!.text, contains('recording drive_2026-11-20_130412'));
      expect(c.outcome!.text, contains('no messages after 90 s: /odom_wheels'));
      expect(f.verbs.last, 'record status');
      f.feed('record status', [readmeStatus]);
      await settle();
      expect(c.recording, isTrue);
      expect(c.canStart, isFalse);
      expect(c.canEdit, isFalse);
      expect(c.status!.silent, ['/zed2i/zed_node/left/color/rect/image/compressed']);
      c.dispose();
    });

    test('preflight fail: red, with the reason', () async {
      final f = fakeWithPresets()..script['record start drive'] = (startFailLines, 1);
      final c = RecordController(f, retryDelay: Duration.zero);
      await c.loadPresets();
      await c.start();
      expect(c.outcome!.level, 'fail');
      expect(c.outcome!.text, 'only 12.0 GB free on /mnt/ssd (need 20)');
    });

    test('busy (75) and refused (64) keep their reasons', () async {
      final f = fakeWithPresets()
        ..script['record start drive'] = (busyLines, 75)
        ..script['record start drive -/rosout'] = (refusedLines, 64);
      final c = RecordController(f, retryDelay: Duration.zero);
      await c.loadPresets();
      await c.start();
      expect(c.outcome!.level, 'busy');
      expect(c.outcome!.text, 'busy: another phone_ctl command is running');
      c.setTopic('/rosout', false);
      await c.start();
      expect(c.outcome!.level, 'refused');
      expect(c.outcome!.text, 'refused: -/not/there: not in the selection');
      expect(c.op, isNull);
    });

    test('status: re-attaches while recording (1 h end), not after it ended; hidden = closed', () async {
      final f = fakeWithPresets();
      final c = RecordController(f, retryDelay: Duration.zero);
      c.setVisible(true);
      await settle();
      f.feed('record status', [readmeStatus]);
      await f.end('record status'); // the 1 h limit
      await Future<void>.delayed(Duration.zero);
      await settle();
      expect(f.verbs.where((v) => v == 'record status'), hasLength(2));
      expect(c.attached, isTrue);

      // the page goes away: the stream (and its ssh connection) is closed
      c.setVisible(false);
      await settle();
      expect(f.cancelled, ['record status']);
      expect(c.attached, isFalse);
      // back: attaches again, shows the old status meanwhile
      c.setVisible(true);
      await settle();
      expect(f.verbs.where((v) => v == 'record status'), hasLength(3));
      expect(c.status!.recording, isTrue);

      // the recording ends: last line recording false, no new attach
      f.feed('record status', [statusLine(recording: false)]);
      await f.end('record status');
      await Future<void>.delayed(Duration.zero);
      await settle();
      expect(f.verbs.where((v) => v == 'record status'), hasLength(3));
      expect(c.recording, isFalse);
      expect(c.canStop, isFalse);
      c.dispose();
    });

    test('status over a broken link: error shown, retried while visible', () async {
      final f = fakeWithPresets()..error = SshUnreachable(['orintwo.local', '10.42.0.1']);
      final c = RecordController(f, retryDelay: Duration.zero);
      c.setVisible(true);
      await settle();
      expect(c.statusError, contains('orintwo not reachable'));
      await Future<void>.delayed(Duration.zero);
      await settle();
      expect(f.verbs.where((v) => v == 'record status'), hasLength(2));
      expect(c.attached, isTrue);
      f.feed('record status', [readmeStatus]);
      await settle();
      expect(c.statusError, isNull);
      c.dispose();
    });

    test('stop: final size/duration as the outcome', () async {
      final f = fakeWithPresets()..script['record stop'] = (stopLines, 0);
      final c = RecordController(f, retryDelay: Duration.zero);
      await c.stop();
      expect(c.outcome!.level, 'ok');
      expect(c.outcome!.text, 'drive_2026-11-20_130412 closed: 20012.3 MB, 00:40:53, 2443615 messages in 17 files');
    });

    test('topics: one RecTopic per topic line, nulls kept', () async {
      final f = FakeRecordCtl()..script['record topics'] = (topicLines, 0);
      final c = RecordController(f);
      await c.loadTopics();
      expect(c.topics!.map((t) => t.name), ['/imu/data', '/mip/ekf/status', '/ouster/points', '/tf_static']);
      expect(c.topics![1].hz, isNull);
      expect(c.topics![0].mbps, 0.1612);
    });

    test('formatting: MB = 10⁶, GB = 10⁹', () {
      expect(fmtElapsed(761), '00:12:41');
      expect(fmtSize(8400.2), '8.4 GB');
      expect(fmtSize(512.4), '512 MB');
      expect(fmtRate(4.1), '4.10 MB/s');
      expect(fmtRate(11.03), '11.0 MB/s');
      expect(fmtLeft(27.2), '27 h');
      expect(fmtLeft(0.5), '30 min');
      expect(fmtHz(null), '?');
    });
  });

  group('page', () {
    Future<(FakeRecordCtl, RecordController)> openPage(WidgetTester t, {Size size = const Size(800, 384), List<String>? muxStops}) async {
      setSize(t, size);
      final f = fakeWithPresets();
      final c = RecordController(f, retryDelay: Duration.zero);
      await t.pumpWidget(page(c, muxStops: muxStops));
      c.setVisible(true);
      await t.pump();
      await t.pump();
      return (f, c);
    }

    for (final s in sizes) {
      testWidgets('layout ${s.width.toInt()}×${s.height.toInt()}: groups, buttons, a busy status, no overflow', (t) async {
        final (f, c) = await openPage(t, size: s);
        expect(find.text('RECORD'), findsOneWidget);
        expect(find.text('Drive'), findsOneWidget);
        for (final g in c.groups) {
          expect(find.text(g.label), findsOneWidget);
        }
        final boxes = t.widgetList<Checkbox>(find.byType(Checkbox)).map((b) => b.value).toList();
        expect(boxes, [true, true, true, true, true, false]); // drive; ouster not
        f.feed('record status', [
          statusLine(silent: ['/zed2i/zed_node/left/color/rect/image/compressed', '/odom_wheels'], unclosed: ['drive_2026-11-19_101010'])
        ]);
        await t.pump();
        expect(find.text('● START'), findsOneWidget);
        expect(find.text('■ STOP'), findsOneWidget);
        expect(find.text('MUX STOP'), findsOneWidget);
        expect(find.byKey(const Key('rec-unclosed')), findsOneWidget);
        c.dispose();
      });
    }

    testWidgets('live status: elapsed, bag, size · rate, free, hours left, silent ✗ / ✓', (t) async {
      final (f, c) = await openPage(t);
      expect(textOf(t, 'rec-state').data, 'status…');
      f.feed('record status', [readmeStatus]);
      await t.pump();
      expect(textOf(t, 'rec-state').data, '● recording 00:12:41');
      expect(textOf(t, 'rec-bag').data, 'drive_2026-11-20_130412');
      expect(textOf(t, 'rec-size').data, '8.4 GB  ·  11.0 MB/s');
      expect(textOf(t, 'rec-free').data, '412 GB free');
      expect(textOf(t, 'rec-left').data, '≈ 10 h left at this rate');
      expect(find.text('✗ /zed2i/zed_node/left/color/rect/image/compressed NO MESSAGES'), findsOneWidget);
      expect(find.text('✓ all topics publishing'), findsNothing);
      // recording: START off, the selection locked
      expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '● START')).onPressed, isNull);
      expect(t.widget<Checkbox>(find.byType(Checkbox).first).onChanged, isNull);

      f.feed('record status', [statusLine(silent: [], elapsed: 3725, leftH: 0.5)]);
      await t.pump();
      expect(textOf(t, 'rec-state').data, '● recording 01:02:05');
      expect(find.text('✓ all topics publishing'), findsOneWidget);
      expect(textOf(t, 'rec-left').data, '≈ 30 min left at this rate');
      f.feed('record status', [statusLine(silent: null)]);
      await t.pump();
      expect(find.text('… checking topics'), findsOneWidget);

      // unclosed bag: banner, tap → the reindex command
      f.feed('record status', [statusLine(recording: false, unclosed: ['drive_2026-11-19_101010'])]);
      await t.pump();
      expect(textOf(t, 'rec-state').data, '○ not recording');
      expect(textOf(t, 'rec-bag').data, 'last: drive_2026-11-20_130412');
      await t.tap(find.byKey(const Key('rec-unclosed')));
      await t.pumpAndSettle();
      expect(find.textContaining('ros2 bag reindex -s sqlite3 /bags/drive_2026-11-19_101010'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      c.dispose();
    });

    testWidgets('STOP asks first; the mux STOP is the small one in the header', (t) async {
      final muxStops = <String>[];
      final (f, c) = await openPage(t, muxStops: muxStops);
      f.script['record stop'] = (stopLines, 0);
      f.feed('record status', [readmeStatus]);
      await t.pump();

      await t.tap(find.text('■ STOP'));
      await t.pumpAndSettle();
      expect(find.text('Stop recording?'), findsOneWidget);
      expect(find.textContaining('drive_2026-11-20_130412 is closed'), findsOneWidget);
      await t.tap(find.text('Keep recording'));
      await t.pumpAndSettle();
      expect(f.verbs, isNot(contains('record stop')));
      expect(muxStops, isEmpty); // the big STOP never touches the mux

      await t.tap(find.text('■ STOP'));
      await t.pumpAndSettle();
      await t.tap(find.text('Stop recording'));
      await t.pumpAndSettle();
      expect(f.verbs, contains('record stop'));
      expect(muxStops, isEmpty);
      expect(textOf(t, 'rec-outcome').data, startsWith('drive_2026-11-20_130412 closed: 20012.3 MB'));

      await t.tap(find.text('MUX STOP'));
      expect(muxStops, ['stop']);
      expect(f.verbs.where((v) => v == 'record stop'), hasLength(1));
      c.dispose();
    });

    testWidgets('All topics…: type, Hz, MB/s, search, ticks → +/topic -/topic on START', (t) async {
      final (f, c) = await openPage(t);
      f.feed('record status', [statusLine(recording: false)]);
      await f.end('record status');
      await t.pump();
      await t.tap(find.textContaining('All topics…'));
      await t.pump();
      expect(f.verbs, contains('record topics'));
      expect(find.text('sampling every live topic (≈ 10 s)…'), findsOneWidget);
      // the preset's topics are there (not live yet) and ticked
      expect(t.widget<Checkbox>(find.descendant(of: find.byKey(const Key('rec-topic-/Motor_pos')), matching: find.byType(Checkbox))).value, isTrue);
      expect(find.text('not live'), findsWidgets);
      f.feed('record topics', topicLines);
      await f.end('record topics');
      await t.pump();
      await t.pump();
      expect(find.text('4 live'), findsOneWidget);
      expect(find.text('sensor_msgs/msg/Imu'), findsOneWidget);
      expect(find.text('500'), findsOneWidget); // 499.7 Hz
      expect(find.text('0.161'), findsOneWidget); // MB/s
      expect(find.text('microstrain_inertial_msgs/msg/MipFilterStatus'), findsOneWidget);

      await t.enterText(find.byKey(const Key('rec-search')), 'ouster');
      await t.pump();
      expect(find.byKey(const Key('rec-topic-/imu/data')), findsNothing);
      expect(find.byKey(const Key('rec-topic-/ouster/points')), findsOneWidget);
      expect(find.text('25.6'), findsOneWidget);
      await t.tap(find.byKey(const Key('rec-topic-/ouster/points')));
      await t.enterText(find.byKey(const Key('rec-search')), 'rosout');
      await t.pump();
      await t.tap(find.byKey(const Key('rec-topic-/rosout'))); // not live, in drive: untick
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus(); // a blinking cursor never settles
      await t.tap(find.text('Done'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('(+1 −1)'), findsOneWidget);
      expect(t.widget<Checkbox>(find.descendant(of: find.byKey(const Key('rec-group-ouster')), matching: find.byType(Checkbox))).value, isNull);

      f.script['record start drive +/ouster/points -/rosout'] = (startWarnLines, 0);
      await t.tap(find.text('● START'));
      await t.pump();
      await t.pump();
      expect(f.verbs, contains('record start drive +/ouster/points -/rosout'));
      expect(textOf(t, 'rec-outcome').data, contains('no messages after 90 s: /odom_wheels'));
      expect(f.verbs.last, 'record status');
      c.dispose();
    });

    testWidgets('busy and refused are shown with their reasons', (t) async {
      final (f, c) = await openPage(t);
      f.feed('record status', [statusLine(recording: false)]);
      await f.end('record status');
      await t.pump();
      f.script['record start drive'] = (busyLines, 75);
      await t.tap(find.text('● START'));
      await t.pump();
      await t.pump();
      expect(textOf(t, 'rec-outcome').data, 'Busy: another phone_ctl command is running');
      expect(textOf(t, 'rec-outcome').style!.color, warn);
      f.feed('record status', [statusLine(recording: false)]);
      await t.pump();
      await t.tap(find.byKey(const Key('rec-group-misc')));
      f.script['record start drive -/diagnostics -/rosout'] = (refusedLines, 64);
      await t.tap(find.text('● START'));
      await t.pump();
      await t.pump();
      expect(textOf(t, 'rec-outcome').data, 'Refused: -/not/there: not in the selection');
      expect(textOf(t, 'rec-outcome').style!.color, bad);
      c.dispose();
    });
  });

  group('app', () {
    testWidgets('Record sits below Wheels: swipe up or "⌄ Record", back via "⌃ Wheels"; buttons don\'t turn it', (t) async {
      setSize(t, sizes[1]);
      SharedPreferences.setMockInitialValues({'host': '127.0.0.1'});
      final f = fakeWithPresets();
      final c = FakeClient();
      await t.pumpWidget(MaterialApp(home: TeleopPage(client: c, phoneCtl: f)));
      await t.pump();
      await t.dragFrom(const Offset(200, 120), const Offset(500, 0));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('WHEELS'), findsOneWidget);
      expect(f.verbs, isEmpty); // nothing over ssh before the page shows

      await t.tap(find.text('⌄ Record'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('RECORD'), findsOneWidget);
      expect(f.verbs, ['record presets', 'record status']);
      expect(f.cancelled, isEmpty);
      f.feed('record status', [readmeStatus]);
      await t.pump();
      await t.pump();
      expect(textOf(t, 'rec-state').data, '● recording 00:12:41');

      // drags that start on a control don't turn the page
      for (final d in const [Offset(0, 250), Offset(0, -250), Offset(400, 0), Offset(-400, 0)]) {
        await t.drag(find.text('■ STOP'), d);
        await t.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('RECORD'), findsOneWidget);
        await t.drag(find.text('GQ7 IMU/GNSS/EKF'), d);
        await t.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('RECORD'), findsOneWidget);
      }
      expect(find.text('Stop recording?'), findsNothing);

      // the mux STOP in the header is the mux's
      await t.tap(find.text('MUX STOP'));
      expect(c.modes, ['stop']);

      // "⌃ Wheels": back; the status stream is closed
      await t.tap(find.text('⌃ Wheels'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('WHEELS'), findsOneWidget);
      expect(f.cancelled, ['record status']);

      // swipe up from Wheels (on its header) → Record, status re-attached
      await t.drag(find.text('WHEELS'), const Offset(0, -300));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('RECORD'), findsOneWidget);
      expect(f.verbs.where((v) => v == 'record status'), hasLength(2));
      expect(f.verbs.where((v) => v == 'record presets'), hasLength(1));
      expect(textOf(t, 'rec-state').data, '● recording 00:12:41'); // the last one meanwhile

      // a swipe down on the header goes back to Wheels
      await t.drag(find.text('RECORD'), const Offset(0, 300));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('WHEELS'), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 6));
    });

    for (final s in sizes) {
      testWidgets('Wheels header with "⌄ Record" fits ${s.width.toInt()}×${s.height.toInt()}', (t) async {
        setSize(t, s);
        await t.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: WheelsPage(
              connected: true,
              linkText: 'connected',
              linkColor: ok,
              robot: null,
              rover: null,
              onCommand: (_) {},
              onArm: () {},
              onStop: () {},
              onControls: () {},
              onSystem: () {},
              onAutonav: () {},
              onRecord: () {},
            ),
          ),
        ));
        expect(find.text('⌄ Record'), findsOneWidget);
        expect(find.text('⌃ Autonav'), findsOneWidget);
      });
    }
  });
}

/// Stands in for the bridge: records the mux modes the app sends.
class FakeClient extends FoxgloveClient {
  final modes = <String>[];

  @override
  void start(String newUrl) {
    url = newUrl;
    link = Link.connected;
    notifyListeners();
  }

  @override
  void stop() {}
  @override
  void stick(double throttle, double steer) {}
  @override
  void watchCamera(bool on) {}
  @override
  void watchNav(bool on) {}
  @override
  void setMode(String mode) => modes.add(mode);
}

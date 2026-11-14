import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:rover_teleop/main.dart';
import 'package:rover_teleop/phone_ctl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for ssh: each run() is a stream the test feeds by hand.
class FakePhoneCtl implements PhoneCtl {
  final verbs = <String>[];
  final runs = <StreamController<String>>[];
  final cancelled = <String>[];
  String? pinned;
  Map<String, List<String>> logs = {};

  StreamController<String> get last => runs.last;

  @override
  Stream<String> run(String verb, {void Function(String host)? onConnected}) {
    verbs.add(verb);
    if (verb.startsWith('log ')) {
      return Stream.fromIterable(logs[verb.substring(4)] ?? const []);
    }
    late final StreamController<String> c;
    c = StreamController<String>(
      onListen: () => onConnected?.call('orintwo.local'),
      onCancel: () => cancelled.add(verb),
    );
    runs.add(c);
    return c.stream;
  }

  void step(String step, String state, {String reason = '', double? t}) =>
      last.add(jsonEncode({'step': step, 'state': state, 'reason': reason, if (t != null) 't': t}));

  Future<void> done(bool ok) async {
    last.add(jsonEncode({'done': true, 'ok': ok}));
    await last.close();
  }

  @override
  Future<String> publicKey() async => 'ssh-ed25519 AAAAC3NzaFAKE rover_teleop-phone';

  @override
  Future<String?> pinnedHostKey() async => pinned;

  @override
  Future<void> trustHostKey(String offered) async => pinned = offered;
}

const sizes = [Size(640, 360), Size(800, 384), Size(915, 412)];

void setSize(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget page(SystemController c) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: SystemPage(ctl: c, onWheels: () {})),
    );

void main() {
  group('keys', () {
    test('phone key: generated once, stored, OpenSSH public key line, signs', () async {
      final store = MemorySecretStore();
      final a = await PhoneKey.load(store);
      final b = await PhoneKey.load(store);
      expect(store.values.keys, [PhoneKey.storeKey]);
      expect(a.authorizedKey, b.authorizedKey);
      final parts = a.authorizedKey.split(' ');
      expect(parts[0], 'ssh-ed25519');
      expect(parts[2], keyComment);
      final blob = base64Decode(parts[1]);
      expect(blob.length, 4 + 11 + 4 + 32); // string "ssh-ed25519", string key
      expect(utf8.decode(blob.sublist(4, 15)), 'ssh-ed25519');
      expect(blob.sublist(19), a.publicKey);

      final data = utf8.encode('exchange hash');
      final sig = a.keyPair.sign(Uint8List.fromList(data)).encode(); // string type, string sig
      expect(
          nacl.VerifyKey(a.publicKey)
              .verify(signature: nacl.Signature(sig.sublist(sig.length - 64)), message: Uint8List.fromList(data)),
          isTrue);

      final other = await PhoneKey.load(MemorySecretStore());
      expect(other.authorizedKey, isNot(a.authorizedKey));
    });

    test('host key pin: first use, trusted, changed', () {
      final fp = HostKeyPin.describe('ssh-ed25519', Uint8List.fromList(List.generate(16, (i) => i)));
      expect(fp, 'ssh-ed25519 MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f');
      expect(HostKeyPin.check(null, fp), PinResult.firstUse);
      expect(HostKeyPin.check(fp, fp), PinResult.trusted);
      expect(HostKeyPin.check(fp, 'ssh-ed25519 MD5:ff'), PinResult.changed);
      expect(HostKeyPin.check(fp, fp.replaceFirst('ed25519', 'rsa')), PinResult.changed);
    });
  });

  group('controller', () {
    test('up: rows follow the stream, done sets the result', () async {
      final f = FakePhoneCtl();
      final c = SystemController(f);
      final finished = c.run('up');
      expect(c.busy, 'up');
      await pumpEventQueue();
      expect(c.ssh, SshState.ok);
      expect(c.host, 'orintwo.local');
      f.step('preflight', 'ok', t: 0.4);
      f.step('wheels', 'running', reason: 'retry 1/3');
      f.last.add('not json'); // ignored
      await pumpEventQueue();
      expect(c.rows['preflight']!.state, 'ok');
      expect(c.rows['preflight']!.t, 0.4);
      expect(c.rows['wheels']!.reason, 'retry 1/3');
      f.step('wheels', 'fail', reason: 'MD80 14 not added', t: 30.2);
      await f.done(false);
      await finished;
      expect(c.busy, isNull);
      expect(c.lastOk, isFalse);
      expect(c.rows['wheels']!.state, 'fail');
      expect(c.rows.keys.toList(), knownSteps);
    });

    test('a step left running when the stream ends turns red', () async {
      final f = FakePhoneCtl();
      final c = SystemController(f);
      final finished = c.run('camera');
      await pumpEventQueue();
      f.step('camera', 'running', reason: 'ZED starting');
      await f.last.close();
      await finished;
      expect(c.rows['camera']!.state, 'fail');
      expect(c.lastOk, isNull);
      expect(c.lastError, 'ended without a result');
    });

    test('only stop goes through while busy, and cancels the running verb', () async {
      final f = FakePhoneCtl();
      final c = SystemController(f);
      unawaited(c.run('up'));
      await pumpEventQueue();
      await c.run('status'); // ignored
      expect(f.verbs, ['up']);
      unawaited(c.run('stop'));
      await pumpEventQueue();
      expect(f.verbs, ['up', 'stop']);
      expect(f.cancelled, ['up']);
      expect(c.busy, 'stop');
    });

    test('errors: unreachable, auth, host key changed, trust', () async {
      final f = FakePhoneCtl();
      final c = SystemController(f);
      var r = c.run('status');
      f.last.addError(SshUnreachable(['orintwo.local', '10.42.0.1']));
      await f.last.close();
      await r;
      expect(c.ssh, SshState.failed);
      expect(c.lastError, contains('not reachable'));

      r = c.run('status');
      f.last.addError(HostKeyChanged('orintwo.local', 'ssh-ed25519 MD5:aa', 'ssh-ed25519 MD5:bb'));
      await f.last.close();
      await r;
      expect(c.ssh, SshState.hostKeyChanged);
      await c.trustNewHostKey();
      expect(f.pinned, 'ssh-ed25519 MD5:bb');
      expect(c.hostKeyChanged, isNull);
    });

    test('zero: unknown steps appended, dropped on the next run', () async {
      final f = FakePhoneCtl();
      final c = SystemController(f);
      var r = c.run('zero 11 14');
      await pumpEventQueue();
      f.step('zero 11', 'ok', t: 6.1);
      await f.done(true);
      await r;
      expect(c.rows.keys.last, 'zero 11');
      r = c.run('status');
      expect(c.rows.containsKey('zero 11'), isFalse);
      await pumpEventQueue();
      await f.done(true);
      await r;
    });

    test('log: plain lines, reasons of JSON lines, no done line', () async {
      final f = FakePhoneCtl()
        ..logs['wheels'] = [
          '[INFO] MD80 11 added',
          jsonEncode({'step': 'log', 'state': 'fail', 'reason': 'no /tmp/wheels.log'}),
          jsonEncode({'done': true, 'ok': true}),
        ];
      final c = SystemController(f);
      expect(await c.log('wheels'), ['[INFO] MD80 11 added', 'no /tmp/wheels.log']);
    });
  });

  group('page', () {
    for (final s in sizes) {
      testWidgets('lays out without overflow at ${s.width.toInt()}x${s.height.toInt()}', (t) async {
        setSize(t, s);
        final f = FakePhoneCtl();
        final c = SystemController(f);
        await t.pumpWidget(page(c));
        expect(t.takeException(), isNull);
        unawaited(c.run('up'));
        await t.pump();
        f.step('preflight', 'warn', reason: '/ at 97 %, clean up soon', t: 0.4);
        f.step('teleop', 'ok', t: 3.1);
        f.step('rover_link', 'ok', t: 0.2);
        f.step('wheels', 'fail', reason: 'Failed to add MD80 with ID: 14 after 3 tries, see log wheels', t: 41);
        f.last.addError(HostKeyChanged('orintwo.local', 'ssh-ed25519 MD5:aa', 'ssh-ed25519 MD5:bb'));
        await f.done(false);
        await t.pump();
        expect(t.takeException(), isNull);
        expect(find.textContaining('DIFFERENT HOST KEY'), findsOneWidget);
      });
    }

    testWidgets('buttons send the #27 verbs; STOP stays on while a verb runs', (t) async {
      setSize(t, sizes[1]);
      final f = FakePhoneCtl();
      final c = SystemController(f);
      await t.pumpWidget(page(c));
      expect(find.text('ssh idle'), findsOneWidget);

      await t.tap(find.text('UP'));
      await t.pump();
      expect(f.verbs, ['up']);
      expect(find.text('ssh ok'), findsOneWidget);
      expect(find.text('UP …'), findsOneWidget);
      await t.tap(find.text('Status')); // off while up runs
      expect(f.verbs, ['up']);

      f.step('preflight', 'ok', t: 0.4);
      f.step('wheels', 'running', reason: 'retry 1/3');
      await t.pump();
      expect(find.text('✓'), findsOneWidget);
      expect(find.text('0.4 s'), findsOneWidget);
      expect(find.text('(retry 1/3)'), findsOneWidget);
      expect(find.text('(separate)'), findsOneWidget); // camera, not run

      await t.tap(find.text('STOP'));
      await t.pump();
      expect(f.verbs, ['up', 'stop']);
      expect(f.cancelled, ['up']);
      await f.done(true);
      await t.pump();
      expect(find.text('stop: ok'), findsOneWidget);

      for (final v in ['Camera on', 'Status']) {
        await t.tap(find.text(v));
        await t.pump();
        await f.done(true);
        await t.pump();
      }
      expect(f.verbs, ['up', 'stop', 'camera', 'status']);
    });

    testWidgets('failed step shows the reason in red; long-press opens its log', (t) async {
      setSize(t, sizes[1]);
      final f = FakePhoneCtl()..logs['wheels'] = ['line one', 'line two'];
      final c = SystemController(f);
      await t.pumpWidget(page(c));
      unawaited(c.run('up'));
      await t.pump();
      f.step('wheels', 'fail', reason: 'MD80 14 not added');
      await f.done(false);
      await t.pump();
      expect(find.text('✗'), findsOneWidget);
      final reason = t.widget<Text>(find.text('MD80 14 not added'));
      expect(reason.style!.color, bad);
      expect(find.text('up: failed'), findsOneWidget);

      await t.longPress(find.text('wheels'));
      await t.pumpAndSettle();
      expect(f.verbs.last, 'log wheels');
      expect(find.text('line one\nline two'), findsOneWidget);
    });

    testWidgets('recenter: none ticked, confirm lists the ids, sends zero, shows steps', (t) async {
      setSize(t, sizes[1]);
      final f = FakePhoneCtl();
      final c = SystemController(f);
      await t.pumpWidget(page(c));
      await t.tap(find.text('Recenter wheels…'));
      await t.pumpAndSettle();
      expect(find.textContaining('go limp'), findsOneWidget);
      final boxes = t.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(boxes.map((b) => (b.title as Text).data), ['FL 11', 'FR 12', 'RL 13', 'RR 14']);
      expect(boxes.every((b) => b.value == false), isTrue);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Tick a wheel')).onPressed, isNull);

      await t.tap(find.text('RR 14'));
      await t.tap(find.text('FL 11'));
      await t.pump();
      await t.tap(find.text('Zero FL 11, RR 14'));
      await t.pump();
      expect(f.verbs, ['zero 11 14']);
      f.step('wheels_stop', 'ok', t: 1.0);
      f.step('zero 11', 'running');
      await t.pump();
      expect(find.text('zero 11'), findsWidgets);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Close')).onPressed, isNull);
      f.step('zero 11', 'ok', t: 6.0);
      await f.done(true);
      await t.pump();
      expect(find.text('done: ok'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.byType(RecenterDialog), findsNothing);
    });

    testWidgets('show public key: copy / share', (t) async {
      setSize(t, sizes[1]);
      final c = SystemController(FakePhoneCtl()..pinned = 'ssh-ed25519 MD5:aa');
      await t.pumpWidget(page(c));
      await t.tap(find.text('Show public key'));
      await t.pumpAndSettle();
      expect(find.text('ssh-ed25519 AAAAC3NzaFAKE rover_teleop-phone'), findsOneWidget);
      expect(find.textContaining('MD5:aa'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });
  });

  testWidgets('page order: Controls first, Wheels right of it, System right of Wheels', (t) async {
    setSize(t, sizes[1]);
    SharedPreferences.setMockInitialValues({'host': '127.0.0.1'});
    await t.pumpWidget(MaterialApp(home: TeleopPage(phoneCtl: FakePhoneCtl())));
    await t.pump();
    expect(find.text('Camera ›'), findsOneWidget);

    await t.dragFrom(const Offset(200, 120), const Offset(500, 0));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('WHEELS'), findsOneWidget);

    await t.tap(find.text('‹ System'));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('SYSTEM'), findsOneWidget);

    // a drag starting on a button doesn't turn the page
    await t.drag(find.text('Status'), const Offset(-500, 0));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('SYSTEM'), findsOneWidget);

    await t.tap(find.text('Wheels ›'));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('WHEELS'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });
}

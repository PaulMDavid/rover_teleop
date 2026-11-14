// System page backend: ssh to orintwo with the phone's own ed25519 key and run one
// phone_ctl.sh verb per connection (navigation_ws #27). orintwo's authorized_keys entry
// pins the key to phone_ctl.sh, which takes the verb from SSH_ORIGINAL_COMMAND: `up`,
// `stop`, `status`, `camera`, `zero <ids>`, `log <step>`. It streams one JSON object per
// line: {"step": "wheels", "state": "running|ok|fail|warn|skipped", "reason": "...",
// "t": 12.3}, then {"done": true, "ok": true}.
//
// The key is generated on the phone on first use and kept in Android secure storage
// (Keystore-backed). orintwo's host key is trusted on first use and pinned for orintwo
// itself, whatever address reached it (mDNS name, typed IP, access point): a different
// key refuses the connection until the user accepts it.
import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

const sshUser = 'orintwo';
const sshDefaultHost = 'orintwo.local';
const sshPort = 22;
const keyComment = 'rover_teleop-phone';

/// The 4 steering MD80s: label → CAN id (#27: `zero` accepts only these).
const wheelIds = {'FL': 11, 'FR': 12, 'RL': 13, 'RR': 14};

/// Steps `up` runs, in order; `camera` is its own verb. Shown before anything ran.
const knownSteps = ['preflight', 'teleop', 'rover_link', 'wheels', 'camera'];

// ---------------------------------------------------------------------------------------
// Errors the ssh layer reports (the UI words them).

class SshUnreachable implements Exception {
  SshUnreachable(this.hosts);
  final List<String> hosts;
  @override
  String toString() => 'orintwo not reachable (${hosts.join(', ')})';
}

class SshAuthFailed implements Exception {
  SshAuthFailed(this.host);
  final String host;
  @override
  String toString() => '$host refused the phone\'s key: install it with phone_link.sh';
}

class HostKeyChanged implements Exception {
  HostKeyChanged(this.host, this.pinned, this.offered);
  final String host;
  final String pinned, offered; // "<type> MD5:aa:bb:…"
  @override
  String toString() => 'orintwo\'s host key changed ($host)';
}

class SshCommandFailed implements Exception {
  SshCommandFailed(this.exitCode, this.stderr);
  final int? exitCode;
  final String stderr;
  @override
  String toString() => 'phone_ctl.sh exited ${exitCode ?? '?'}${stderr.isEmpty ? '' : ': $stderr'}';
}

// ---------------------------------------------------------------------------------------
// Storage, key, host key pin: small pieces the tests use directly.

/// Where the private key and the pinned host key live. Android: FlutterSecureStorage.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureSecretStore implements SecretStore {
  // EncryptedSharedPreferences: AES key wrapped by the Android Keystore
  static const _s = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// The phone's ed25519 identity, from its 32-byte seed.
class PhoneKey {
  PhoneKey.fromSeed(Uint8List seed) : _sk = nacl.SigningKey.fromSeed(seed);

  static const storeKey = 'ssh_ed25519_seed';

  final nacl.SigningKey _sk;

  /// Loads the key, generating and storing one on first use.
  static Future<PhoneKey> load(SecretStore store) async {
    final stored = await store.read(storeKey);
    if (stored != null) return PhoneKey.fromSeed(base64Decode(stored));
    final seed = Uint8List.fromList(nacl.SigningKey.generate().seed.asTypedList);
    await store.write(storeKey, base64Encode(seed));
    return PhoneKey.fromSeed(seed);
  }

  Uint8List get publicKey => Uint8List.fromList(_sk.verifyKey.asTypedList);

  OpenSSHEd25519KeyPair get keyPair =>
      OpenSSHEd25519KeyPair(publicKey, Uint8List.fromList(_sk.asTypedList), keyComment);

  /// The authorized_keys line: `ssh-ed25519 AAAA… rover_teleop-phone`.
  String get authorizedKey => 'ssh-ed25519 ${base64Encode(keyPair.toPublicKey().encode())} $keyComment';
}

enum PinResult { trusted, firstUse, changed }

/// orintwo's host key, pinned on first use. dartssh2 hands over the key type and the MD5
/// of the key blob (compare with `ssh-keygen -l -E md5 -f /etc/ssh/ssh_host_*_key.pub`).
class HostKeyPin {
  static const storeKey = 'orintwo_host_key';

  static String describe(String type, Uint8List md5) =>
      '$type MD5:${md5.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}';

  static PinResult check(String? pinned, String offered) => pinned == null
      ? PinResult.firstUse
      : pinned == offered
          ? PinResult.trusted
          : PinResult.changed;
}

// ---------------------------------------------------------------------------------------
// The ssh layer, behind an interface so the widget tests can fake it.

abstract class PhoneCtl {
  /// Runs one phone_ctl.sh verb; stdout lines as they arrive. Errors: [SshUnreachable],
  /// [SshAuthFailed], [HostKeyChanged], [SshCommandFailed]. Cancelling the subscription
  /// closes the connection. [onConnected] gets the address that answered.
  Stream<String> run(String verb, {void Function(String host)? onConnected});

  Future<String> publicKey();

  /// The pinned host key ("<type> MD5:…"), null before the first connection.
  Future<String?> pinnedHostKey();

  /// After a [HostKeyChanged], when the user accepts the new key.
  Future<void> trustHostKey(String offered);
}

class SshPhoneCtl implements PhoneCtl {
  SshPhoneCtl({required this.hosts, SecretStore? store}) : store = store ?? SecureSecretStore();

  /// Addresses to try, in order (orintwo.local, typed IP, the WebSocket host).
  final List<String> Function() hosts;
  final SecretStore store;
  PhoneKey? _key;

  Future<PhoneKey> _phoneKey() async => _key ??= await PhoneKey.load(store);

  @override
  Future<String> publicKey() async => (await _phoneKey()).authorizedKey;

  @override
  Future<String?> pinnedHostKey() => store.read(HostKeyPin.storeKey);

  @override
  Future<void> trustHostKey(String offered) => store.write(HostKeyPin.storeKey, offered);

  @override
  Stream<String> run(String verb, {void Function(String host)? onConnected}) {
    SSHClient? client;
    var cancelled = false;
    late final StreamController<String> out;
    out = StreamController<String>(onCancel: () {
      cancelled = true;
      client?.close();
    });

    Future<void> go() async {
      final key = await _phoneKey();
      final tried = <String>[];
      for (final host in hosts()) {
        if (cancelled) return;
        tried.add(host);
        SSHSocket socket;
        try {
          socket = await SSHSocket.connect(host, sshPort, timeout: const Duration(seconds: 4));
        } catch (_) {
          continue; // name doesn't resolve / nothing listening: next address
        }
        HostKeyChanged? changed;
        final c = client = SSHClient(
          socket,
          username: sshUser,
          identities: [key.keyPair],
          onVerifyHostKey: (type, md5) async {
            final offered = HostKeyPin.describe(type, md5);
            final pinned = await store.read(HostKeyPin.storeKey);
            switch (HostKeyPin.check(pinned, offered)) {
              case PinResult.trusted:
                return true;
              case PinResult.firstUse:
                await store.write(HostKeyPin.storeKey, offered);
                return true;
              case PinResult.changed:
                changed = HostKeyChanged(host, pinned!, offered);
                return false;
            }
          },
        );
        try {
          await c.authenticated;
        } catch (e) {
          c.close();
          if (changed != null) throw changed!; // never fall through to another address
          if (e is SSHAuthFailError) throw SshAuthFailed(host);
          continue;
        }
        if (cancelled) return c.close();
        onConnected?.call(host);
        final session = await c.execute(verb);
        final stderr = StringBuffer();
        final errDone = session.stderr.cast<List<int>>().transform(utf8.decoder).forEach(stderr.write);
        await session.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((l) => cancelled ? null : out.add(l));
        await session.done;
        await errDone.catchError((_) {});
        c.close();
        final code = session.exitCode;
        if (code != null && code != 0) throw SshCommandFailed(code, stderr.toString().trim().split('\n').last);
        return;
      }
      throw SshUnreachable(tried);
    }

    go().catchError((Object e) {
      if (!cancelled) out.addError(e);
    }).whenComplete(() {
      if (!out.isClosed) out.close();
    });
    return out.stream;
  }
}

// ---------------------------------------------------------------------------------------
// What the System page shows.

class StepRow {
  StepRow(this.step);
  final String step;
  String state = 'idle'; // idle | running | ok | fail | warn | skipped
  String reason = '';
  double? t;
  int run = 0; // which run last updated it; older rows are shown dimmed
}

enum SshState { idle, connecting, ok, failed, hostKeyChanged }

class SystemController extends ChangeNotifier {
  SystemController(this.ctl) {
    for (final s in knownSteps) {
      rows[s] = StepRow(s);
    }
  }

  final PhoneCtl ctl;
  final rows = <String, StepRow>{}; // insertion order = display order

  int runId = 0;
  String? busy; // verb running now
  String? lastVerb;
  bool? lastOk; // from the {"done": …} line; null = ended without one
  String? lastError;
  SshState ssh = SshState.idle;
  String? host; // the address that answered last
  HostKeyChanged? hostKeyChanged;

  StreamSubscription<String>? _sub;
  Completer<void>? _finished;

  /// Starts a verb. While one runs, only `stop` goes through: it cancels the running one
  /// (a second `stop` while one runs is dropped).
  Future<void> run(String verb) async {
    if (busy != null) {
      if (verb != 'stop' || busy == 'stop') return;
      // not awaited: closing the ssh client happens in onCancel, synchronously
      unawaited(_sub?.cancel());
      _end();
    }
    final id = ++runId;
    busy = verb;
    lastVerb = verb;
    lastOk = null;
    lastError = null;
    if (ssh != SshState.hostKeyChanged) ssh = SshState.connecting;
    rows.removeWhere((k, r) => !knownSteps.contains(k) && r.run < id);
    notifyListeners();

    final finished = _finished = Completer<void>();
    _sub = ctl.run(verb, onConnected: (h) {
      if (id != runId) return;
      host = h;
      ssh = SshState.ok;
      hostKeyChanged = null;
      notifyListeners();
    }).listen(
      (l) => _onLine(id, l),
      onError: (Object e) {
        if (id != runId) return;
        if (e is HostKeyChanged) {
          hostKeyChanged = e;
          ssh = SshState.hostKeyChanged;
        } else if (e is SshCommandFailed) {
          // the script ran: the ssh link itself was fine
          if (lastOk == null) lastError = e.toString();
        } else {
          ssh = SshState.failed;
          lastError = e.toString();
        }
        notifyListeners();
      },
      onDone: () {
        if (id == runId) _end();
      },
    );
    return finished.future;
  }

  void _end() {
    busy = null;
    _sub = null;
    final f = _finished;
    _finished = null;
    // steps still "running" when the stream ended never finished
    for (final r in rows.values) {
      if (r.run == runId && r.state == 'running') {
        r.state = 'fail';
        if (r.reason.isEmpty) r.reason = 'no result';
      }
    }
    if (lastOk == null && lastError == null && ssh == SshState.ok) lastError = 'ended without a result';
    notifyListeners();
    f?.complete();
  }

  void _onLine(int id, String line) {
    if (id != runId) return;
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return; // not a status line
    }
    if (j['done'] == true) {
      lastOk = j['ok'] == true;
      if (j['reason'] is String && (j['reason'] as String).isNotEmpty && lastOk == false) {
        lastError = j['reason'] as String;
      }
    } else if (j['step'] is String) {
      final r = rows.putIfAbsent(j['step'] as String, () => StepRow(j['step'] as String));
      if (r.run != id) {
        r.reason = '';
        r.t = null;
      }
      r
        ..run = id
        ..state = (j['state'] as String?) ?? r.state
        ..reason = (j['reason'] as String?) ?? r.reason
        ..t = (j['t'] as num?)?.toDouble() ?? r.t;
    } else {
      return;
    }
    notifyListeners();
  }

  /// `log <step>`: its own connection, doesn't touch the rows; allowed while a verb runs.
  /// Plain lines as they are; JSON lines by their reason.
  Future<List<String>> log(String step) async {
    final lines = <String>[];
    try {
      await for (final l in ctl.run('log $step')) {
        try {
          final j = jsonDecode(l);
          if (j is Map && j['done'] == true) continue;
          if (j is Map && j['reason'] is String && (j['reason'] as String).isNotEmpty) {
            lines.add(j['reason'] as String);
            continue;
          }
        } catch (_) {}
        lines.add(l);
      }
    } catch (e) {
      lines.add('⚠ $e');
    }
    return lines;
  }

  Future<void> trustNewHostKey() async {
    final c = hostKeyChanged;
    if (c == null) return;
    await ctl.trustHostKey(c.offered);
    hostKeyChanged = null;
    ssh = SshState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

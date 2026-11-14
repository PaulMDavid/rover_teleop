// Record page backend (navigation_ws #29): `phone_ctl.sh record …` over the System page's
// ssh layer (same key, host order, host-key pin, same forced command). Contract: section
// "Recording from the phone" in navigation_ws src/app_teleop/README.md:
//
//   record presets                      groups, presets (one is "default"), quiet_ok
//   record topics                       every live topic: type, hz, mbps (≈ 8–10 s)
//   record start <preset> [+/t] [-/t]   preflight → sensors → record
//   record status [once]                a status line every ~2 s; ends after 1 h, when the
//                                       recording ends, or at once when not recording
//   record stop                         SIGINT, wait for the bag to close, report it
//
// One JSON object per line {"step", "state", "reason", "t", …}, last {"done": true, "ok"}.
// Exit 0 ok, 1 failed, 64 refused, 75 busy. MB = 10⁶ B, GB = 10⁹ B.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'phone_ctl.dart';

/// Characters phone_ctl.sh accepts in a record command (commas = spaces).
final recordCommandChars = RegExp(r'^[A-Za-z0-9_/+ ,-]*$');

/// A ROS topic name the app may put on a `record start` line.
final topicName = RegExp(r'^/[A-Za-z0-9_/]+$');

class RecGroup {
  RecGroup(this.name, this.label, this.topics);
  final String name, label;
  final List<String> topics;
}

class RecPreset {
  RecPreset(this.name, this.label, this.isDefault, this.groups, this.topics);
  final String name, label;
  final bool isDefault;
  final List<String> groups;
  final List<String> topics; // its groups' topics, in order, deduplicated
}

class RecTopic {
  RecTopic(this.name, this.type, this.hz, this.mbps);
  final String name, type;
  final double? hz, mbps; // null: app_teleop's image can't load the type

  static RecTopic? fromJson(Object? j) {
    if (j is! Map || j['name'] is! String) return null;
    return RecTopic(j['name'] as String, (j['type'] as String?) ?? '', _d(j['hz']), _d(j['mbps']));
  }
}

/// One `record status` line.
class RecStatus {
  RecStatus(this.j);
  final Map<String, dynamic> j;

  bool get recording => j['recording'] == true;
  String? get bag => j['bag'] as String?;
  String? get preset => j['preset'] as String?;
  int? get elapsedS => (j['elapsed_s'] as num?)?.round();
  double? get sizeMb => _d(j['size_mb']);
  double? get rateMbps => _d(j['rate_mbps']);
  double? get inputMbps => _d(j['input_mbps']);
  double? get freeGb => _d(j['free_gb']);
  double? get leftH => _d(j['left_h']);
  int get topics => (j['topics'] as num?)?.toInt() ?? 0;

  /// null = no verdict yet (watcher younger than 8 s, or its file older than 5 s).
  List<String>? get silent => _strings(j['silent']);
  List<String> get unwatched => _strings(j['unwatched']) ?? const [];
  List<String> get unclosed => _strings(j['unclosed']) ?? const [];
  String get reason => (j['reason'] as String?) ?? '';
}

double? _d(Object? v) => v is num ? v.toDouble() : null;
List<String>? _strings(Object? v) => v is List ? v.whereType<String>().toList() : null;

/// What a start/stop/presets/topics run ended with, worded for the page.
class RecOutcome {
  RecOutcome(this.text, this.level);
  final String text;
  final String level; // ok | warn | fail | busy | refused
}

class RecordController extends ChangeNotifier {
  RecordController(this.ctl, {this.retryDelay = const Duration(seconds: 5)});

  final PhoneCtl ctl;

  /// Wait before re-attaching `record status` after an ssh error (or a stream that ended
  /// right away while still recording).
  final Duration retryDelay;

  // presets
  final groups = <RecGroup>[];
  final presets = <RecPreset>[];
  final quietOk = <String>{};
  bool presetsLoading = false;
  RecOutcome? presetsError;

  // selection: a preset plus differences, as `record start` takes them
  String? preset;
  final selected = <String>{}; // insertion order: preset topics first, then the added ones

  // record topics
  List<RecTopic>? topics;
  bool topicsLoading = false;
  RecOutcome? topicsError;

  // record start / stop
  String? op; // 'start' | 'stop' while it runs
  String? opLine; // its newest reason
  RecOutcome? outcome; // how the last start/stop ended

  // record status
  RecStatus? status;
  bool attached = false; // a `record status` stream is open
  String? statusError;
  bool visible = false;

  StreamSubscription<String>? _statusSub;
  Timer? _retry;
  bool _disposed = false;

  RecPreset? get currentPreset => _preset(preset);
  RecPreset? _preset(String? name) => presets.where((p) => p.name == name).firstOrNull;
  bool get recording => status?.recording == true;
  bool get canEdit => op == null && !recording && currentPreset != null;
  bool get canStart => canEdit && selected.isNotEmpty;

  /// Unknown or recording: stop is idempotent, so it may go out when in doubt.
  bool get canStop => op == null && status?.recording != false;

  // ---------------------------------------------------------------------------------
  // page visibility: status runs only while the page shows

  void setVisible(bool v) {
    if (v == visible) return;
    visible = v;
    if (v) {
      if (presets.isEmpty && !presetsLoading) loadPresets();
      attach();
    } else {
      _detach();
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------
  // presets + selection

  Future<void> loadPresets() async {
    presetsLoading = true;
    presetsError = null;
    notifyListeners();
    final g = <RecGroup>[], p = <RecPreset>[], q = <String>{};
    final r = await _collect('record presets', (j) {
      final group = j['group'], pr = j['preset'];
      if (group is Map && group['name'] is String) {
        g.add(RecGroup(group['name'] as String, (group['label'] as String?) ?? group['name'] as String,
            _strings(group['topics']) ?? const []));
      } else if (pr is Map && pr['name'] is String) {
        p.add(RecPreset(pr['name'] as String, (pr['label'] as String?) ?? pr['name'] as String, pr['default'] == true,
            _strings(pr['groups']) ?? const [], _strings(pr['topics']) ?? const []));
      } else if (j['quiet_ok'] is List) {
        q.addAll(_strings(j['quiet_ok'])!);
      }
    });
    if (_disposed) return;
    presetsLoading = false;
    if (r.level != 'ok' || p.isEmpty) {
      presetsError = r.level != 'ok' ? r : RecOutcome('no presets from orintwo', 'fail');
    } else {
      groups
        ..clear()
        ..addAll(g);
      presets
        ..clear()
        ..addAll(p);
      quietOk
        ..clear()
        ..addAll(q);
      if (_preset(preset) == null) {
        selectPreset((p.where((x) => x.isDefault).firstOrNull ?? p.first).name);
      }
    }
    notifyListeners();
  }

  /// Picks a preset; the selection goes back to its topics.
  void selectPreset(String name) {
    final p = _preset(name);
    if (p == null) return;
    preset = name;
    selected
      ..clear()
      ..addAll(p.topics);
    notifyListeners();
  }

  /// true = all its topics selected, false = none, null = some.
  bool? groupState(RecGroup g) {
    final n = g.topics.where(selected.contains).length;
    return n == 0 ? false : (n == g.topics.length ? true : null);
  }

  void setGroup(RecGroup g, bool on) {
    if (on) {
      selected.addAll(g.topics);
    } else {
      selected.removeAll(g.topics);
    }
    notifyListeners();
  }

  void setTopic(String t, bool on) {
    if (on) {
      selected.add(t);
    } else {
      selected.remove(t);
    }
    notifyListeners();
  }

  /// Selected topics in no group (added from the full list).
  List<String> get extraTopics {
    final grouped = {for (final g in groups) ...g.topics};
    return selected.where((t) => !grouped.contains(t)).toList();
  }

  /// `+/t` for topics the preset doesn't have, `-/t` for its topics left out.
  List<String> get diff {
    final p = currentPreset;
    if (p == null) return const [];
    final inPreset = p.topics.toSet();
    return [
      for (final t in selected)
        if (!inPreset.contains(t)) '+$t',
      for (final t in p.topics)
        if (!selected.contains(t)) '-$t',
    ];
  }

  String? get startCommand {
    final p = currentPreset;
    if (p == null) return null;
    return ['record', 'start', p.name, ...diff].join(' ');
  }

  // ---------------------------------------------------------------------------------
  // record topics

  Future<void> loadTopics() async {
    if (topicsLoading) return;
    topicsLoading = true;
    topicsError = null;
    notifyListeners();
    final list = <RecTopic>[];
    final r = await _collect('record topics', (j) {
      final t = RecTopic.fromJson(j['topic']);
      if (t != null) list.add(t);
    }, progress: (_) {});
    if (_disposed) return;
    topicsLoading = false;
    if (r.level == 'ok') {
      topics = list;
    } else {
      topicsError = r;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------
  // record start / stop

  Future<void> start() async {
    final cmd = startCommand;
    if (!canStart || cmd == null) return;
    if (!recordCommandChars.hasMatch(cmd)) {
      outcome = RecOutcome('topic names with characters phone_ctl.sh refuses', 'refused');
      notifyListeners();
      return;
    }
    await _op('start', cmd, (j) {
      if (j['step'] == 'record' && j['state'] == 'ok') return RecOutcome(j['reason'] as String? ?? 'recording', 'ok');
      return null;
    });
  }

  Future<void> stop() => _op('stop', 'record stop', (j) {
        if (j['step'] == 'stop' && j['state'] == 'ok') return RecOutcome(j['reason'] as String? ?? 'stopped', 'ok');
        return null;
      });

  Future<void> _op(String name, String cmd, RecOutcome? Function(Map<String, dynamic>) result) async {
    if (op != null) return;
    op = name;
    opLine = null;
    outcome = null;
    notifyListeners();
    RecOutcome? good;
    final warns = <String>[];
    final r = await _collect(cmd, (j) {
      good = result(j) ?? good;
      if (j['state'] == 'warn' && j['reason'] is String) warns.add(j['reason'] as String);
    }, progress: (reason) {
      opLine = reason;
      notifyListeners();
    });
    if (_disposed) return;
    op = null;
    opLine = null;
    if (r.level == 'ok' && good != null) {
      // start: recording anyway with silent sensors → amber, with the sensors' words
      outcome = warns.isEmpty ? good : RecOutcome('${good!.text} — ${warns.join('; ')}', 'warn');
    } else {
      outcome = r.level == 'ok' ? RecOutcome('$name: ended without a result', 'fail') : r;
    }
    notifyListeners();
    // the status stream ends when nothing records: a new one shows the new state
    if (visible) attach();
  }

  // ---------------------------------------------------------------------------------
  // record status

  /// Opens `record status` unless one is open. The last status (and error) stays shown
  /// until the new stream says otherwise.
  void attach() {
    if (_disposed || _statusSub != null) return;
    _retry?.cancel();
    attached = true;
    final opened = DateTime.now();
    var gotLine = false;
    String? failReason, err;
    notifyListeners();
    _statusSub = ctl.run('record status').listen((l) {
      final j = _json(l);
      if (j == null) return;
      if (j['step'] == 'status') {
        gotLine = true;
        status = RecStatus(j);
        statusError = null;
        notifyListeners();
      } else if (j['state'] == 'fail' && j['reason'] is String) {
        failReason = j['reason'] as String;
      }
    }, onError: (Object e) {
      err = _errorText(e, failReason);
    }, onDone: () {
      _statusSub = null;
      attached = false;
      err ??= failReason;
      if (err != null) statusError = err;
      notifyListeners();
      if (!visible || _disposed) return;
      if (err != null) {
        // ssh trouble: keep trying while the page shows (a refusal won't change by itself)
        if (!err!.startsWith('refused')) _retry = Timer(retryDelay, attach);
      } else if (gotLine && recording) {
        // ended after 1 h (or ssh dropped): re-attach; right away unless it ended at once
        final quick = DateTime.now().difference(opened) < const Duration(seconds: 5);
        _retry = Timer(quick ? retryDelay : Duration.zero, attach);
      }
    });
  }

  void _detach() {
    _retry?.cancel();
    _retry = null;
    final s = _statusSub;
    _statusSub = null;
    attached = false;
    unawaited(s?.cancel()); // closes the ssh connection
  }

  // ---------------------------------------------------------------------------------

  /// Runs one verb to its end. Lines with a `step` go to [onLine]; running lines' reasons
  /// to [progress]. Returns ok, or how it failed (busy / refused / fail, with the reason).
  Future<RecOutcome> _collect(String cmd, void Function(Map<String, dynamic>) onLine,
      {void Function(String reason)? progress}) async {
    bool? doneOk;
    String? failReason;
    try {
      await for (final l in ctl.run(cmd)) {
        final j = _json(l);
        if (j == null) continue;
        if (j['done'] == true) {
          doneOk = j['ok'] == true;
          continue;
        }
        if (j['state'] == 'fail' && j['reason'] is String) failReason ??= '${j['reason']}';
        if (j['state'] == 'running' && j['reason'] is String) progress?.call(j['reason'] as String);
        onLine(j);
      }
    } catch (e) {
      final text = _errorText(e, failReason);
      return RecOutcome(text, _level(e, text));
    }
    if (doneOk == true) return RecOutcome('ok', 'ok');
    final text = failReason ?? (doneOk == false ? 'failed' : 'ended without a result');
    return RecOutcome(text, _level(null, text));
  }

  static String _level(Object? e, String text) {
    final code = e is SshCommandFailed ? e.exitCode : null;
    if (code == 75 || text.startsWith('busy')) return 'busy';
    if (code == 64 || text.startsWith('refused')) return 'refused';
    return 'fail';
  }

  static String _errorText(Object e, String? failReason) {
    if (e is SshCommandFailed && failReason != null) return failReason; // the script said why
    if (e is HostKeyChanged) return 'orintwo\'s host key changed: check and accept it on the System page';
    return e.toString();
  }

  static Map<String, dynamic>? _json(String l) {
    try {
      final j = jsonDecode(l);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _detach();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------------------
// Formatting (units per the contract: MB = 10⁶ B, GB = 10⁹ B).

String fmtElapsed(int? s) {
  if (s == null) return '--:--:--';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
}

String fmtSize(double? mb) {
  if (mb == null) return '—';
  if (mb >= 1000) return '${(mb / 1000).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
}

String fmtRate(double? mbps) => mbps == null ? '— MB/s' : '${mbps.toStringAsFixed(mbps >= 10 ? 1 : 2)} MB/s';

String fmtLeft(double? h) {
  if (h == null) return '—';
  if (h < 1) return '${(h * 60).round()} min';
  return '${h.toStringAsFixed(h >= 10 ? 0 : 1)} h';
}

String fmtHz(double? hz) => hz == null ? '?' : (hz >= 10 ? hz.toStringAsFixed(0) : hz.toStringAsFixed(1));

String fmtMbps(double? v) => v == null ? '?' : (v >= 1 ? v.toStringAsFixed(1) : v.toStringAsFixed(3));

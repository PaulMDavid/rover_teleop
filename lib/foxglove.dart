// Foxglove WebSocket client (subprotocol foxglove.sdk.v1) for app_foxglove_bridge.
// Publishes JSON-encoded /teleop/phone/cmd_vel and /teleop/phone/set_mode, and
// subscribes /teleop/state: the mode the robot is actually in.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// What teleop_mux reports on /teleop/state.
class RobotState {
  RobotState(this.json) : receivedAt = DateTime.now();

  final Map<String, dynamic> json;
  final DateTime receivedAt;

  String get mode => json['mode'] as String;
  String get modeBy => json['mode_by'] as String;
  String get source => json['source'] as String;
  double? get phoneAge => (json['teleop_age']['phone'] as num?)?.toDouble();
  double get teleopTimeout => (json['teleop_timeout'] as num).toDouble();
  double get maxLinear => (json['max_linear'] as num).toDouble();
  double get maxAngular => (json['max_angular'] as num).toDouble();

  bool get fresh => DateTime.now().difference(receivedAt) < const Duration(seconds: 1);
  bool get hearsPhone => phoneAge != null && phoneAge! < teleopTimeout;
}

enum Link { disconnected, connecting, connected }

class FoxgloveClient extends ChangeNotifier {
  static const _chCmd = 1, _chMode = 2, _subState = 1;

  Link link = Link.disconnected;
  RobotState? state;
  String url = '';

  WebSocket? _ws;
  bool _running = false;
  Timer? _retry;
  int _generation = 0; // bumped by stop(): late results of older attempts are dropped

  void start(String newUrl) {
    url = newUrl;
    _running = true;
    _connect();
  }

  void stop() {
    _generation++;
    _running = false;
    _retry?.cancel();
    _ws?.close();
    _ws = null;
    _setLink(Link.disconnected);
  }

  Future<void> _connect() async {
    if (!_running || _ws != null) return;
    final generation = _generation;
    _setLink(Link.connecting);
    try {
      final ws = await WebSocket.connect(url, protocols: ['foxglove.sdk.v1'])
          .timeout(const Duration(seconds: 3));
      if (generation != _generation) {
        ws.close();
        return;
      }
      // a dead Wi-Fi link shows in the UI within a few seconds instead of minutes
      ws.pingInterval = const Duration(seconds: 1);
      _ws = ws;
      _setLink(Link.connected);
      ws.listen(_onMessage,
          onDone: () => _onClosed(generation), onError: (_) => _onClosed(generation), cancelOnError: true);
    } catch (_) {
      _onClosed(generation);
    }
  }

  void _onClosed(int generation) {
    if (generation != _generation) return;
    _ws = null;
    _setLink(Link.disconnected);
    if (_running) {
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 1), _connect);
    }
  }

  void _setLink(Link l) {
    if (l == link) return;
    link = l;
    notifyListeners();
  }

  void _send(Map<String, dynamic> obj) => _ws?.add(jsonEncode(obj));

  void _onMessage(dynamic data) {
    if (data is String) {
      final msg = jsonDecode(data) as Map<String, dynamic>;
      switch (msg['op']) {
        case 'serverInfo':
          _send({
            'op': 'advertise',
            'channels': [
              {'id': _chCmd, 'topic': '/teleop/phone/cmd_vel', 'encoding': 'json',
               'schemaName': 'geometry_msgs/msg/Twist'},
              {'id': _chMode, 'topic': '/teleop/phone/set_mode', 'encoding': 'json',
               'schemaName': 'std_msgs/msg/String'},
            ],
          });
        case 'advertise':
          for (final c in msg['channels'] as List) {
            if (c['topic'] == '/teleop/state') {
              _send({'op': 'subscribe', 'subscriptions': [{'id': _subState, 'channelId': c['id']}]});
            }
          }
      }
      return;
    }
    // messageData: op(1) subscriptionId(u32) timestamp(u64) payload; the payload is
    // std_msgs/String in CDR: 4-byte encapsulation header, u32 length incl. NUL, bytes
    final b = data as Uint8List;
    final v = ByteData.sublistView(b);
    if (b.length < 21 || v.getUint8(0) != 1 || v.getUint32(1, Endian.little) != _subState) return;
    final len = v.getUint32(17, Endian.little);
    try {
      state = RobotState(jsonDecode(utf8.decode(b.sublist(21, 21 + len - 1))) as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {}
  }

  void _publish(int channel, Map<String, dynamic> obj) {
    final ws = _ws;
    if (ws == null) return;
    final header = ByteData(5)
      ..setUint8(0, 1) // clientMessageData
      ..setUint32(1, channel, Endian.little);
    ws.add(Uint8List.fromList([...header.buffer.asUint8List(), ...utf8.encode(jsonEncode(obj))]));
  }

  void drive(double vx, double wz) => _publish(_chCmd, {
        'linear': {'x': vx, 'y': 0.0, 'z': 0.0},
        'angular': {'x': 0.0, 'y': 0.0, 'z': wz},
      });

  /// Sent three times: a lost frame must not leave the robot driving after STOP.
  void setMode(String mode) {
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: 80 * i), () => _publish(_chMode, {'data': mode}));
    }
  }
}

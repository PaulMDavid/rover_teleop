// Foxglove WebSocket client (subprotocol foxglove.sdk.v1) for app_foxglove_bridge.
// Publishes JSON-encoded /teleop/phone/cmd_vel, /teleop/phone/set_mode and
// /teleop/phone/rover_cmd, and subscribes /teleop/state (the mode the robot is actually
// in) and /teleop/rover_state (robot_control's modes as orintwo tracks them). /teleop/camera/compressed
// is subscribed only while the camera page wants it (app_teleop's teleop_camera relays
// the ZED only while someone is subscribed).
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
  double? get outVx => (json['out']?['vx'] as num?)?.toDouble();
  double? get outWz => (json['out']?['wz'] as num?)?.toDouble();

  bool get fresh => DateTime.now().difference(receivedAt) < const Duration(seconds: 1);
  bool get hearsPhone => phoneAge != null && phoneAge! < teleopTimeout;
}

/// robot_control's modes as orintwo's rover_cmd node reports them on /teleop/rover_state.
/// `tracked` = guessed from the /joy presses orintwo sent, not read from the rover.
class RoverState {
  RoverState(this.json) : receivedAt = DateTime.now();

  final Map<String, dynamic> json;
  final DateTime receivedAt;

  bool get tracked => json['tracked'] == true;
  String? get input => json['input'] as String?;
  String? get steering => json['steering'] as String?;
  String? get motion => json['motion'] as String?;
  String? get lastCmd => json['last_cmd'] as String?;
  double? get lastCmdAge => (json['last_cmd_age'] as num?)?.toDouble();
  String? get lastCmdBy => json['last_cmd_by'] as String?;
  int? get presses => (json['presses'] as num?)?.toInt();
  String? get rejected => json['rejected'] as String?;

  /// Published at 2–5 Hz; nothing for 1 s counts as stale.
  bool get fresh => DateTime.now().difference(receivedAt) < const Duration(seconds: 1);
}

enum Link { disconnected, connecting, connected }

class FoxgloveClient extends ChangeNotifier {
  static const _chCmd = 1, _chMode = 2, _chRover = 3, _subState = 1, _subCamera = 2, _subRover = 3;
  static const cameraTopic = '/teleop/camera/compressed';
  static const roverStateTopic = '/teleop/rover_state';

  Link link = Link.disconnected;
  RobotState? state;
  RoverState? roverState;
  String url = '';

  /// Latest camera JPEG; updated without notifying the client's listeners, so frames
  /// only rebuild the image widget.
  final cameraFrame = ValueNotifier<Uint8List?>(null);
  final _frameTimes = <DateTime>[];
  bool _wantCamera = false;
  int? _cameraChannel;
  bool _cameraSubscribed = false;

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
      final ws = await WebSocket.connect(url, protocols: ['foxglove.sdk.v1']).timeout(const Duration(seconds: 3));
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
    _cameraChannel = null;
    _cameraSubscribed = false;
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
              {
                'id': _chCmd,
                'topic': '/teleop/phone/cmd_vel',
                'encoding': 'json',
                'schemaName': 'geometry_msgs/msg/Twist'
              },
              {
                'id': _chMode,
                'topic': '/teleop/phone/set_mode',
                'encoding': 'json',
                'schemaName': 'std_msgs/msg/String'
              },
              {
                'id': _chRover,
                'topic': '/teleop/phone/rover_cmd',
                'encoding': 'json',
                'schemaName': 'std_msgs/msg/String'
              },
            ],
          });
        case 'advertise':
          for (final c in msg['channels'] as List) {
            if (c['topic'] == '/teleop/state') {
              _send({
                'op': 'subscribe',
                'subscriptions': [
                  {'id': _subState, 'channelId': c['id']}
                ]
              });
            } else if (c['topic'] == roverStateTopic) {
              _send({
                'op': 'subscribe',
                'subscriptions': [
                  {'id': _subRover, 'channelId': c['id']}
                ]
              });
            } else if (c['topic'] == cameraTopic) {
              _cameraChannel = c['id'] as int;
              _cameraSubscribed = false;
              _syncCamera();
            }
          }
      }
      return;
    }
    // messageData: op(1) subscriptionId(u32) timestamp(u64) payload; the payload is
    // std_msgs/String in CDR: 4-byte encapsulation header, u32 length incl. NUL, bytes
    final b = data as Uint8List;
    final v = ByteData.sublistView(b);
    if (b.length < 21 || v.getUint8(0) != 1) return;
    final sub = v.getUint32(1, Endian.little);
    if (sub == _subCamera) {
      _onCameraFrame(b);
      return;
    }
    if (sub != _subState && sub != _subRover) return;
    final len = v.getUint32(17, Endian.little);
    try {
      final json = jsonDecode(utf8.decode(b.sublist(21, 21 + len - 1))) as Map<String, dynamic>;
      if (sub == _subState) {
        state = RobotState(json);
      } else {
        roverState = RoverState(json);
      }
      notifyListeners();
    } catch (_) {}
  }

  /// Turn the camera stream on or off (the camera page being visible).
  void watchCamera(bool on) {
    _wantCamera = on;
    _syncCamera();
    if (!on) {
      cameraFrame.value = null;
      _frameTimes.clear();
    }
  }

  void _syncCamera() {
    final channel = _cameraChannel;
    if (_ws == null || channel == null || _wantCamera == _cameraSubscribed) return;
    if (_wantCamera) {
      _send({
        'op': 'subscribe',
        'subscriptions': [
          {'id': _subCamera, 'channelId': channel}
        ]
      });
    } else {
      _send({
        'op': 'unsubscribe',
        'subscriptionIds': [_subCamera]
      });
    }
    _cameraSubscribed = _wantCamera;
  }

  /// Frames per second over the last 2 s.
  double get cameraFps {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 2));
    _frameTimes.removeWhere((t) => t.isBefore(cutoff));
    return _frameTimes.length / 2;
  }

  bool get cameraAvailable => _cameraChannel != null;

  // sensor_msgs/CompressedImage in CDR, after the 13-byte messageData header and the
  // 4-byte encapsulation header: stamp (8), frame_id (u32 len + bytes), format (aligned
  // to 4), data (aligned u32 len + bytes). Alignment is relative to the CDR body.
  void _onCameraFrame(Uint8List b) {
    if (!_wantCamera) return;
    try {
      final body = ByteData.sublistView(b, 17);
      var off = 8;
      int skipString(int off) => off + 4 + body.getUint32(off, Endian.little);
      off = skipString(off); // frame_id
      off = (off + 3) & ~3;
      off = skipString(off); // format
      off = (off + 3) & ~3;
      final n = body.getUint32(off, Endian.little);
      final start = 17 + off + 4;
      cameraFrame.value = Uint8List.sublistView(b, start, start + n);
      _frameTimes.add(DateTime.now());
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

  /// A robot_control command for orintwo (input_auto, steer_crab, steer_ackermann, resume,
  /// arm, reset). Sent once, not repeated like setMode: each one becomes /joy presses, and
  /// a repeat would press again (input_auto, resume) or be queued as a second sequence.
  void roverCmd(String cmd) => _publish(_chRover, {'data': cmd});

  /// Sent three times: a lost frame must not leave the robot driving after STOP.
  void setMode(String mode) {
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: 80 * i), () => _publish(_chMode, {'data': mode}));
    }
  }
}

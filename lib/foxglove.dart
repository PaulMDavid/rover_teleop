// Foxglove WebSocket client (subprotocol foxglove.sdk.v1) for app_foxglove_bridge.
// Publishes JSON-encoded /teleop/phone/cmd_vel, /teleop/phone/set_mode and
// /teleop/phone/rover_cmd, and subscribes /teleop/state (the mode the robot is actually
// in) and /teleop/rover_state (robot_control's modes as orintwo tracks them). /teleop/camera/compressed
// is subscribed only while the camera page wants it (app_teleop's teleop_camera relays
// the ZED only while someone is subscribed). The Autonav page's topics (nav_relay,
// navigation_ws #30) are subscribed only while that page shows: /teleop/nav/state, and
// the latched map /teleop/nav/map + /teleop/nav/map_meta, which are subscribed again
// whenever a map half is missing (the bridge drops messages when its send buffer is full,
// and a dropped map only comes again on a new subscription). Goals and bringup commands
// go out on /teleop/phone/nav_cmd.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'nav.dart';

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
  static const _chCmd = 1, _chMode = 2, _chRover = 3, _chNav = 4, _subState = 1, _subCamera = 2, _subRover = 3;
  static const cameraTopic = '/teleop/camera/compressed';
  static const roverStateTopic = '/teleop/rover_state';
  static const navStateTopic = '/teleop/nav/state', navMapTopic = '/teleop/nav/map', navMetaTopic = '/teleop/nav/map_meta';

  /// A map half missing this long after subscribing (or after the other half came) →
  /// subscribe both again to get the latched copy.
  static const mapRetry = Duration(seconds: 3);

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

  /// nav_relay's /teleop/nav/state while the Autonav page shows.
  NavState? navState;

  /// The newest map whose image and meta pair up; kept when the page closes.
  NavMap? navMap;
  bool _wantNav = false;
  final _navChannels = <String, int>{}; // topic → bridge channel id
  final _navSubs = <String, int>{}; // topic → our subscription id
  final _metas = <MapMeta>[]; // recent metas, newest last, waiting for / paired with images
  ({Uint8List png, double stamp})? _orphanImage; // image whose meta hasn't come (yet)
  DateTime? _mapAsked; // last (re)subscription of the map topics
  int _nextSub = 10;
  Timer? _mapCheck;
  int mapSubscriptions = 0; // how often the map was (re)subscribed: for the tests

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
    _mapCheck?.cancel();
    _mapCheck = null;
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
    _navChannels.clear();
    _navSubs.clear();
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

  /// The socket is open (the tests override this and [sendRaw]).
  @protected
  bool get isOpen => _ws != null;

  @protected
  void sendRaw(Object data) => _ws?.add(data);

  void _send(Map<String, dynamic> obj) => sendRaw(jsonEncode(obj));

  /// A frame from the bridge, as the WebSocket delivers it.
  @visibleForTesting
  void handleMessage(dynamic data) => _onMessage(data);

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
              {
                'id': _chNav,
                'topic': '/teleop/phone/nav_cmd',
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
            } else if (c['topic'] == navStateTopic || c['topic'] == navMapTopic || c['topic'] == navMetaTopic) {
              final topic = c['topic'] as String;
              _navChannels[topic] = c['id'] as int;
              _navSubs.remove(topic); // a new channel: the old subscription is gone with it
              if (topic == navStateTopic) {
                _syncNav();
              } else {
                _askMap();
              }
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
    if (sub == _navSubs[navMapTopic]) {
      _onMapImage(b);
      return;
    }
    if (sub == _navSubs[navStateTopic] || sub == _navSubs[navMetaTopic]) {
      _onNavString(sub, b);
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
    if (!isOpen || channel == null || _wantCamera == _cameraSubscribed) return;
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
      cameraFrame.value = _compressedImage(b).data;
      _frameTimes.add(DateTime.now());
    } catch (_) {}
  }

  static ({double stamp, Uint8List data}) _compressedImage(Uint8List b) {
    final body = ByteData.sublistView(b, 17);
    final stamp = body.getInt32(0, Endian.little) + body.getUint32(4, Endian.little) * 1e-9;
    var off = 8;
    int skipString(int off) => off + 4 + body.getUint32(off, Endian.little);
    off = skipString(off); // frame_id
    off = (off + 3) & ~3;
    off = skipString(off); // format
    off = (off + 3) & ~3;
    final n = body.getUint32(off, Endian.little);
    final start = 17 + off + 4;
    if (start + n > b.length) throw const FormatException('short CompressedImage');
    return (stamp: stamp, data: Uint8List.sublistView(b, start, start + n));
  }

  // ---------------------------------------------------------------------------------------
  // Autonav (nav_relay)

  /// Turn the Autonav topics on or off (the page showing). Opening it always asks for the
  /// latched map again: a copy the bridge dropped earlier comes this way.
  void watchNav(bool on) {
    if (on == _wantNav) return;
    _wantNav = on;
    _syncNav();
    if (on) {
      _askMap();
      _mapCheck ??= Timer.periodic(const Duration(milliseconds: 500), (_) => checkMap());
    } else {
      _mapCheck?.cancel();
      _mapCheck = null;
      _unsubscribe(navMapTopic);
      _unsubscribe(navMetaTopic);
      navState = null;
    }
  }

  bool get navAvailable => _navChannels.containsKey(navStateTopic);

  void _subscribe(String topic) {
    final channel = _navChannels[topic];
    if (!isOpen || channel == null) return;
    final id = _nextSub++;
    _navSubs[topic] = id;
    _send({
      'op': 'subscribe',
      'subscriptions': [
        {'id': id, 'channelId': channel}
      ]
    });
  }

  void _unsubscribe(String topic) {
    final id = _navSubs.remove(topic);
    if (id == null || !isOpen) return;
    _send({
      'op': 'unsubscribe',
      'subscriptionIds': [id]
    });
  }

  void _syncNav() {
    final subscribed = _navSubs.containsKey(navStateTopic);
    if (_wantNav && !subscribed) _subscribe(navStateTopic);
    if (!_wantNav && subscribed) _unsubscribe(navStateTopic);
  }

  /// Unsubscribe + subscribe map and meta: the bridge sends the latched copy to the new
  /// subscription. Fresh subscription ids, so a late frame of the old one is ignored.
  void _askMap() {
    if (!_wantNav || !isOpen) return;
    if (!_navChannels.containsKey(navMapTopic) || !_navChannels.containsKey(navMetaTopic)) return;
    _unsubscribe(navMetaTopic);
    _unsubscribe(navMapTopic);
    _subscribe(navMetaTopic); // meta first, as the relay publishes it
    _subscribe(navMapTopic);
    _mapAsked = DateTime.now();
    mapSubscriptions++;
  }

  /// Every 0.5 s while the page shows: asks for the map again when, [mapRetry] after the
  /// last ask, there is no map, or the newest meta still has no image, or an image came
  /// without its meta.
  @visibleForTesting
  void checkMap({DateTime? now}) {
    final asked = _mapAsked;
    if (!_wantNav) return;
    if (asked == null) {
      _askMap();
      return;
    }
    final t = now ?? DateTime.now();
    if (t.difference(asked) < mapRetry) return;
    final newest = _metas.isEmpty ? null : _metas.last;
    final missing = navMap == null || _orphanImage != null || (newest != null && navMap!.meta.stamp != newest.stamp);
    if (missing) _askMap();
  }

  void _onNavString(int sub, Uint8List b) {
    final v = ByteData.sublistView(b);
    final len = v.getUint32(17, Endian.little);
    try {
      final json = jsonDecode(utf8.decode(b.sublist(21, 21 + len - 1))) as Map<String, dynamic>;
      if (sub == _navSubs[navStateTopic]) {
        navState = NavState(json);
      } else {
        _onMeta(MapMeta.fromJson(json));
      }
      notifyListeners();
    } catch (_) {}
  }

  void _onMeta(MapMeta meta) {
    _metas.removeWhere((m) => m.stamp == meta.stamp);
    _metas.add(meta);
    if (_metas.length > 4) _metas.removeAt(0);
    final orphan = _orphanImage;
    if (orphan != null && meta.pairs(orphan.stamp, orphan.png.length)) {
      _orphanImage = null;
      navMap = NavMap(meta, orphan.png);
    }
  }

  void _onMapImage(Uint8List b) {
    try {
      final img = _compressedImage(b);
      final png = Uint8List.fromList(img.data); // the frame buffer isn't ours to keep
      final meta = _metas.reversed.where((m) => m.pairs(img.stamp, png.length)).firstOrNull;
      if (meta == null) {
        _orphanImage = (png: png, stamp: img.stamp);
      } else {
        _orphanImage = null;
        navMap = NavMap(meta, png);
      }
      notifyListeners();
    } catch (_) {}
  }

  /// One /teleop/phone/nav_cmd (nav_relay's JSON); sent once, like roverCmd.
  void navCmd(Map<String, dynamic> cmd) => _publish(_chNav, {'data': jsonEncode(cmd)});

  void navGoal(double x, double y, double yaw) => navCmd({'cmd': 'goal', 'x': x, 'y': y, 'yaw': yaw});

  void _publish(int channel, Map<String, dynamic> obj) {
    if (!isOpen) return;
    final header = ByteData(5)
      ..setUint8(0, 1) // clientMessageData
      ..setUint32(1, channel, Endian.little);
    sendRaw(Uint8List.fromList([...header.buffer.asUint8List(), ...utf8.encode(jsonEncode(obj))]));
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

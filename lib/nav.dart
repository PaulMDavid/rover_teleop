// What nav_relay (navigation_ws #30/#32, app_teleop README "Autonav relay") sends the
// phone, and the map geometry the Autonav page draws with. Everything is in the `map`
// frame, metres and radians; yaw is REP-103 (counter-clockwise from +x).
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

double? _d(Object? v) => (v as num?)?.toDouble();

/// x, y, yaw (+ age) as nav_relay sends pose and goal.
class NavPose {
  const NavPose(this.x, this.y, this.yaw, [this.age]);

  static NavPose? fromJson(Object? j) => j is Map
      ? NavPose((j['x'] as num).toDouble(), (j['y'] as num).toDouble(), (j['yaw'] as num).toDouble(), _d(j['age']))
      : null;

  final double x, y, yaw;
  final double? age;
}

class BringupCheck {
  BringupCheck(Map j)
      : label = j['label'] as String? ?? '',
        ok = j['ok'] as bool?,
        value = j['value']?.toString() ?? '',
        hint = j['hint'] as String? ?? '';
  final String label, value, hint;
  final bool? ok; // null = measuring
}

class BringupStage {
  BringupStage(Map j)
      : name = j['name'] as String? ?? '',
        title = j['title'] as String? ?? (j['name'] as String? ?? ''),
        state = j['state'] as String? ?? 'pending',
        required = j['required'] != false,
        message = j['message'] as String? ?? '',
        checks = [for (final c in (j['checks'] as List?) ?? const []) BringupCheck(c as Map)];
  final String name, title, state, message;
  final bool required;
  final List<BringupCheck> checks;
}

/// /teleop/nav/state (JSON, ~5 Hz).
class NavState {
  NavState(this.json) : receivedAt = DateTime.now();

  final Map<String, dynamic> json;
  final DateTime receivedAt;

  NavPose? get pose => NavPose.fromJson(json['pose']);
  String? get poseError => json['pose_error'] as String?;
  bool get nav2Ready => json['nav2_ready'] == true;
  String get status => json['status'] as String? ?? 'idle';
  String? get reason => json['reason'] as String?;
  NavPose? get goal => NavPose.fromJson(json['goal']);
  double? get distanceRemaining => _d(json['distance_remaining']);
  double? get eta => _d(json['eta']);
  int? get recoveries => (json['recoveries'] as num?)?.toInt();
  List<Offset> get plan => [
        for (final p in (json['plan'] as List?) ?? const [])
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
      ];
  Map<String, dynamic>? get _bringup => json['bringup'] as Map<String, dynamic>?;
  bool get hasBringup => _bringup != null;
  String? get bringupOverall => _bringup?['overall'] as String?;
  double? get bringupAge => _d(_bringup?['age']);

  /// The manager publishes at 1 Hz: older than 3 s = gone.
  bool get bringupGone => bringupAge != null && bringupAge! > 3;
  List<BringupStage> get stages => [for (final s in (_bringup?['stages'] as List?) ?? const []) BringupStage(s as Map)];
  Map<String, dynamic>? get bringupReply => json['bringup_reply'] as Map<String, dynamic>?;
  String? get lastCmd => json['last_cmd'] as String?;
  String? get rejected => json['rejected'] as String?;

  /// README: Nav2 is up = the nav2 stage (or the whole stack) ready, and the action server there.
  bool get nav2Up {
    final st = stages.where((s) => s.name == 'nav2').firstOrNull;
    return nav2Ready && (st?.state == 'ready' || bringupOverall == 'ready');
  }

  /// Published at 5 Hz; nothing for 1.5 s counts as stale.
  bool get fresh => DateTime.now().difference(receivedAt) < const Duration(milliseconds: 1500);
}

/// /teleop/nav/map_meta.
class MapMeta {
  MapMeta({
    required this.seq,
    required this.stamp,
    required this.resolution,
    required this.width,
    required this.height,
    required this.ox,
    required this.oy,
    this.oyaw = 0,
    this.bytes,
  });

  factory MapMeta.fromJson(Map<String, dynamic> j) {
    final o = j['origin'] as Map;
    return MapMeta(
      seq: (j['seq'] as num).toInt(),
      stamp: (j['stamp'] as num).toDouble(),
      resolution: (j['resolution'] as num).toDouble(),
      width: (j['width'] as num).toInt(),
      height: (j['height'] as num).toInt(),
      ox: (o['x'] as num).toDouble(),
      oy: (o['y'] as num).toDouble(),
      oyaw: _d(o['yaw']) ?? 0,
      bytes: (j['bytes'] as num?)?.toInt(),
    );
  }

  final int seq, width, height;
  final double stamp, resolution, ox, oy, oyaw;
  final int? bytes;

  /// The image whose header.stamp is [imageStamp] belongs to this meta (same stamp, and
  /// the same size when the meta gives one).
  bool pairs(double imageStamp, int length) =>
      (imageStamp - stamp).abs() < 1e-6 && (bytes == null || bytes == length);

  /// README: centre of PNG pixel (column u, row v) in `map`. Row 0 is the top = highest y.
  Offset pixelCentre(int u, int v) => gridToMap(Offset((u + 0.5) * resolution, (height - v - 0.5) * resolution));

  /// Grid axes (metres from the origin corner, along the grid's own x/y) → map.
  Offset gridToMap(Offset g) {
    final c = cos(oyaw), s = sin(oyaw);
    return Offset(ox + g.dx * c - g.dy * s, oy + g.dx * s + g.dy * c);
  }

  Offset mapToGrid(Offset p) {
    final dx = p.dx - ox, dy = p.dy - oy, c = cos(oyaw), s = sin(oyaw);
    return Offset(dx * c + dy * s, -dx * s + dy * c);
  }

  double get widthM => width * resolution;
  double get heightM => height * resolution;
}

/// A map image with the meta it pairs with.
class NavMap {
  NavMap(this.meta, this.png);
  final MapMeta meta;
  final Uint8List png;
}

/// The map on screen: the PNG unrotated (screen right = grid +x, screen up = grid +y,
/// which is map +x / +y when the origin yaw is 0), [center] (map frame) at the middle of
/// the view, [pxPerM] screen pixels per metre.
class MapView {
  MapView(this.meta, this.size, this.center, this.pxPerM);

  /// The whole map in the view, with a small margin.
  factory MapView.fit(MapMeta meta, Size size) {
    final k = min(size.width / meta.widthM, size.height / meta.heightM) * 0.95;
    return MapView(meta, size, meta.gridToMap(Offset(meta.widthM / 2, meta.heightM / 2)), k);
  }

  final MapMeta meta;
  final Size size;
  final Offset center;
  final double pxPerM;

  Offset toScreen(Offset p) {
    final g = meta.mapToGrid(p), c = meta.mapToGrid(center);
    return Offset(size.width / 2 + (g.dx - c.dx) * pxPerM, size.height / 2 - (g.dy - c.dy) * pxPerM);
  }

  Offset toMap(Offset s) {
    final c = meta.mapToGrid(center);
    return meta.gridToMap(
        Offset(c.dx + (s.dx - size.width / 2) / pxPerM, c.dy - (s.dy - size.height / 2) / pxPerM));
  }

  /// Where the PNG goes: its top-left corner is grid (0, height).
  Rect get imageRect {
    final tl = toScreen(meta.gridToMap(Offset(0, meta.heightM)));
    return Rect.fromLTWH(tl.dx, tl.dy, meta.widthM * pxPerM, meta.heightM * pxPerM);
  }

  /// A map yaw as a screen angle (radians, clockwise from screen right, as Canvas rotates).
  double screenAngle(double yaw) => -(yaw - meta.oyaw);

  /// The map yaw pointing from screen point [from] to [to].
  double yawBetween(Offset from, Offset to) {
    final a = atan2(to.dy - from.dy, to.dx - from.dx);
    return normalizeAngle(meta.oyaw - a);
  }

  MapView copyWith({MapMeta? meta, Size? size, Offset? center, double? pxPerM}) =>
      MapView(meta ?? this.meta, size ?? this.size, center ?? this.center, pxPerM ?? this.pxPerM);

  /// Pinch/pan: [scale] about the screen point [focal], which then moves by [pan].
  MapView zoomPan(Offset focal, double scale, Offset pan) {
    final k = (pxPerM * scale).clamp(minPxPerM, maxPxPerM);
    final anchor = toMap(focal); // stays under the fingers
    final moved = copyWith(pxPerM: k);
    final now = moved.toScreen(anchor);
    final target = focal + pan;
    return moved.copyWith(center: moved.toMap(moved.size.center(Offset.zero) + (now - target)));
  }

  double get minPxPerM => min(size.width / meta.widthM, size.height / meta.heightM) * 0.25;
  static const maxPxPerM = 400.0; // 1 m = 400 px
}

/// (−π, π]
double normalizeAngle(double a) {
  while (a > pi) {
    a -= 2 * pi;
  }
  while (a <= -pi) {
    a += 2 * pi;
  }
  return a;
}

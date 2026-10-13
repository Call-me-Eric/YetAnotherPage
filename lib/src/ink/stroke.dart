import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';

const penBaseWidth = 3.0;
const penColor = 0xFF000000;
const missingPressure = 0.5;
const missingOpacity = 1.0;
const straightSpacing = 1.0;
const tightSpacing = 0.4;

/// Gaps this short are joined directly. A circle fit on them is just noise.
const minFitDistance = 1.5;

/// Handwriting samples are denser than this. Fitting them bows the stroke, then later samples pull it back.
const directJoinDistance = 8;
const curveWindow = 0.032;

class StrokePoint {
  const StrokePoint({
    required this.x,
    required this.y,
    required this.time,
    required this.width,
    required this.height,
    required this.opacity,
    required this.pressure,
    this.azimuth,
    this.altitude,
    this.gap = false,
  });

  final double x;
  final double y;
  final double time;
  final double width;
  final double height;
  final double opacity;
  final double pressure;
  final double? azimuth;
  final double? altitude;

  /// When true, this point starts a new run and is not joined to the previous point.
  final bool gap;

  StrokePoint copyWith({double? x, double? y, double? width, double? height}) {
    return StrokePoint(
      x: x ?? this.x,
      y: y ?? this.y,
      time: time,
      width: width ?? this.width,
      height: height ?? this.height,
      opacity: opacity,
      pressure: pressure,
      azimuth: azimuth,
      altitude: altitude,
      gap: gap,
    );
  }

  Map<String, Object> toJson() => {
    'x': x,
    'y': y,
    'time': time,
    'width': width,
    'height': height,
    'opacity': opacity,
    'pressure': pressure,
    'azimuth': ?azimuth,
    'altitude': ?altitude,
    if (gap) 'gap': true,
  };

  factory StrokePoint.fromJson(Map<String, Object?> json) {
    return StrokePoint(
      x: (json['x']! as num).toDouble(),
      y: (json['y']! as num).toDouble(),
      time: (json['time']! as num).toDouble(),
      width: (json['width']! as num).toDouble(),
      height: (json['height']! as num).toDouble(),
      opacity: (json['opacity']! as num).toDouble(),
      pressure: (json['pressure']! as num).toDouble(),
      azimuth: (json['azimuth'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      gap: json['gap'] == true,
    );
  }
}

class FrozenStrokePoints extends ListBase<StrokePoint> {
  FrozenStrokePoints(List<StrokePoint> points)
    : _source = List<StrokePoint>.of(points),
      _start = 0,
      _end = points.length,
      _root = null;
  FrozenStrokePoints._view(this._source, this._start, this._end, this._root);
  final List<StrokePoint> _source;
  final int _start, _end;
  final FrozenStrokePoints? _root;
  List<Rect>? _chunks;
  Rect? _inkBounds;
  List<double>? _distances;
  @override
  int get length => _end - _start;
  @override
  set length(int value) => throw UnsupportedError('Immutable samples');
  @override
  StrokePoint operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _source[_start + index];
  }

  @override
  void operator []=(int index, StrokePoint value) =>
      throw UnsupportedError('Immutable samples');

  FrozenStrokePoints slice(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    return FrozenStrokePoints._view(
      _source,
      _start + start,
      _start + end,
      _root ?? this,
    );
  }

  Iterable<Rect> get chunkBounds sync* {
    final root = _root ?? this;
    root._chunks ??= [
      for (var i = 0; i < root._source.length; i += 32)
        _sampleBounds(root._source, i, math.min(root._source.length, i + 33)),
    ];
    for (var chunk = _start ~/ 32; chunk * 32 < _end; chunk++) {
      final from = math.max(_start, chunk * 32),
          to = math.min(_end, chunk * 32 + 33);
      yield from == chunk * 32 &&
              to == math.min(_source.length, chunk * 32 + 33)
          ? root._chunks![chunk]
          : _sampleBounds(_source, from, to);
    }
  }

  /// Arc length from this view's first sample. Shared by repeated eraser cuts.
  double distanceAt(int index) {
    RangeError.checkValidIndex(index, this);
    final root = _root ?? this;
    root._distances ??= [
      0,
      for (var i = 1, distance = 0.0; i < _source.length; i++)
        distance += _source[i].gap
            ? 0
            : _hypot(
                _source[i].x - _source[i - 1].x,
                _source[i].y - _source[i - 1].y,
              ),
    ];
    return root._distances![_start + index] - root._distances![_start];
  }

  Rect get inkBounds => _inkBounds ??= _unionBounds(chunkBounds);

  /// Shared conservative bounds for 32-sample chunks. Region fragments reuse
  /// these blocks and immutable sample storage rather than copying whole runs.
  Iterable<(int, int)> ranges(Rect query) sync* {
    final root = _root ?? this;
    root._chunks ??= [
      for (var i = 0; i < root._source.length; i += 32)
        _sampleBounds(root._source, i, math.min(root._source.length, i + 33)),
    ];
    for (var chunk = _start ~/ 32; chunk * 32 < _end; chunk++) {
      if (!root._chunks![chunk].overlaps(query)) continue;
      yield (
        math.max(0, chunk * 32 - _start),
        math.min(length, chunk * 32 + 33 - _start),
      );
    }
  }
}

Rect _unionBounds(Iterable<Rect> rects) {
  var result = Rect.zero;
  for (final rect in rects) {
    result = result.isEmpty ? rect : result.expandToInclude(rect);
  }
  return result;
}

Rect _sampleBounds(List<StrokePoint> points, int from, int to) {
  var left = double.infinity,
      top = double.infinity,
      right = double.negativeInfinity,
      bottom = double.negativeInfinity;
  for (var i = from; i < to; i++) {
    final p = points[i], pad = math.max(p.width, p.height) / 2 + 2;
    left = math.min(left, p.x - pad);
    top = math.min(top, p.y - pad);
    right = math.max(right, p.x + pad);
    bottom = math.max(bottom, p.y + pad);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Lazy JSON view: creating a document snapshot must not allocate a map for
/// every old sample on the UI isolate. Encoding occurs on the storage worker.
class StrokeJsonPoints extends ListBase<Object?> {
  StrokeJsonPoints(this.points);
  final List<StrokePoint> points;
  @override
  int get length => points.length;
  @override
  set length(int value) => throw UnsupportedError('Immutable samples');
  @override
  Object? operator [](int index) => points[index].toJson();
  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('Immutable samples');
}

class StrokeObject {
  StrokeObject({
    required this.id,
    required this.tool,
    required this.color,
    required this.baseWidth,
    required List<StrokePoint> points,
    required this.finalized,
    this.dashCycle = 24,
    this.dashRatio = 1,
    this.dashOffset = 0,
  }) : points = finalized
           ? (points is FrozenStrokePoints
                 ? points
                 : FrozenStrokePoints(points))
           : points;

  final String id;
  final String tool;
  final int color;
  final double baseWidth;
  final List<StrokePoint> points;
  final bool finalized;

  /// Length of one dash repeat, in points. Ignored when [dashRatio] is 1.
  final double dashCycle;

  /// Fraction of each repeat that is drawn. 1 is a solid line.
  final double dashRatio;

  /// Original arc length at the first sample, retained when a stroke is cut.
  final double dashOffset;

  StrokeObject copyWith({
    List<StrokePoint>? points,
    bool? finalized,
    double? baseWidth,
    double? dashCycle,
    double? dashOffset,
  }) {
    return StrokeObject(
      id: id,
      tool: tool,
      color: color,
      baseWidth: baseWidth ?? this.baseWidth,
      points: points ?? this.points,
      finalized: finalized ?? this.finalized,
      dashCycle: dashCycle ?? this.dashCycle,
      dashRatio: dashRatio,
      dashOffset: dashOffset ?? this.dashOffset,
    );
  }

  Map<String, Object> toJson() => {
    'type': 'stroke',
    'id': id,
    'tool': tool,
    'color': color,
    'baseWidth': baseWidth,
    'finalized': finalized,
    'dashCycle': dashCycle,
    'dashRatio': dashRatio,
    if (dashOffset != 0) 'dashOffset': dashOffset,
    'points': finalized
        ? StrokeJsonPoints(points)
        : [for (final point in points) point.toJson()],
  };

  factory StrokeObject.fromJson(Map<String, Object?> json) {
    return StrokeObject(
      id: json['id']! as String,
      tool: json['tool']! as String,
      color: json['color']! as int,
      baseWidth: (json['baseWidth']! as num).toDouble(),
      points: [
        for (final point in json['points']! as List<Object?>)
          StrokePoint.fromJson((point as Map).cast<String, Object?>()),
      ],
      finalized: json['finalized'] as bool? ?? false,
      dashCycle: (json['dashCycle'] as num?)?.toDouble() ?? 24,
      dashRatio: (json['dashRatio'] as num?)?.toDouble() ?? 1,
      dashOffset: (json['dashOffset'] as num?)?.toDouble() ?? 0,
    );
  }
}

StrokeObject? strokeFromObject(Object? object) {
  if (object is! Map) {
    return null;
  }
  final json = object.cast<String, Object?>();
  if (json['type'] != 'stroke') {
    return null;
  }
  return StrokeObject.fromJson(json);
}

List<StrokeObject> strokesIn(Iterable<Object?> objects) {
  return [for (final object in objects) ?strokeFromObject(object)];
}

/// Carries the last sample's fitted circle and the sums behind it.
/// The next sample slides that window instead of starting over.
class StrokeCursor {
  int connected = 0;
  double incomingX = 0;
  double incomingY = 0;
  bool hasIncoming = false;
  _Poly? _poly;
  final _PolySums _sums = _PolySums();
}

/// Samples a mouse point. Pressure and opacity use fixed values.
StrokePoint mouseSample({
  required double x,
  required double y,
  required double time,
  required double baseWidth,
}) {
  return StrokePoint(
    x: x,
    y: y,
    time: time,
    width: baseWidth,
    height: baseWidth,
    opacity: missingOpacity,
    pressure: missingPressure,
  );
}

/// Builds the points that are both shown while drawing and stored on pen up.
/// A segment is painted only after later samples have arrived, so the curve is final.
StrokeObject bakePenStroke(StrokeObject stroke) {
  final painted = causalPaint(stroke.points, stroke.baseWidth);
  return stroke.copyWith(
    points: stroke.tool == 'highlighter'
        ? [
            for (final point in painted)
              point.copyWith(width: stroke.baseWidth, height: stroke.baseWidth),
          ]
        : painted,
    finalized: true,
  );
}

List<StrokePoint> pointsForPaint(StrokeObject stroke) {
  if (stroke.finalized) {
    return stroke.points;
  }
  return causalPaint(stroke.points, stroke.baseWidth);
}

List<StrokePoint> causalPaint(List<StrokePoint> raw, double baseWidth) {
  if (raw.isEmpty) {
    return raw;
  }
  var painted = <StrokePoint>[];
  var kept = <StrokePoint>[];
  final cursor = StrokeCursor();
  for (final sample in raw) {
    final next = appendCausalPoint(
      raw: kept,
      painted: painted,
      sample: sample,
      baseWidth: baseWidth,
      connected: cursor.connected,
      cursor: cursor,
    );
    kept = next.raw;
    painted = next.painted;
  }
  return finishStroke(
    raw: kept,
    painted: painted,
    connected: cursor.connected,
    cursor: cursor,
  ).painted;
}

List<StrokePoint> densifySamples(List<StrokePoint> points) {
  return causalPaint(
    points,
    points.isEmpty ? penBaseWidth : points.first.width,
  );
}

({List<StrokePoint> raw, List<StrokePoint> painted, int connected})
appendCausalPoint({
  required List<StrokePoint> raw,
  required List<StrokePoint> painted,
  required StrokePoint sample,
  required double baseWidth,
  required int connected,
  StrokeCursor? cursor,
}) {
  if (identical(raw, painted)) {
    painted = List<StrokePoint>.of(painted);
  }
  final sized = raw.isEmpty
      ? sample.copyWith(width: baseWidth, height: baseWidth)
      : _widthFromPrevious(raw.last, sample, baseWidth);
  raw.add(sized);
  if (painted.isEmpty) {
    painted.add(raw.first);
  }
  final ready = _drawReady(
    raw: raw,
    painted: painted,
    connected: connected,
    hold: _holdCount(raw),
    cursor: cursor,
  );
  cursor?.connected = ready;
  return (raw: raw, painted: painted, connected: ready);
}

({List<StrokePoint> raw, List<StrokePoint> painted, int connected})
finishStroke({
  required List<StrokePoint> raw,
  required List<StrokePoint> painted,
  required int connected,
  StrokeCursor? cursor,
}) {
  if (painted.isEmpty && raw.isNotEmpty) {
    painted.add(raw.first);
  }
  final ready = _drawReady(
    raw: raw,
    painted: painted,
    connected: connected,
    hold: 1,
    cursor: cursor,
  );
  cursor?.connected = ready;
  return (raw: raw, painted: painted, connected: ready);
}

int _drawReady({
  required List<StrokePoint> raw,
  required List<StrokePoint> painted,
  required int connected,
  required int hold,
  StrokeCursor? cursor,
}) {
  var next = connected;
  while (raw.length - 1 - next >= hold) {
    next += 1;
    _appendArc(painted, raw, next, cursor);
  }
  return next;
}

/// How many not-yet-connected samples to wait for. A longer gap means the input is late,
/// so the curve needs more following points before it is drawn.
int _holdCount(List<StrokePoint> raw) {
  if (raw.length < 2) {
    return 2;
  }
  final gap = raw.last.time - raw[raw.length - 2].time;
  if (gap >= 0.024) {
    return 4;
  }
  if (gap >= 0.014) {
    return 3;
  }
  return 2;
}

void _appendArc(
  List<StrokePoint> result,
  List<StrokePoint> raw,
  int index,
  StrokeCursor? cursor,
) {
  final start = raw[index - 1];
  final end = raw[index];
  void remember() {
    if (cursor == null) {
      return;
    }
    cursor.incomingX = end.x - start.x;
    cursor.incomingY = end.y - start.y;
    cursor.hasIncoming = true;
  }

  final chord = _hypot(end.x - start.x, end.y - start.y);
  if (chord < minFitDistance) {
    _addIfLater(result, end);
    remember();
    return;
  }
  if (chord < directJoinDistance) {
    final bulge = _allowedBulge(raw, index, start, end, chord, cursor);
    if (bulge < 0.7) {
      _appendChord(result, start, end, straightSpacing);
      remember();
      return;
    }
  }
  final poly = _polyFor(raw, index, cursor);
  if (poly == null || (end.time - start.time).abs() <= 0.0001) {
    _appendChord(result, start, end, straightSpacing);
    remember();
    return;
  }
  final atStart = poly.at(start.time);
  final atEnd = poly.at(end.time);
  Offset at(double u) {
    final time = start.time + (end.time - start.time) * u;
    final point = poly.at(time);
    return Offset(
      point.dx + (start.x - atStart.dx) * (1 - u) + (end.x - atEnd.dx) * u,
      point.dy + (start.y - atStart.dy) * (1 - u) + (end.y - atEnd.dy) * u,
    );
  }

  final allowed = _allowedBulge(raw, index, start, end, chord, cursor);
  final rough = at(0.5);
  if (_hypot(
        rough.dx - (start.x + end.x) / 2,
        rough.dy - (start.y + end.y) / 2,
      ) >
      allowed) {
    _appendChord(result, start, end, straightSpacing);
    remember();
    return;
  }
  final spacing = allowed > 2 ? tightSpacing : straightSpacing;
  final lengthGuess = math.max(
    chord,
    _hypot(rough.dx - start.x, rough.dy - start.y) +
        _hypot(end.x - rough.dx, end.y - rough.dy),
  );
  final steps = math.max(1, (lengthGuess / spacing).ceil());
  for (var step = 1; step <= steps; step++) {
    final u = step / steps;
    if (step == steps) {
      _addIfLater(result, end);
      break;
    }
    final point = at(u);
    _addIfLater(
      result,
      _lerpSample(start, end, u).copyWith(x: point.dx, y: point.dy),
    );
  }
  remember();
}

double _allowedBulge(
  List<StrokePoint> raw,
  int index,
  StrokePoint start,
  StrokePoint end,
  double chord,
  StrokeCursor? cursor,
) {
  var inX = 0.0;
  var inY = 0.0;
  if (cursor != null && cursor.hasIncoming) {
    inX = cursor.incomingX;
    inY = cursor.incomingY;
  } else if (index >= 2) {
    final previous = raw[index - 2];
    inX = start.x - previous.x;
    inY = start.y - previous.y;
  }
  final incoming = _hypot(inX, inY);
  var expected = 0.0;
  if (incoming > 0.5) {
    expected = math.max(
      expected,
      _bulgeForTurn(inX, inY, end.x - start.x, end.y - start.y, chord),
    );
  }
  if (index + 1 < raw.length) {
    final next = raw[index + 1];
    expected = math.max(
      expected,
      _bulgeForTurn(
        end.x - start.x,
        end.y - start.y,
        next.x - end.x,
        next.y - end.y,
        chord,
      ),
    );
  }
  return math.max(1.0, expected * 1.35);
}

double _bulgeForTurn(
  double inX,
  double inY,
  double outX,
  double outY,
  double chord,
) {
  final incoming = _hypot(inX, inY);
  final outgoing = _hypot(outX, outY);
  if (incoming <= 0.5 || outgoing <= 0.5) {
    return 0;
  }
  final cross = inX * outY - inY * outX;
  final dot = inX * outX + inY * outY;
  final delta = math.atan2(cross, dot).abs();
  if (delta <= 0.001 || delta >= 2.5) {
    return 0;
  }
  return chord * (1 - math.cos(delta)) / (2 * math.sin(delta));
}

void _appendChord(
  List<StrokePoint> result,
  StrokePoint start,
  StrokePoint end,
  double spacing,
) {
  final distance = _hypot(end.x - start.x, end.y - start.y);
  final steps = math.max(1, (distance / spacing).ceil());
  for (var step = 1; step <= steps; step++) {
    _addIfLater(
      result,
      step == steps ? end : _lerpSample(start, end, step / steps),
    );
  }
}

void _addIfLater(List<StrokePoint> result, StrokePoint point) {
  final last = result.last;
  if (point.time + 0.0000001 < last.time) {
    return;
  }
  if (_hypot(point.x - last.x, point.y - last.y) < 0.05 &&
      (point.time - last.time).abs() < 0.0001) {
    return;
  }
  result.add(point);
}

class _Poly {
  const _Poly(
    this.ax,
    this.bx,
    this.cx,
    this.ay,
    this.by,
    this.cy, {
    this.origin = 0,
  });

  final double origin;

  final double ax;
  final double bx;
  final double cx;
  final double ay;
  final double by;
  final double cy;

  Offset at(double time) {
    final t = (time - origin) * 1000;
    final t2 = t * t;
    return Offset(ax * t2 + bx * t + cx, ay * t2 + by * t + cy);
  }
}

_Poly? _polyFor(List<StrokePoint> raw, int index, StrokeCursor? cursor) {
  final from = math.max(0, index - 1);
  final to = math.min(raw.length, index + 2);
  if (to - from < 3) {
    return null;
  }
  final cached = cursor?._poly;
  if (cached != null && _polyFits(raw, from, to, cached)) {
    return cached;
  }
  if (cursor != null) {
    cursor._sums.sync(raw, from, to);
    final fitted = cursor._sums.solve(raw);
    cursor._poly = fitted;
    return fitted;
  }
  return _fitPoly(raw.sublist(from, to));
}

bool _polyFits(List<StrokePoint> raw, int from, int to, _Poly poly) {
  var error = 0.0;
  var count = 0;
  for (var index = from; index < to; index++) {
    final point = raw[index];
    final at = poly.at(point.time);
    error += _hypot(point.x - at.dx, point.y - at.dy);
    count += 1;
  }
  return count >= 3 && error / count <= 8;
}

class _PolySums {
  double origin = 0;
  double st4 = 0;
  double st3 = 0;
  double st2 = 0;
  double st1 = 0;
  double sn = 0;
  double xt2 = 0;
  double xt1 = 0;
  double x = 0;
  double yt2 = 0;
  double yt1 = 0;
  double y = 0;
  int from = 0;
  int to = 0;

  void sync(List<StrokePoint> raw, int nextFrom, int nextTo) {
    // This window has only three samples. Rebase locally instead of subtracting
    // large cumulative fourth powers for a long stroke (catastrophic cancellation).
    origin = raw[nextFrom].time;
    st4 = st3 = st2 = st1 = sn = xt2 = xt1 = x = yt2 = yt1 = y = 0;
    from = nextFrom;
    to = nextTo;
    for (var index = from; index < to; index++) {
      _accumulate(raw[index], 1);
    }
  }

  void _accumulate(StrokePoint point, double sign) {
    final t = (point.time - origin) * 1000;
    final t2 = t * t;
    st4 += sign * t2 * t2;
    st3 += sign * t2 * t;
    st2 += sign * t2;
    st1 += sign * t;
    sn += sign;
    xt2 += sign * t2 * point.x;
    xt1 += sign * t * point.x;
    x += sign * point.x;
    yt2 += sign * t2 * point.y;
    yt1 += sign * t * point.y;
    y += sign * point.y;
  }

  _Poly? solve(List<StrokePoint> raw) {
    final poly = _solve();
    if (poly == null || !_polyFits(raw, from, to, poly)) {
      return null;
    }
    if (sn <= 3) {
      return poly;
    }
    var worst = -1;
    var worstMiss = 0.0;
    for (var index = from; index < to; index++) {
      final point = raw[index];
      final at = poly.at(point.time);
      final miss = _hypot(point.x - at.dx, point.y - at.dy);
      if (miss > worstMiss) {
        worstMiss = miss;
        worst = index;
      }
    }
    if (worst < 0 || worstMiss <= 6) {
      return poly;
    }
    final copy = _PolySums()
      ..origin = origin
      ..st4 = st4
      ..st3 = st3
      ..st2 = st2
      ..st1 = st1
      ..sn = sn
      ..xt2 = xt2
      ..xt1 = xt1
      ..x = x
      ..yt2 = yt2
      ..yt1 = yt1
      ..y = y
      ..from = from
      ..to = to;
    copy._accumulate(raw[worst], -1);
    final without = copy._solve();
    if (without == null) {
      return poly;
    }
    return without;
  }

  _Poly? _solve() {
    if (sn < 3) {
      return null;
    }
    final det = _det3(st4, st3, st2, st3, st2, st1, st2, st1, sn);
    if (det.abs() > 1e-12) {
      final ax = _det3(xt2, st3, st2, xt1, st2, st1, x, st1, sn) / det;
      final bx = _det3(st4, xt2, st2, st3, xt1, st1, st2, x, sn) / det;
      final cx = _det3(st4, st3, xt2, st3, st2, xt1, st2, st1, x) / det;
      final ay = _det3(yt2, st3, st2, yt1, st2, st1, y, st1, sn) / det;
      final by = _det3(st4, yt2, st2, st3, yt1, st1, st2, y, sn) / det;
      final cy = _det3(st4, st3, yt2, st3, st2, yt1, st2, st1, y) / det;
      return _Poly(ax, bx, cx, ay, by, cy, origin: origin);
    }
    final det2 = st2 * sn - st1 * st1;
    if (det2.abs() < 1e-12) {
      return null;
    }
    final bx = (xt1 * sn - st1 * x) / det2;
    final cx = (st2 * x - st1 * xt1) / det2;
    final by = (yt1 * sn - st1 * y) / det2;
    final cy = (st2 * y - st1 * yt1) / det2;
    return _Poly(0, bx, cx, 0, by, cy, origin: origin);
  }
}

_Poly? _fitPoly(List<StrokePoint> points) {
  if (points.length < 3) {
    return null;
  }
  final sums = _PolySums()..origin = points.first.time;
  for (final point in points) {
    sums._accumulate(point, 1);
  }
  sums.to = points.length;
  final poly = sums._solve();
  if (poly == null || !_polyFits(points, 0, points.length, poly)) {
    return null;
  }
  return poly;
}

double _det3(
  double a,
  double b,
  double c,
  double d,
  double e,
  double f,
  double g,
  double h,
  double i,
) {
  return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
}

StrokePoint _widthFromPrevious(
  StrokePoint previous,
  StrokePoint next,
  double baseWidth,
) {
  final dt = next.time - previous.time;
  final distance = _hypot(next.x - previous.x, next.y - previous.y);
  final speed = dt <= 0.0001 ? 0.0 : distance / dt;
  final pace = (speed / 900).clamp(0.0, 1.0);
  final pressure = next.pressure <= 0 ? missingPressure : next.pressure;
  final width = baseWidth * (1.1 - 0.2 * pace) * (0.7 + 0.6 * pressure);
  return next.copyWith(width: width, height: width);
}

StrokePoint _lerpSample(StrokePoint start, StrokePoint end, double t) {
  double? angle(double? from, double? to) {
    if (from == null || to == null) {
      return null;
    }
    return from + (to - from) * t;
  }

  return StrokePoint(
    x: start.x + (end.x - start.x) * t,
    y: start.y + (end.y - start.y) * t,
    time: start.time + (end.time - start.time) * t,
    width: start.width + (end.width - start.width) * t,
    height: start.height + (end.height - start.height) * t,
    opacity: start.opacity + (end.opacity - start.opacity) * t,
    pressure: start.pressure + (end.pressure - start.pressure) * t,
    azimuth: angle(start.azimuth, end.azimuth),
    altitude: angle(start.altitude, end.altitude),
  );
}

double _hypot(double x, double y) => math.sqrt(x * x + y * y);

bool drawsInk(PointerDeviceKind kind) {
  return kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      kind == PointerDeviceKind.mouse;
}

StrokePoint sampleFromPointer({
  required PointerEvent event,
  required double x,
  required double y,
  required double time,
  required double baseWidth,
}) {
  return StrokePoint(
    x: x,
    y: y,
    time: time,
    width: baseWidth,
    height: baseWidth,
    opacity: missingOpacity,
    pressure: _pressureOf(event),
    azimuth: _hasStylusPose(event) ? event.orientation : null,
    altitude: _hasStylusPose(event) ? (math.pi / 2) - event.tilt : null,
  );
}

bool _hasStylusPose(PointerEvent event) {
  return event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus;
}

double _pressureOf(PointerEvent event) {
  if (!_hasStylusPose(event) || event.pressureMax <= event.pressureMin) {
    return missingPressure;
  }
  return ((event.pressure - event.pressureMin) /
          (event.pressureMax - event.pressureMin))
      .clamp(0.0, 1.0);
}

const highlighterOpacity = 0.35;

/// Length up to a point, shared by live chunks so dash phase never restarts.
double strokeLength(List<StrokePoint> points) {
  var distance = 0.0;
  for (var i = 1; i < points.length; i++) {
    if (!points[i].gap) {
      distance += _hypot(
        points[i].x - points[i - 1].x,
        points[i].y - points[i - 1].y,
      );
    }
  }
  return distance;
}

void paintStroke(
  Canvas canvas,
  StrokeObject stroke, {
  double distanceOffset = 0,
  bool applyHighlighterOpacity = true,
}) {
  final translucent = stroke.tool == 'highlighter' && applyHighlighterOpacity;
  if (translucent) {
    var bounds = Rect.zero;
    for (final point in stroke.points) {
      final rect = Rect.fromCircle(
        center: Offset(point.x, point.y),
        radius: stroke.baseWidth + 2,
      );
      bounds = bounds.isEmpty ? rect : bounds.expandToInclude(rect);
    }
    canvas.saveLayer(
      bounds,
      Paint()..color = Color.fromRGBO(255, 255, 255, highlighterOpacity),
    );
  }
  _paintStrokeGeometry(canvas, stroke, stroke.dashOffset + distanceOffset);
  if (translucent) canvas.restore();
}

void _paintStrokeGeometry(
  Canvas canvas,
  StrokeObject stroke,
  double distanceOffset,
) {
  if (stroke.tool == 'fixed') {
    _paintFixed(canvas, stroke);
    return;
  }
  final paint = Paint()
    ..color = stroke.tool == 'highlighter'
        ? Color(stroke.color).withAlpha(255)
        : Color(stroke.color)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  final points = stroke.points;
  if (points.isEmpty) {
    return;
  }
  final solid = stroke.dashRatio >= 0.999 || stroke.dashCycle <= 0;
  if (points.length == 1) {
    if (!solid &&
        (stroke.dashRatio <= 0 ||
            distanceOffset % stroke.dashCycle >=
                stroke.dashCycle * stroke.dashRatio)) {
      return;
    }
    canvas.drawCircle(
      Offset(points.single.x, points.single.y),
      points.single.width / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  paint.style = PaintingStyle.stroke;
  if (solid) {
    _paintIsolated(canvas, paint, points);
    Path? path;
    var width = 0.0;
    void flush() {
      if (path != null) canvas.drawPath(path!, paint..strokeWidth = width);
      path = null;
    }

    for (var i = 0; i < points.length - 1; i++) {
      final start = points[i], end = points[i + 1];
      if (end.gap) {
        flush();
        continue;
      }
      final nextWidth = ((start.width + end.width) / 2 * 40).round() / 40;
      if (path == null || nextWidth != width) {
        flush();
        width = nextWidth;
        path = Path()..moveTo(start.x, start.y);
      }
      path!.lineTo(end.x, end.y);
    }
    flush();
    return;
  }
  final cycle = stroke.dashCycle;
  final on = cycle * stroke.dashRatio.clamp(0.0, 1.0);
  if (on <= 0) return;
  paint.style = PaintingStyle.fill;
  var traveled = distanceOffset;
  final run = <StrokePoint>[];
  void flush() {
    if (run.length > 1) canvas.drawPath(outlineOf(run), paint);
    run.clear();
  }

  for (var index = 0; index < points.length; index++) {
    final start = points[index];
    final isolated =
        (index == 0 || start.gap) &&
        (index == points.length - 1 || points[index + 1].gap);
    if (isolated && traveled % cycle < on) {
      canvas.drawCircle(Offset(start.x, start.y), start.width / 2, paint);
    }
    if (index == points.length - 1) break;
    final end = points[index + 1];
    if (end.gap) {
      flush();
      continue;
    }
    final length = _hypot(end.x - start.x, end.y - start.y);
    if (length == 0) continue;
    var local = 0.0;
    while (local < length) {
      final into = (traveled + local) % cycle;
      final drawing = into < on;
      final remain = drawing ? on - into : cycle - into;
      final step = math.min(math.max(remain, 1e-9), length - local);
      if (drawing) {
        if (run.isEmpty) run.add(_lerpSample(start, end, local / length));
        run.add(_lerpSample(start, end, (local + step) / length));
      } else {
        flush();
      }
      if (drawing && step >= remain) flush();
      local += step;
    }
    traveled += length;
  }
  flush();
}

void _paintFixed(Canvas canvas, StrokeObject stroke, {Paint? paint}) {
  final fill = Paint()
    ..color = paint?.color ?? Color(stroke.color)
    ..blendMode = paint?.blendMode ?? BlendMode.srcOver
    ..isAntiAlias = false
    ..style = PaintingStyle.fill;
  final points = stroke.points;
  var index = 0;
  while (index < points.length) {
    final start = points[index];
    if (index + 1 < points.length && !points[index + 1].gap) {
      final end = points[index + 1];
      final height = start.height;
      final left = math.min(start.x, end.x) - height / 2;
      final right = math.max(start.x, end.x) + height / 2;
      canvas.drawRect(
        Rect.fromLTRB(left, start.y - height / 2, right, start.y + height / 2),
        fill,
      );
      index += 2;
      continue;
    }
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(start.x, start.y),
        width: start.width,
        height: start.height,
      ),
      fill,
    );
    index += 1;
  }
}

void _paintIsolated(Canvas canvas, Paint paint, List<StrokePoint> points) {
  for (var index = 0; index < points.length; index++) {
    final point = points[index];
    final starts = index == 0 || point.gap;
    final ends = index == points.length - 1 || points[index + 1].gap;
    if (!starts || !ends) {
      continue;
    }
    canvas.drawCircle(
      Offset(point.x, point.y),
      point.width / 2,
      paint..style = PaintingStyle.fill,
    );
  }
  paint.style = PaintingStyle.stroke;
}

/// Draws a round stroke slightly wider than [paintStroke], so a wash or a cut covers the ink edge as well as the center.
void paintStrokeCover(
  Canvas canvas,
  StrokeObject stroke,
  Paint paint, {
  double pad = 0,
}) {
  if (stroke.tool == 'fixed') {
    _paintFixed(canvas, stroke, paint: paint);
    return;
  }
  final points = stroke.points;
  if (points.isEmpty) {
    return;
  }
  paint
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  if (points.length == 1) {
    canvas.drawCircle(
      Offset(points.single.x, points.single.y),
      points.single.width / 2 + pad,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  paint.style = PaintingStyle.stroke;
  for (var index = 0; index < points.length - 1; index++) {
    final start = points[index];
    final end = points[index + 1];
    if (end.gap) {
      continue;
    }
    canvas.drawLine(
      Offset(start.x, start.y),
      Offset(end.x, end.y),
      paint..strokeWidth = math.max(start.width, end.width) + pad * 2,
    );
  }
}

List<StrokeObject> undrawnStrokes(
  Set<String> drawnIds,
  List<StrokeObject> strokes,
) {
  return [
    for (final stroke in strokes)
      if (!drawnIds.contains(stroke.id)) stroke,
  ];
}

Path outlineOf(List<StrokePoint> points) {
  final path = Path();
  if (points.isEmpty) {
    return path;
  }
  if (points.length == 1) {
    final point = points.single;
    path.addOval(
      Rect.fromCircle(
        center: Offset(point.x, point.y),
        radius: point.width / 2,
      ),
    );
    return path;
  }
  final left = <Offset>[];
  final right = <Offset>[];
  for (var index = 0; index < points.length; index++) {
    final previous = index == 0 ? points[index] : points[index - 1];
    final next = index == points.length - 1 ? points[index] : points[index + 1];
    var dx = next.x - previous.x;
    var dy = next.y - previous.y;
    final length = _hypot(dx, dy);
    if (length == 0) {
      dx = 1;
      dy = 0;
    } else {
      dx /= length;
      dy /= length;
    }
    final half = points[index].width / 2;
    left.add(Offset(points[index].x - dy * half, points[index].y + dx * half));
    right.add(Offset(points[index].x + dy * half, points[index].y - dx * half));
  }
  path.moveTo(left.first.dx, left.first.dy);
  for (final point in left.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  for (final point in right.reversed) {
    path.lineTo(point.dx, point.dy);
  }
  path.close();
  return path;
}

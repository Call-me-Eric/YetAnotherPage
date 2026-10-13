import 'dart:ui';

import '../ids.dart';
import 'stroke.dart';

enum InkTool { pen, highlighter, text, objectEraser, regionEraser, lasso }

enum EraserKind { stroke, region }

enum LassoShape { free, rect }

/// Object categories selected independently by either lasso shape.
enum LassoTarget { stroke, text, highlighter }

const eraserRadius = 14.0;

bool strokeHitsEraser(
  StrokeObject stroke,
  List<Offset> eraser, {
  double radius = eraserRadius,
  Rect? near,
}) {
  return _hits(
    stroke.points,
    eraser,
    radius,
    query: near,
    stopAtFirst: true,
  ).hit;
}

/// Cuts [stroke] where the eraser passes. Unchanged strokes return null.
/// A full erase returns an empty list. A partial erase returns the remaining pieces.
List<StrokeObject>? eraseRegion(
  StrokeObject stroke,
  List<Offset> eraser, {
  double radius = eraserRadius,
}) {
  final hit = _hits(stroke.points, eraser, radius);
  if (!hit.hit) {
    return null;
  }
  final runs = <({List<StrokePoint> points, double offset})>[];
  final events = {...hit.erased, ...hit.cutAfter}.toList()..sort();
  final points = stroke.points;
  var from = 0;
  void append(int end) {
    if (end <= from) return;
    final offset = stroke.dashRatio >= 0.999 || stroke.dashCycle <= 0
        ? 0.0
        : points is FrozenStrokePoints
        ? points.distanceAt(from)
        : strokeLength(points.sublist(0, from + 1));
    runs.add((
      points: points is FrozenStrokePoints
          ? points.slice(from, end)
          : points.sublist(from, end),
      offset: stroke.dashOffset + offset,
    ));
  }

  for (final index in events) {
    if (hit.erased.contains(index)) {
      append(index);
      from = index + 1;
    } else if (hit.cutAfter.contains(index)) {
      append(index + 1);
      from = index + 1;
    }
  }
  append(points.length);
  return [
    for (final run in runs)
      if (run.points.isNotEmpty)
        StrokeObject(
          id: newId(),
          tool: stroke.tool,
          color: stroke.color,
          baseWidth: stroke.baseWidth,
          points: run.points,
          finalized: true,
          dashCycle: stroke.dashCycle,
          dashRatio: stroke.dashRatio,
          dashOffset: run.offset,
        ),
  ];
}

class _Hit {
  const _Hit({required this.hit, required this.erased, required this.cutAfter});

  final bool hit;
  final Set<int> erased;
  final Set<int> cutAfter;
}

_Hit _hits(
  List<StrokePoint> points,
  List<Offset> eraser,
  double radius, {
  Rect? query,
  bool stopAtFirst = false,
}) {
  final erased = <int>{}, cutAfter = <int>{};
  if (points.isEmpty || eraser.isEmpty) {
    return _Hit(hit: false, erased: erased, cutAfter: cutAfter);
  }
  var bounds = Rect.fromPoints(eraser.first, eraser.first);
  for (final point in eraser.skip(1)) {
    bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
  }
  final near = query ?? bounds.inflate(radius);
  final ranges = points is FrozenStrokePoints
      ? points.ranges(near)
      : [(0, points.length)];
  for (final range in ranges) {
    for (var index = range.$1; index < range.$2; index++) {
      final point = points[index];
      if (_nearEraser(
        Offset(point.x, point.y),
        eraser,
        radius + point.width / 2,
      )) {
        erased.add(index);
        if (stopAtFirst) {
          return _Hit(hit: true, erased: erased, cutAfter: cutAfter);
        }
      }
      if (index >= points.length - 1) continue;
      final end = points[index + 1];
      if (!end.gap &&
          _segmentHitsEraser(
            Offset(point.x, point.y),
            Offset(end.x, end.y),
            eraser,
            radius + (point.width + end.width) / 4,
          )) {
        cutAfter.add(index);
        if (stopAtFirst) {
          return _Hit(hit: true, erased: erased, cutAfter: cutAfter);
        }
      }
    }
  }
  return _Hit(
    hit: erased.isNotEmpty || cutAfter.isNotEmpty,
    erased: erased,
    cutAfter: cutAfter,
  );
}

bool _nearEraser(Offset point, List<Offset> eraser, double reach) {
  if (eraser.length == 1) {
    return (point - eraser.single).distance <= reach;
  }
  for (var index = 0; index < eraser.length - 1; index++) {
    if (_pointSegment(point, eraser[index], eraser[index + 1]) <= reach) {
      return true;
    }
  }
  return false;
}

bool _segmentHitsEraser(
  Offset start,
  Offset end,
  List<Offset> eraser,
  double reach,
) {
  if (eraser.length == 1) {
    return _pointSegment(eraser.single, start, end) <= reach;
  }
  for (var index = 0; index < eraser.length - 1; index++) {
    if (_segmentsHit(start, end, eraser[index], eraser[index + 1], reach)) {
      return true;
    }
  }
  return false;
}

bool _segmentsHit(Offset a, Offset b, Offset c, Offset d, double limit) {
  if (_cross(b - a, d - c).abs() > 1e-6) {
    final ab = b - a;
    final cd = d - c;
    final ac = c - a;
    final denom = _cross(ab, cd);
    final t = _cross(ac, cd) / denom;
    final u = _cross(ac, ab) / denom;
    if (t >= 0 && t <= 1 && u >= 0 && u <= 1) {
      return true;
    }
  }
  return _pointSegment(a, c, d) <= limit ||
      _pointSegment(b, c, d) <= limit ||
      _pointSegment(c, a, b) <= limit ||
      _pointSegment(d, a, b) <= limit;
}

double _pointSegment(Offset point, Offset start, Offset end) {
  final delta = end - start;
  final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
  if (lengthSquared == 0) {
    return (point - start).distance;
  }
  final t =
      ((point - start).dx * delta.dx + (point - start).dy * delta.dy) /
      lengthSquared;
  final clamped = t.clamp(0.0, 1.0);
  final nearest = Offset(
    start.dx + delta.dx * clamped,
    start.dy + delta.dy * clamped,
  );
  return (point - nearest).distance;
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

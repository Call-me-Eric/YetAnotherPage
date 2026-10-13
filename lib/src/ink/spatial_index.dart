import 'dart:ui';

import 'stroke.dart';

/// Incremental index of immutable strokes. Chunk bounds cover sparse segments
/// without visiting every historical sample again after each edit.
class StrokeSpatialIndex {
  static const cellSize = 128.0;
  final Map<String, StrokeObject> _known = {};
  final Map<String, Rect> _bounds = {};
  final Map<(int, int), Set<String>> _cells = {};
  final Map<String, Set<(int, int)>> _memberships = {};
  Map<String, int> _order = {};
  int indexedPoints = 0;

  void sync(Iterable<StrokeObject> strokes) {
    final order = <String, int>{};
    for (final stroke in strokes) {
      order[stroke.id] = order.length;
      if (_known.containsKey(stroke.id)) continue;
      _known[stroke.id] = stroke;
      final points = stroke.points;
      var overall = Rect.zero;
      final membership = <(int, int)>{};
      final blocks = points is FrozenStrokePoints
          ? points.chunkBounds
          : FrozenStrokePoints(points).chunkBounds;
      for (final rect in blocks) {
        overall = overall.isEmpty ? rect : overall.expandToInclude(rect);
        for (final cell in _keys(rect)) {
          _cells.putIfAbsent(cell, () => {}).add(stroke.id);
          membership.add(cell);
        }
      }
      indexedPoints += points.length;
      _bounds[stroke.id] = overall;
      _memberships[stroke.id] = membership;
    }
    for (final id in _known.keys.toList()) {
      if (order.containsKey(id)) continue;
      for (final cell in _memberships.remove(id) ?? <(int, int)>{}) {
        final bucket = _cells[cell]!;
        bucket.remove(id);
        if (bucket.isEmpty) _cells.remove(cell);
      }
      _known.remove(id);
      _bounds.remove(id);
    }
    _order = order;
  }

  Rect bounds(String id) => _bounds[id] ?? Rect.zero;

  List<StrokeObject> query(Rect rect, {Set<String> deleted = const {}}) =>
      queryRects([rect], deleted: deleted);

  List<StrokeObject> queryRects(
    Iterable<Rect> rects, {
    Set<String> deleted = const {},
  }) {
    final hits = <String>{};
    for (final rect in rects) {
      for (final cell in _keys(rect)) {
        for (final id in _cells[cell] ?? <String>{}) {
          if (_order.containsKey(id) &&
              !deleted.contains(id) &&
              _bounds[id]!.overlaps(rect)) {
            hits.add(id);
          }
        }
      }
    }
    final ids = hits.toList()..sort((a, b) => _order[a]!.compareTo(_order[b]!));
    return [for (final id in ids) _known[id]!];
  }

  Iterable<(int, int)> _keys(Rect rect) sync* {
    if (rect.isEmpty) return;
    for (
      var y = (rect.top / cellSize).floor();
      y <= (rect.bottom / cellSize).floor();
      y++
    ) {
      for (
        var x = (rect.left / cellSize).floor();
        x <= (rect.right / cellSize).floor();
        x++
      ) {
        yield (x, y);
      }
    }
  }
}

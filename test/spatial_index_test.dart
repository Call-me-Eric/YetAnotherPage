import 'package:flutter/foundation.dart';

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/ink/spatial_index.dart';
import 'package:yet_another_page/src/ink/stroke.dart';

void main() {
  StrokeObject line(String id, double x, double y, {double length = 20}) =>
      StrokeObject(
        id: id,
        tool: 'pen',
        color: penColor,
        baseWidth: 3,
        finalized: true,
        points: [
          for (var i = 0; i < 32; i++)
            mouseSample(
              x: x + length * i / 31,
              y: y,
              time: i * 0.008,
              baseWidth: 3,
            ),
        ],
      );
  test('ten thousand strokes reuse geometry and query only local candidates', () {
    final strokes = [
      for (var i = 0; i < 10000; i++)
        line('$i', (i % 100) * 40, (i ~/ 100) * 40),
    ];
    final index = StrokeSpatialIndex();
    final build = Stopwatch()..start();
    index.sync(strokes);
    build.stop();
    final count = index.indexedPoints;
    final queries = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      expect(
        index.query(const Rect.fromLTWH(390, 390, 60, 60)).length,
        lessThan(10),
      );
    }
    queries.stop();
    index.sync(strokes);
    expect(index.indexedPoints, count);
    final extra = line('extra', 4500, 4500);
    index.sync([...strokes, extra]);
    expect(index.indexedPoints, count + 32);
    debugPrint(
      '10000 strokes / 320000 samples: index ${build.elapsedMilliseconds} ms; 1000 local queries ${queries.elapsedMilliseconds} ms',
    );
  });
  test('sparse segment middles are indexed and inactive objects disappear', () {
    final index = StrokeSpatialIndex();
    final stroke = line('long', 0, 0, length: 1000);
    index.sync([stroke]);
    expect(index.query(const Rect.fromLTWH(499, -2, 2, 4)).single.id, 'long');
    index.sync([]);
    expect(index.query(const Rect.fromLTWH(499, -2, 2, 4)), isEmpty);
    index.sync([stroke]);
    expect(index.query(const Rect.fromLTWH(499, -2, 2, 4)).single.id, 'long');
  });
}

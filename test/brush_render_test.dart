import 'dart:ui' as ui;

import 'package:yet_another_page/src/ink/eraser.dart';
import 'package:yet_another_page/src/ink/selection.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/ink/stroke.dart';

void main() {
  StrokeObject stroke(String tool, List<StrokePoint> points) => StrokeObject(
    id: 'brush',
    tool: tool,
    color: 0xFFFFFF00,
    baseWidth: 12,
    points: points,
    finalized: true,
    dashCycle: 17,
    dashRatio: tool == 'pen' ? 0.4 : 1,
  );
  List<StrokePoint> line() => [
    for (var i = 0; i <= 180; i++)
      mouseSample(x: 10 + i.toDouble(), y: 30, time: i * 0.008, baseWidth: 12),
  ];
  Future<List<int>> render(void Function(ui.Canvas) draw) async {
    final recorder = ui.PictureRecorder();
    draw(ui.Canvas(recorder));
    final picture = recorder.endRecording();
    final image = await picture.toImage(220, 70);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return bytes;
  }

  test('dash chunks preserve phase exactly across cache boundaries', () async {
    final points = line();
    final whole = stroke('pen', points);
    final finalPixels = await render((canvas) => paintStroke(canvas, whole));
    final livePixels = await render((canvas) {
      final a = points.sublist(0, 58),
          b = points.sublist(57, 119),
          c = points.sublist(118);
      paintStroke(canvas, stroke('pen', a));
      paintStroke(canvas, stroke('pen', b), distanceOffset: strokeLength(a));
      paintStroke(
        canvas,
        stroke('pen', c),
        distanceOffset: strokeLength(points.sublist(0, 119)),
      );
    });
    // A split polygon can round edge coverage by one alpha level.
    for (var x = 10; x < 190; x++) {
      expect(
        livePixels[(30 * 220 + x) * 4 + 3],
        closeTo(finalPixels[(30 * 220 + x) * 4 + 3], 1),
        reason: 'x=$x',
      );
    }
  });
  test('a dashed curve has a connected outer edge at a turn', () async {
    final points = [
      for (final p in const [
        ui.Offset(10, 30),
        ui.Offset(30, 30),
        ui.Offset(30, 50),
      ])
        mouseSample(x: p.dx, y: p.dy, time: 0, baseWidth: 12),
    ];
    final curve = StrokeObject(
      id: 'curve',
      tool: 'pen',
      color: 0xFF000000,
      baseWidth: 12,
      finalized: true,
      points: points,
      dashCycle: 120,
      dashRatio: 0.5,
    );
    final pixels = await render((canvas) => paintStroke(canvas, curve));
    // The old independent butt-ended rectangles leave this outer join empty.
    expect(pixels[(28 * 220 + 32) * 4 + 3], greaterThan(200));
  });

  test('erasing and reloading never shifts distant dashes', () async {
    final whole = stroke('pen', line());
    final before = await render((canvas) => paintStroke(canvas, whole));
    final pieces = eraseRegion(whole, const [ui.Offset(45, 30)], radius: 2)!;
    final tail = pieces.last;
    final cutAgain = eraseRegion(tail, const [ui.Offset(85, 30)], radius: 2)!;
    final restored = StrokeObject.fromJson(cutAgain.last.toJson());
    final after = await render((canvas) => paintStroke(canvas, restored));
    for (var x = 105; x < 190; x++) {
      expect(
        after[(30 * 220 + x) * 4 + 3],
        before[(30 * 220 + x) * 4 + 3],
        reason: 'x=$x',
      );
    }
    expect(restored.dashOffset, closeTo(restored.points.first.x - 10, 1e-9));
    final scaled = mapStroke(restored, (p) => p * 2, widthScale: 2);
    expect(scaled.dashOffset, restored.dashOffset * 2);
    expect(scaled.dashCycle, restored.dashCycle * 2);
  });

  test('isolated samples in a dash gap stay invisible', () async {
    final points = [
      mouseSample(x: 10, y: 30, time: 0, baseWidth: 12),
      const StrokePoint(
        x: 50,
        y: 30,
        time: 1,
        width: 12,
        height: 12,
        opacity: 1,
        pressure: 0.5,
        gap: true,
      ),
    ];
    final pixels = await render(
      (canvas) =>
          paintStroke(canvas, stroke('pen', points).copyWith(dashOffset: 10)),
    );
    expect(pixels.every((channel) => channel == 0), isTrue);
  });

  test(
    'highlighter opacity is applied once per stroke, including self crossings',
    () async {
      final points = [
        for (final p in const [
          ui.Offset(10, 30),
          ui.Offset(190, 30),
          ui.Offset(10, 30),
        ])
          mouseSample(x: p.dx, y: p.dy, time: 0, baseWidth: 12),
      ];
      final mark = stroke('highlighter', points);
      final single = await render((canvas) => paintStroke(canvas, mark));
      final overlap = await render((canvas) {
        paintStroke(canvas, mark);
        paintStroke(canvas, mark);
      });
      final alpha = (30 * 220 + 100) * 4 + 3;
      expect(single[alpha], inInclusiveRange(88, 90));
      expect(overlap[alpha], inInclusiveRange(146, 148));
      final grouped = await render((canvas) {
        canvas.saveLayer(
          null,
          ui.Paint()
            ..color = const ui.Color.fromRGBO(
              255,
              255,
              255,
              highlighterOpacity,
            ),
        );
        paintStroke(
          canvas,
          stroke('highlighter', points.sublist(0, 2)),
          applyHighlighterOpacity: false,
        );
        paintStroke(
          canvas,
          stroke('highlighter', points.sublist(1)),
          applyHighlighterOpacity: false,
        );
        canvas.restore();
      });
      expect(grouped[alpha], single[alpha]);
    },
  );
}

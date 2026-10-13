import 'package:yet_another_page/src/ui/text_box_view.dart';
import 'package:yet_another_page/src/ui/pen_settings.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:yet_another_page/src/ui/page_canvas.dart';
import 'package:yet_another_page/src/ink/marks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/ink/stroke.dart';
import 'package:yet_another_page/src/ink/text_box.dart';
import 'package:yet_another_page/src/paper.dart';
import 'package:yet_another_page/src/storage/note_document.dart';
import 'package:yet_another_page/src/storage/vault.dart';
import 'package:yet_another_page/src/input/stylus_side_button.dart';
import 'package:yet_another_page/src/ui/library_page.dart';
import 'package:yet_another_page/src/ui/note_page.dart';

void main() {
  PageCanvas canvas(WidgetTester tester) =>
      tester.widget(find.byType(PageCanvas));
  List<StrokeObject> ink(WidgetTester tester) =>
      liveStrokes(canvas(tester).pages.first.layers.first);
  Future<void> draw(WidgetTester tester, double y) async {
    final c = canvas(tester);
    c.onStrokeStart(
      'page-1',
      PointerDownEvent(
        kind: PointerDeviceKind.stylus,
        position: Offset(100, y),
      ),
    );
    for (var i = 1; i < 20; i++) {
      c.onStrokeMove(
        'page-1',
        PointerMoveEvent(
          kind: PointerDeviceKind.stylus,
          position: Offset(100 + i * 5, y),
          timeStamp: Duration(milliseconds: i * 8),
        ),
      );
    }
    c.onStrokeEnd('page-1');
    await tester.pump();
  }

  testWidgets(
    'dense pages support draw, erase, selection transforms and zoom',
    (tester) async {
      final library = _MemoryLibrary();
      var note = await library.createNote('密集页面');
      final strokes = [
        for (var i = 0; i < 3000; i++)
          StrokeObject(
            id: 'dense-$i',
            tool: 'pen',
            color: penColor,
            baseWidth: 3,
            finalized: true,
            points: [
              for (var p = 0; p < 8; p++)
                mouseSample(
                  x: (i % 50) * 11 + p.toDouble(),
                  y: (i ~/ 50) * 13 + 20,
                  time: p * 0.008,
                  baseWidth: 3,
                ),
            ],
          ),
      ];
      note = applyMarks(
        note,
        pageId: 'page-1',
        layerId: 'layer-1',
        add: strokes,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NotePage(vault: library, note: note),
        ),
      );
      await tester.pump();
      await draw(tester, 350);
      expect(ink(tester), hasLength(3001));
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(ink(tester), hasLength(3000));
      await tester.tap(find.byTooltip('橡皮'));
      await tester.pump();
      canvas(tester).onEraseStart('page-1', const Offset(100, 350));
      canvas(tester).onEraseEnd('page-1');
      await tester.pump();
      expect(ink(tester).length, lessThan(3000));
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(ink(tester), hasLength(3000));
      await tester.tap(find.byTooltip('套索'));
      await tester.pump();
      final c = canvas(tester);
      c.onLassoStart!('page-1', const Offset(20, 280));
      c.onLassoMove!('page-1', const Offset(220, 280));
      c.onLassoMove!('page-1', const Offset(220, 380));
      c.onLassoMove!('page-1', const Offset(20, 380));
      c.onLassoEnd!('page-1', const Offset(20, 280));
      await tester.pump();
      expect(ink(tester).length, lessThan(3000));
      for (var i = 0; i < 12; i++) {
        canvas(tester).onSelectionMove!(Offset(100 + i.toDouble(), 330));
        await tester.pump();
      }
      canvas(tester).onSelectionMoveEnd!();
      canvas(tester).onSelectionClear!();
      await tester.pump();
      expect(ink(tester), hasLength(3000));
      for (final scale in [4.0, 0.5, 2.0, 1.0]) {
        final c = canvas(tester);
        c.transformation.value = Matrix4.identity()
          ..translateByDouble(-48 * scale, -200 * scale, 0, 1)
          ..scaleByDouble(scale, scale, 1, 1);
        c.onScaleSettled!();
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('highlighter works with history, erase, lasso and quick tools', (
    tester,
  ) async {
    final library = _MemoryLibrary();
    final note = await library.createNote('荧光');
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('放大'), findsNothing);
    expect(find.byTooltip('缩小'), findsNothing);
    await tester.tap(find.byTooltip('荧光笔'));
    await tester.pump();
    await draw(tester, 350);
    final highlight = ink(tester).single;
    expect(highlight.tool, 'highlighter');
    expect(highlight.color, 0xFFFFFF00);
    expect(highlight.points.every((point) => point.width == 18), isTrue);
    await tester.tap(find.byTooltip('钢笔'));
    await tester.pump();
    await draw(tester, 400);
    expect(ink(tester).last.tool, 'pen');
    expect(ink(tester).last.color, penColor);
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(ink(tester).single.tool, 'highlighter');
    await tester.tap(find.byTooltip('橡皮'));
    await tester.pump();
    canvas(tester).onEraseStart('page-1', const Offset(150, 350));
    canvas(tester).onEraseEnd('page-1');
    await tester.pump();
    expect(ink(tester), isEmpty);
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(ink(tester).single.id, highlight.id);
    await tester.tap(find.byTooltip('套索'));
    await tester.pump();
    final c = canvas(tester);
    c.onLassoStart!('page-1', const Offset(90, 330));
    c.onLassoMove!('page-1', const Offset(210, 330));
    c.onLassoMove!('page-1', const Offset(210, 370));
    c.onLassoMove!('page-1', const Offset(90, 370));
    c.onLassoEnd!('page-1', const Offset(90, 330));
    await tester.pump();
    expect(ink(tester), isEmpty);
    canvas(tester).onSelectionClear!();
    await tester.pump();
    expect(ink(tester).single.tool, 'highlighter');
    stylusSideButton.report(const Offset(240, 320));
    await tester.pump();
    expect(find.byKey(const ValueKey('arc-highlighter')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('arc-highlighter')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pen-preset-arc')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'crossing ink survives object erase and new ink is visible there',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final library = _MemoryLibrary();
      var note = await library.createNote('交叉');
      StrokeObject line(String id, int color, Offset a, Offset b) =>
          StrokeObject(
            id: id,
            tool: 'pen',
            color: color,
            baseWidth: 6,
            finalized: true,
            points: [
              mouseSample(x: a.dx, y: a.dy, time: 0, baseWidth: 6),
              mouseSample(x: b.dx, y: b.dy, time: 0.1, baseWidth: 6),
            ],
          );
      note = applyMarks(
        note,
        pageId: 'page-1',
        layerId: 'layer-1',
        add: [
          line(
            'red',
            0xffff0000,
            const Offset(100, 150),
            const Offset(200, 150),
          ),
          line(
            'blue',
            0xff0000ff,
            const Offset(150, 100),
            const Offset(150, 200),
          ),
        ],
      );
      const boundaryKey = ValueKey('capture');
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundaryKey,
            child: NotePage(vault: library, note: note),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      Future<List<int>> pixel(Offset at) async {
        await tester.pump();
        final box = tester.renderObject<RenderBox>(
          find
              .byWidgetPredicate(
                (widget) => widget.runtimeType.toString() == '_PageSheet',
              )
              .first,
        );
        final global = box.localToGlobal(at);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        final local = boundary.globalToLocal(global);
        final rgba = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final i = (local.dy.round() * image.width + local.dx.round()) * 4;
          final result = data!.buffer
              .asUint8List(data.offsetInBytes + i, 4)
              .toList();
          image.dispose();
          return result;
        });
        return rgba!;
      }

      expect(await pixel(const Offset(150, 150)), [0, 0, 255, 255]);
      await tester.tap(find.byTooltip('橡皮'));
      await tester.pump();
      canvas(tester).onEraseStart('page-1', const Offset(105, 150));
      canvas(tester).onEraseEnd('page-1');
      await tester.pump();
      expect(ink(tester).single.id, 'blue');
      expect(await pixel(const Offset(150, 150)), [0, 0, 255, 255]);
      await tester.tap(find.byTooltip('钢笔'));
      await tester.pump();
      await draw(tester, 150);
      final rgba = await pixel(const Offset(130, 150));
      expect(rgba[0], lessThan(100));
      expect(rgba[1], lessThan(100));
      expect(rgba[2], lessThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving a note waits for pending writes', (tester) async {
    final library = _MemoryLibrary()..saveGate = Completer<void>();
    final note = await library.createNote('退出');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NotePage(vault: library, note: note),
              ),
            ),
            child: const Text('打开测试笔记'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开测试笔记'));
    await tester.pumpAndSettle();
    await draw(tester, 150);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(NotePage), findsOneWidget);
    library.saveGate!.complete();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(NotePage), findsNothing);
    expect(
      liveStrokes(
        (await library.openNote(note.directoryName)).pages.first.layers.first,
      ),
      hasLength(1),
    );
  });

  testWidgets(
    'region erase updates before lift and one undo restores the stroke',
    (tester) async {
      final library = _MemoryLibrary();
      final note = await library.createNote('擦除');
      await tester.pumpWidget(
        MaterialApp(
          home: NotePage(vault: library, note: note),
        ),
      );
      await tester.pump();
      await draw(tester, 150);
      final original = ink(tester).single.id;
      await tester.tap(find.byTooltip('橡皮'));
      await tester.pump();
      await tester.tap(find.byTooltip('橡皮'));
      await tester.pump();
      await tester.tap(find.text('区域'));
      await tester.pump();
      canvas(tester).onEraseStart('page-1', const Offset(150, 150));
      await tester.pump();
      expect(ink(tester).every((stroke) => stroke.id != original), isTrue);
      expect(ink(tester), hasLength(2));
      canvas(tester).onEraseMove('page-1', const Offset(160, 150));
      canvas(tester).onEraseEnd('page-1');
      await tester.pump();
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(ink(tester).single.id, original);
      await tester.tap(find.byTooltip('重做'));
      await tester.pump();
      expect(ink(tester).every((stroke) => stroke.id != original), isTrue);
      await tester.tap(find.byTooltip('钢笔'));
      await tester.pump();
      await draw(tester, 150);
      expect(ink(tester).length, greaterThan(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('slow text save cannot overwrite a newer stroke or its undo', (
    tester,
  ) async {
    final library = _MemoryLibrary()..saveGate = Completer<void>();
    final note = await library.createNote('保存');
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();
    canvas(tester).onTextCreate('page-1', const Rect.fromLTWH(20, 20, 100, 60));
    await tester.pump();
    await draw(tester, 150);
    expect(ink(tester), hasLength(1));
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(ink(tester), isEmpty);
    library.saveGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(ink(tester), isEmpty);
    final saved = await library.openNote(note.directoryName);
    expect(liveStrokes(saved.pages.first.layers.first), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text is interleaved with strokes on its layer', (tester) async {
    final library = _MemoryLibrary();
    var note = await library.createNote('顺序');
    StrokeObject line(String id, double y) => StrokeObject(
      id: id,
      tool: 'pen',
      color: penColor,
      baseWidth: 3,
      points: [mouseSample(x: 100, y: y, time: 0, baseWidth: 3)],
      finalized: true,
    );
    note = applyMarks(
      note,
      pageId: 'page-1',
      layerId: 'layer-1',
      add: [line('under', 150)],
    );
    note = await library.saveTextBox(
      note,
      pageId: 'page-1',
      layerId: 'layer-1',
      box: const TextBox(
        id: 'box',
        version: 1,
        x: 90,
        y: 140,
        width: 120,
        height: 60,
        source: '文字',
      ),
    );
    note = applyMarks(
      note,
      pageId: 'page-1',
      layerId: 'layer-1',
      add: [line('above', 160)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();
    final group = tester.widget<Stack>(
      find
          .ancestor(of: find.byType(TextBoxLayer), matching: find.byType(Stack))
          .first,
    );
    expect(group.children[0].runtimeType.toString(), '_CommittedInk');
    expect(group.children[1], isA<Positioned>());
    expect(group.children[2].runtimeType.toString(), '_CommittedInk');
    expect(tester.takeException(), isNull);
  });

  testWidgets('lasso move is one undo command and one redo command', (
    tester,
  ) async {
    final library = _MemoryLibrary();
    final note = await library.createNote('套索');
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();
    await draw(tester, 150);
    final original = ink(tester).single;
    await tester.tap(find.byTooltip('套索'));
    await tester.pump();
    final c = canvas(tester);
    c.onLassoStart!('page-1', const Offset(90, 130));
    c.onLassoMove!('page-1', const Offset(210, 130));
    c.onLassoMove!('page-1', const Offset(210, 170));
    c.onLassoMove!('page-1', const Offset(90, 170));
    c.onLassoEnd!('page-1', const Offset(90, 130));
    await tester.pump();
    expect(ink(tester), isEmpty);
    canvas(tester).onSelectionMove!(const Offset(150, 150));
    canvas(tester).onSelectionMove!(const Offset(200, 180));
    canvas(tester).onSelectionMoveEnd!();
    canvas(tester).onSelectionClear!();
    await tester.pump();
    expect(
      ink(tester).single.points.first.x,
      closeTo(original.points.first.x + 50, 0.001),
    );
    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(ink(tester).single.id, original.id);
    await tester.tap(find.byTooltip('重做'));
    await tester.pump();
    expect(
      ink(tester).single.points.first.x,
      closeTo(original.points.first.x + 50, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('create a note and open it again', (tester) async {
    final library = _MemoryLibrary();

    await tester.pumpWidget(MaterialApp(home: LibraryPage(vault: library)));
    await tester.pump();
    expect(find.text('还没有笔记'), findsOneWidget);

    await tester.tap(find.text('新建笔记'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '第一章');
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text((await library.listNotes()).single.pages.single.id),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('图层'));
    await tester.pumpAndSettle();
    expect(find.text('墨水'), findsOneWidget);

    Navigator.of(tester.element(find.text('墨水'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    Navigator.of(tester.element(find.byTooltip('图层'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
  });

  testWidgets('a stylus side button opens and closes the tool arc', (
    tester,
  ) async {
    final library = _MemoryLibrary();
    final note = await library.createNote('笔');
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();

    stylusSideButton.report(const Offset(240, 320));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-arc')), findsOneWidget);
    expect(find.byKey(const ValueKey('pen-preset-arc')), findsOneWidget);
    expect(find.byKey(const ValueKey('arc-pen')), findsOneWidget);
    expect(find.byKey(const ValueKey('arc-eraser')), findsOneWidget);
    expect(find.byKey(const ValueKey('arc-lasso')), findsOneWidget);
    expect(find.byKey(const ValueKey('arc-paste')), findsOneWidget);
    expect(find.byKey(const ValueKey('arc-redo')), findsOneWidget);
    expect(find.byKey(const ValueKey('arc-region-eraser')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('arc-text')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-arc')), findsOneWidget);
    expect(find.byKey(const ValueKey('pen-preset-arc')), findsNothing);
    stylusSideButton.report(const Offset(240, 320));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-arc')), findsNothing);

    await tester.tap(find.byTooltip('钢笔'));
    await tester.pump();
    stylusSideButton.report(const Offset(240, 320));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-arc')), findsOneWidget);
    expect(find.byKey(const ValueKey('pen-preset-arc')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('arc-eraser')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-arc')), findsOneWidget);
    expect(find.byKey(const ValueKey('pen-preset-arc')), findsNothing);
    expect(find.byKey(const ValueKey('eraser-options')), findsOneWidget);

    stylusSideButton.report(const Offset(240, 320));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-arc')), findsNothing);
    expect(find.byKey(const ValueKey('eraser-options')), findsNothing);
  });

  testWidgets('hover uses selected ink color and highlighter width and alpha', (
    tester,
  ) async {
    final library = _MemoryLibrary();
    final note = await library.createNote('悬停');
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('钢笔'));
    await tester.pumpAndSettle();
    final presets = tester.widget<PenPresetBar>(find.byType(PenPresetBar));
    presets.onChanged(presets.palette.selectColor(2));
    await tester.pump();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(PageCanvas)),
    );
    await gesture.moveTo(
      tester.getCenter(find.byType(PageCanvas)) + const Offset(1, 1),
    );
    await tester.pump();

    Future<List<int>> tipPixels() async {
      final tip = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('ink-tip')),
      );
      final recorder = ui.PictureRecorder();
      tip.painter!.paint(ui.Canvas(recorder), tip.size);
      final picture = recorder.endRecording();
      return (await tester.runAsync(() async {
        final image = await picture.toImage(
          tip.size.width.ceil(),
          tip.size.height.ceil(),
        );
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!.buffer.asUint8List().toList();
        image.dispose();
        picture.dispose();
        return bytes;
      }))!;
    }

    var pixels = await tipPixels();
    final penTip = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('ink-tip')),
    );
    var side = penTip.size.width.ceil();
    var center = ((side ~/ 2) * side + side ~/ 2) * 4;
    expect(pixels.sublist(center, center + 4), [255, 0, 0, 255]);

    await tester.tap(find.byTooltip('荧光笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('荧光笔'));
    await tester.pumpAndSettle();
    final highlightPresets = tester.widget<PenPresetBar>(
      find.byType(PenPresetBar),
    );
    highlightPresets.onChanged(
      highlightPresets.palette.selectColor(2).selectWidth(2),
    );
    await tester.pump();
    pixels = await tipPixels();
    final highlightTip = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('ink-tip')),
    );
    side = highlightTip.size.width.ceil();
    center = ((side ~/ 2) * side + side ~/ 2) * 4;
    expect(
      highlightTip.size.width,
      24 + 4,
    ); // Full brush diameter plus preview padding.
    // Converting the 8-bit premultiplied preview back to RGB can round by one.
    expect(pixels[center], closeTo(85, 1));
    expect(pixels[center + 1], closeTo(204, 1));
    expect(pixels[center + 2], 255);
    expect(pixels[((side ~/ 2) * side + 1) * 4 + 3], 0);
    expect(pixels[((side ~/ 2) * side + 3) * 4 + 3], inInclusiveRange(88, 90));
    expect(pixels[center + 3], inInclusiveRange(88, 90));
    await draw(tester, 250);
    expect(ink(tester).single.color, canvas(tester).penColor);
    expect(ink(tester).single.points.every((p) => p.width == 24), isTrue);
    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the pen tool shows size, color, and dash presets', (
    tester,
  ) async {
    final library = _MemoryLibrary();
    final note = await library.createNote('笔');
    await tester.pumpWidget(
      MaterialApp(
        home: NotePage(vault: library, note: note),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('钢笔'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pen-presets')), findsOneWidget);
    expect(find.text('1.5'), findsOneWidget);
    expect(find.text('3.0'), findsOneWidget);
    expect(find.text('6.0'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
  });
}

class _MemoryLibrary implements NoteLibrary {
  final Map<String, OpenNote> _notes = {};
  Completer<void>? saveGate;

  @override
  Future<List<OpenNote>> listNotes() async => _notes.values.toList();

  @override
  Future<List<NoteSummary>> listSummaries() async {
    return [
      for (final note in _notes.values)
        NoteSummary(directoryName: note.directoryName, manifest: note.manifest),
    ];
  }

  @override
  Future<OpenNote> createNote(String title) async {
    final note = OpenNote(
      directoryName: '$title.yep',
      manifest: NoteManifest(
        id: 'note-1',
        title: title,
        formatVersion: formatVersion,
        pageOrder: const ['page-1'],
      ),
      pages: const [
        PageFile(
          id: 'page-1',
          width: a4Width,
          height: a4Height,
          layers: [
            LayerFile(
              id: 'layer-1',
              name: defaultInkLayerName,
              objects: [],
              deletedObjectIds: [],
            ),
          ],
          deletedLayerIds: [],
        ),
      ],
    );
    _notes[note.directoryName] = note;
    return note;
  }

  @override
  Future<OpenNote> openNote(String directoryName) async =>
      _notes[directoryName]!;

  @override
  Future<OpenNote> renameNote(OpenNote note, String title) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> insertPage(
    OpenNote note, {
    required String pageId,
    required bool before,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> deletePage(OpenNote note, {required String pageId}) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteNote(OpenNote note) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> moveLayer(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool upward,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> setLayerVisible(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool visible,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> setLayerLocked(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool locked,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> saveTextBox(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required TextBox box,
  }) async {
    await saveGate?.future;
    final updated = OpenNote(
      directoryName: note.directoryName,
      manifest: note.manifest,
      pages: [
        for (final page in note.pages)
          if (page.id != pageId)
            page
          else
            page.updateLayer(
              layerId,
              (layer) => layer.copyWith(
                objects: [
                  for (final object in layer.objects)
                    if (TextBox.fromObject(object)?.id != box.id) object,
                  box.toJson(),
                ],
              ),
            ),
      ],
    );
    _notes[note.directoryName] = updated;
    return updated;
  }

  @override
  Future<OpenNote> saveStroke(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required StrokeObject stroke,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenNote> changeMarks(
    OpenNote note, {
    required String pageId,
    required String layerId,
    List<StrokeObject> add = const [],
    List<String> tombstone = const [],
    List<String> restore = const [],
  }) async {
    await saveGate?.future;
    final updated = applyMarks(
      note,
      pageId: pageId,
      layerId: layerId,
      add: add,
      tombstone: tombstone,
      restore: restore,
    );
    _notes[note.directoryName] = updated;
    return updated;
  }
}

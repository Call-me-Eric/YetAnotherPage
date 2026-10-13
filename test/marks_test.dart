import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/ink/marks.dart';
import 'package:yet_another_page/src/ink/stroke.dart';
import 'package:yet_another_page/src/paper.dart';
import 'package:yet_another_page/src/storage/note_document.dart';

void main() {
  OpenNote noteWith(StrokeObject stroke) {
    const pageId = 'page';
    const layerId = 'layer';
    return OpenNote(
      directoryName: 't.yep',
      manifest: const NoteManifest(
        id: 'n',
        title: 't',
        formatVersion: formatVersion,
        pageOrder: [pageId],
      ),
      pages: [
        PageFile(
          id: pageId,
          width: a4Width,
          height: a4Height,
          deletedLayerIds: const [],
          layers: [
            LayerFile(
              id: layerId,
              name: defaultInkLayerName,
              objects: [stroke.toJson()],
              deletedObjectIds: const [],
            ),
          ],
        ),
      ],
    );
  }

  StrokeObject stroke(String id) {
    return StrokeObject(
      id: id,
      tool: 'pen',
      color: penColor,
      baseWidth: penBaseWidth,
      points: [
        mouseSample(x: 0, y: 0, time: 0, baseWidth: penBaseWidth),
        mouseSample(x: 10, y: 0, time: 0.1, baseWidth: penBaseWidth),
      ],
      finalized: true,
    );
  }

  test('applyMarks tombstones and restores without dropping objects', () {
    final a = stroke('a');
    var note = noteWith(a);
    note = applyMarks(
      note,
      pageId: 'page',
      layerId: 'layer',
      tombstone: const ['a'],
    );
    expect(liveStrokes(note.pages.single.layers.single), isEmpty);
    expect(note.pages.single.layers.single.objects, hasLength(1));

    note = applyMarks(
      note,
      pageId: 'page',
      layerId: 'layer',
      restore: const ['a'],
    );
    expect(liveStrokes(note.pages.single.layers.single).single.id, 'a');
  });

  test('duplicates in one add batch create only one object', () {
    final b = stroke('b');
    final note = applyMarks(
      noteWith(stroke('a')),
      pageId: 'page',
      layerId: 'layer',
      add: [b, b],
    );
    expect(note.pages.single.layers.single.objects, hasLength(2));
  });

  test('applyMarks add is idempotent and undo tombstones the new id', () {
    final a = stroke('a');
    var note = noteWith(a);
    final b = stroke('b');
    note = applyMarks(note, pageId: 'page', layerId: 'layer', add: [b]);
    note = applyMarks(note, pageId: 'page', layerId: 'layer', add: [b]);
    expect(note.pages.single.layers.single.objects, hasLength(2));

    note = applyMarks(
      note,
      pageId: 'page',
      layerId: 'layer',
      tombstone: const ['b'],
    );
    final live = liveStrokes(note.pages.single.layers.single);
    expect(live.map((s) => s.id), ['a']);
  });
}

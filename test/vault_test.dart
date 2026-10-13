import 'package:yet_another_page/src/ink/pen_palette.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/ink/marks.dart';
import 'package:yet_another_page/src/ink/stroke.dart';
import 'package:yet_another_page/src/ink/text_box.dart';
import 'package:yet_another_page/src/paper.dart';
import 'package:yet_another_page/src/storage/note_document.dart';
import 'package:yet_another_page/src/storage/vault.dart';

void main() {
  late Directory root;
  late Vault vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yep-vault-');
    vault = Vault(root);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'highlighter settings and geometry survive reopening independently',
    () async {
      await vault.writePenPalette(
        PenPalette.highlighter().selectWidth(0),
        highlighter: true,
      );
      expect((await vault.readPenPalette()).width, 3);
      expect((await vault.readPenPalette(highlighter: true)).width, 12);
      final note = await vault.createNote('荧光笔');
      final mark = StrokeObject(
        id: 'marker',
        tool: 'highlighter',
        color: 0xFFFFFF00,
        baseWidth: 18,
        points: [
          mouseSample(x: 10, y: 10, time: 0, baseWidth: 18),
          mouseSample(x: 100, y: 10, time: 0.1, baseWidth: 18),
        ],
        finalized: true,
      );
      await vault.saveStroke(
        note,
        pageId: note.pages.single.id,
        layerId: note.pages.single.layers.single.id,
        stroke: mark,
      );
      final reopened = await vault.openNote(note.directoryName);
      final stored = liveStrokes(reopened.pages.single.layers.single).single;
      expect(stored.tool, 'highlighter');
      expect(stored.points.last.width, 18);
    },
  );

  test('unfinished samples recover after a truncated journal tail', () async {
    final note = await vault.createNote('恢复');
    final pageId = note.pages.single.id;
    final layerId = note.pages.single.layers.single.id;
    final draft = StrokeObject(
      id: 'draft',
      tool: 'pen',
      color: penColor,
      baseWidth: 3,
      points: const [],
      finalized: false,
    );
    final samples = [
      mouseSample(x: 10, y: 20, time: 0, baseWidth: 3),
      mouseSample(x: 30, y: 20, time: 0.01, baseWidth: 3),
    ];
    await vault.checkpointStroke(
      note.directoryName,
      pageId: pageId,
      layerId: layerId,
      stroke: draft,
      samples: samples,
    );
    final file = File(
      '${root.path}/${note.directoryName}/pages/$pageId/journal/draft.jsonl',
    );
    await file.writeAsString('{"x":', mode: FileMode.append);
    final recovered = await vault.openNote(note.directoryName);
    final ink = liveStrokes(recovered.pages.single.layers.single);
    expect(ink.single.id, 'draft');
    expect(ink.single.finalized, isTrue);
    expect(ink.single.points.last.x, 30);
    expect(await file.exists(), isFalse);
    expect(
      liveStrokes(
        (await vault.openNote(note.directoryName)).pages.single.layers.single,
      ),
      hasLength(1),
    );
  });

  test('a stale checkpoint cannot resurrect an erased object', () async {
    var note = await vault.createNote('旧日志');
    final pageId = note.pages.single.id;
    final layerId = note.pages.single.layers.single.id;
    final point = mouseSample(x: 10, y: 20, time: 0, baseWidth: 3);
    final stroke = StrokeObject(
      id: 'done',
      tool: 'pen',
      color: penColor,
      baseWidth: 3,
      points: [point],
      finalized: true,
    );
    await vault.checkpointStroke(
      note.directoryName,
      pageId: pageId,
      layerId: layerId,
      stroke: stroke,
      samples: [point],
    );
    note = await vault.changeMarks(
      note,
      pageId: pageId,
      layerId: layerId,
      add: [stroke],
      tombstone: ['done'],
    );
    final reopened = await vault.openNote(note.directoryName);
    expect(liveStrokes(reopened.pages.single.layers.single), isEmpty);
    expect(
      reopened.pages.single.layers.single.deletedObjectIds,
      contains('done'),
    );
  });

  test(
    'a provisional stroke file can be extended before finalization',
    () async {
      var note = await vault.createNote('草稿');
      final pageId = note.pages.single.id;
      final layerId = note.pages.single.layers.single.id;
      final draft = StrokeObject(
        id: 'draft',
        tool: 'pen',
        color: penColor,
        baseWidth: 3,
        points: [mouseSample(x: 10, y: 20, time: 0, baseWidth: 3)],
        finalized: false,
      );
      note = await vault.saveStroke(
        note,
        pageId: pageId,
        layerId: layerId,
        stroke: draft,
      );
      final finished = draft.copyWith(
        finalized: true,
        points: [
          ...draft.points,
          mouseSample(x: 30, y: 20, time: 0.1, baseWidth: 3),
        ],
      );
      await vault.saveStroke(
        note,
        pageId: pageId,
        layerId: layerId,
        stroke: finished,
      );
      final reopened = await vault.openNote(note.directoryName);
      expect(
        liveStrokes(reopened.pages.single.layers.single).single.points,
        hasLength(2),
      );
    },
  );

  test(
    'missing referenced ink fails visibly instead of silently dropping it',
    () async {
      var note = await vault.createNote('缺失文件');
      final pageId = note.pages.single.id;
      final layerId = note.pages.single.layers.single.id;
      final stroke = StrokeObject(
        id: 'missing',
        tool: 'pen',
        color: penColor,
        baseWidth: 3,
        points: [mouseSample(x: 1, y: 2, time: 0, baseWidth: 3)],
        finalized: true,
      );
      note = await vault.changeMarks(
        note,
        pageId: pageId,
        layerId: layerId,
        add: [stroke],
      );
      await File(
        '${root.path}/${note.directoryName}/pages/$pageId/strokes/missing.json',
      ).delete();
      await expectLater(
        vault.openNote(note.directoryName),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('device id stays in the vault and out of the note', () async {
    final first = await vault.deviceId();
    final again = await Vault(root).deviceId();
    expect(again, first);

    final note = await vault.createNote('力学');
    final manifest = jsonDecode(
      await File('${root.path}/${note.directoryName}/manifest.json')
          .readAsString(),
    ) as Map<String, Object?>;
    expect(manifest.containsKey('deviceId'), isFalse);
    expect(File('${root.path}/device.json').existsSync(), isTrue);
  });

  test(
    'create, close, and reopen keeps the page id and A4 ink layer',
    () async {
      final created = await vault.createNote('  ');
      final pageId = created.pages.single.id;
      final layerId = created.pages.single.layers.single.id;

      final reopened = await Vault(root).openNote(created.directoryName);
      expect(reopened.manifest.id, created.id);
      expect(reopened.manifest.formatVersion, formatVersion);
      expect(reopened.manifest.pageOrder, [pageId]);
      expect(reopened.title, '未命名');

      final page = reopened.pages.single;
      expect(page.id, pageId);
      expect(page.width, a4Width);
      expect(page.height, a4Height);
      expect(page.deletedLayerIds, isEmpty);
      expect(page.layers.single.id, layerId);
      expect(page.layers.single.name, defaultInkLayerName);
      expect(page.layers.single.objects, isEmpty);
      expect(page.layers.single.deletedObjectIds, isEmpty);

      final pageDirectory = Directory(
        '${root.path}/${created.directoryName}/pages/$pageId',
      );
      expect(File('${pageDirectory.path}/page.json').existsSync(), isTrue);
      expect(File('${pageDirectory.path}/$layerId.json').existsSync(), isTrue);
      expect(
        Directory('${root.path}/${created.directoryName}/assets').existsSync(),
        isTrue,
      );
      expect(File('${pageDirectory.path}/page.json.tmp').existsSync(), isFalse);
    },
  );

  test('rename keeps the note id and page id', () async {
    final created = await vault.createNote('旧标题');
    final renamed = await vault.renameNote(created, '新标题');

    expect(renamed.directoryName, '新标题.yep');
    expect(renamed.id, created.id);
    expect(renamed.pages.single.id, created.pages.single.id);
    expect(Directory('${root.path}/旧标题.yep').existsSync(), isFalse);

    final listed = await Vault(root).listNotes();
    expect(listed.single.title, '新标题');
    expect(listed.single.pages.single.id, created.pages.single.id);
  });

  test('rename refuses a title that belongs to another note', () async {
    await vault.createNote('已有');
    final other = await vault.createNote('另一本');
    expect(() => vault.renameNote(other, '已有'), throwsA(isA<NoteNameTaken>()));
  });

  test('insert copies the layer structure onto a new page id', () async {
    final created = await vault.createNote('分页');
    final first = created.pages.single;
    final after = await vault.insertPage(
      created,
      pageId: first.id,
      before: false,
    );
    final before = await vault.insertPage(
      after,
      pageId: first.id,
      before: true,
    );

    expect(before.pages.map((page) => page.id), [
      isNot(first.id),
      first.id,
      after.pages.last.id,
    ]);
    final inserted = before.pages.first;
    expect(inserted.id, isNot(first.id));
    expect(inserted.width, first.width);
    expect(inserted.height, first.height);
    expect(inserted.layers.single.name, first.layers.single.name);
    expect(inserted.layers.single.id, isNot(first.layers.single.id));
    expect(inserted.layers.single.objects, isEmpty);

    final reopened = await Vault(root).openNote(created.directoryName);
    expect(reopened.manifest.pageOrder, before.pages.map((page) => page.id));
  });

  test('layer visibility, lock, and order survive reopening', () async {
    final created = await vault.createNote('图层');
    final page = created.pages.single;
    final ink = page.layers.single;
    final extraId = 'extra-layer';
    final pageDirectory = Directory(
      '${root.path}/${created.directoryName}/pages/${page.id}',
    );
    await File('${pageDirectory.path}/$extraId.json').writeAsString(
      encodeJson(
        LayerFile(
          id: extraId,
          name: '标注',
          objects: [],
          deletedObjectIds: [],
        ).toJson(),
      ),
    );
    await File('${pageDirectory.path}/page.json').writeAsString(
      encodeJson(
        PageFile(
          id: page.id,
          width: page.width,
          height: page.height,
          deletedLayerIds: page.deletedLayerIds,
          layers: [
            ...page.layers,
            LayerFile(
              id: extraId,
              name: '标注',
              objects: [],
              deletedObjectIds: [],
            ),
          ],
        ).toJson(),
      ),
    );

    final opened = await vault.openNote(created.directoryName);
    final hidden = await vault.setLayerVisible(
      opened,
      pageId: page.id,
      layerId: ink.id,
      visible: false,
    );
    final locked = await vault.setLayerLocked(
      hidden,
      pageId: page.id,
      layerId: extraId,
      locked: true,
    );
    final moved = await vault.moveLayer(
      locked,
      pageId: page.id,
      layerId: extraId,
      upward: false,
    );

    final reopened = await Vault(root).openNote(created.directoryName);
    expect(reopened.pages.single.layers.map((layer) => layer.id), [
      extraId,
      ink.id,
    ]);
    expect(reopened.pages.single.layers.first.locked, isTrue);
    expect(reopened.pages.single.layers.last.visible, isFalse);
    expect(moved.pages.single.layers.map((layer) => layer.id), [
      extraId,
      ink.id,
    ]);
  });

  test('a finished pen stroke keeps its baked shape after reopen', () async {
    final created = await vault.createNote('钢笔');
    final page = created.pages.single;
    final layer = page.layers.single;
    final baked = bakePenStroke(
      StrokeObject(
        id: 'pen-1',
        tool: 'pen',
        color: penColor,
        baseWidth: penBaseWidth,
        finalized: false,
        points: [
          mouseSample(x: 10, y: 20, time: 0, baseWidth: penBaseWidth),
          mouseSample(x: 30, y: 50, time: 0.4, baseWidth: penBaseWidth),
          mouseSample(x: 70, y: 40, time: 0.8, baseWidth: penBaseWidth),
        ],
      ),
    );

    final saved = await vault.saveStroke(
      created,
      pageId: page.id,
      layerId: layer.id,
      stroke: baked,
    );
    final changed = baked.copyWith(
      points: [baked.points.first.copyWith(x: 999, width: 1, height: 1)],
    );
    final ignored = await vault.saveStroke(
      saved,
      pageId: page.id,
      layerId: layer.id,
      stroke: changed,
    );

    final reopened = await Vault(root).openNote(created.directoryName);
    final stored = strokesIn(reopened.pages.single.layers.single.objects)
        .single;
    expect(stored.finalized, isTrue);
    expect(
      stored.points.map((point) => point.x),
      baked.points.map((point) => point.x),
    );
    expect(
      stored.points.map((point) => point.width),
      baked.points.map((point) => point.width),
    );
    expect(
      stored.points.map((point) => point.height),
      baked.points.map((point) => point.height),
    );
    expect(
      ignored.pages.single.layers.single.objects,
      saved.pages.single.layers.single.objects,
    );
  });

  test('changeMarks does not duplicate strokes already in memory', () async {
    final created = await vault.createNote('幂等');
    final page = created.pages.single;
    final layer = page.layers.single;
    final stroke = StrokeObject(
      id: 'dup',
      tool: 'pen',
      color: penColor,
      baseWidth: penBaseWidth,
      finalized: true,
      points: [mouseSample(x: 1, y: 2, time: 0, baseWidth: penBaseWidth)],
    );
    final local = applyMarks(
      created,
      pageId: page.id,
      layerId: layer.id,
      add: [stroke],
    );
    final saved = await vault.changeMarks(
      local,
      pageId: page.id,
      layerId: layer.id,
      add: [stroke],
    );
    expect(saved.pages.single.layers.single.objects, hasLength(1));
    final again = await vault.changeMarks(
      saved,
      pageId: page.id,
      layerId: layer.id,
      add: [stroke],
    );
    expect(again.pages.single.layers.single.objects, hasLength(1));
  });

  test('erasing a stroke records the id and undo clears that mark', () async {
    final created = await vault.createNote('橡皮');
    final page = created.pages.single;
    final layer = page.layers.single;
    final stroke = StrokeObject(
      id: 'ink',
      tool: 'pen',
      color: penColor,
      baseWidth: penBaseWidth,
      finalized: true,
      points: [mouseSample(x: 1, y: 2, time: 0, baseWidth: penBaseWidth)],
    );
    final saved = await vault.saveStroke(
      created,
      pageId: page.id,
      layerId: layer.id,
      stroke: stroke,
    );
    final erased = await vault.changeMarks(
      saved,
      pageId: page.id,
      layerId: layer.id,
      tombstone: const ['ink'],
    );
    final reopened = await Vault(root).openNote(created.directoryName);
    expect(reopened.pages.single.layers.single.deletedObjectIds, ['ink']);
    expect(
      strokesIn(reopened.pages.single.layers.single.objects).single.id,
      'ink',
    );

    final restored = await vault.changeMarks(
      erased,
      pageId: page.id,
      layerId: layer.id,
      restore: const ['ink'],
    );
    final again = await Vault(root).openNote(created.directoryName);
    expect(again.pages.single.layers.single.deletedObjectIds, isEmpty);
    expect(restored.pages.single.layers.single.deletedObjectIds, isEmpty);
  });

  test('deleting a page keeps its files and drops it from the order', () async {
    final created = await vault.createNote('分页');
    final inserted = await vault.insertPage(
      created,
      pageId: created.pages.single.id,
      before: false,
    );
    final first = inserted.pages.first.id;
    final second = inserted.pages.last.id;
    final deleted = await vault.deletePage(inserted, pageId: second);
    expect(deleted.pages.map((page) => page.id), [first]);
    expect(deleted.manifest.pageOrder, [first]);
    expect(deleted.manifest.deletedPageIds, [second]);
    expect(
      Directory('${root.path}/${created.directoryName}/pages/$second')
          .existsSync(),
      isTrue,
    );

    final reopened = await Vault(root).openNote(created.directoryName);
    expect(reopened.pages.map((page) => page.id), [first]);
    expect(reopened.manifest.deletedPageIds, [second]);
  });

  test('the last page cannot be deleted', () async {
    final created = await vault.createNote('单页');
    expect(
      () => vault.deletePage(created, pageId: created.pages.single.id),
      throwsA(isA<StateError>()),
    );
  });

  test('a text box is stored on its layer and can be rewritten', () async {
    final created = await vault.createNote('文字');
    final page = created.pages.single;
    final layer = page.layers.single;
    final box = TextBox(
      id: 'box-1',
      version: 1,
      x: 40,
      y: 50,
      width: 220,
      height: 90,
      source: '# 标题',
    );
    final saved = await vault.saveTextBox(
      created,
      pageId: page.id,
      layerId: layer.id,
      box: box,
    );
    final stored = TextBox.fromObject(
      saved.pages.single.layers.single.objects.single,
    );
    expect(stored?.source, '# 标题');
    expect(stored?.version, 1);

    final edited = await vault.saveTextBox(
      saved,
      pageId: page.id,
      layerId: layer.id,
      box: box.copyWith(source: '- 一项\n\n**强调**'),
    );
    final again = TextBox.fromObject(
      edited.pages.single.layers.single.objects.single,
    );
    expect(again?.version, 2);
    expect(again?.source, '- 一项\n\n**强调**');

    final reopened = await Vault(root).openNote(created.directoryName);
    final loaded = TextBox.fromObject(
      reopened.pages.single.layers.single.objects.single,
    );
    expect(loaded?.x, 40);
    expect(loaded?.source, '- 一项\n\n**强调**');
    expect(loaded?.version, 2);
  });

  test('deleting a note removes its directory', () async {
    final created = await vault.createNote('扔掉');
    await vault.deleteNote(created);
    expect(
      Directory('${root.path}/${created.directoryName}').existsSync(),
      isFalse,
    );
    expect(await vault.listNotes(), isEmpty);
  });
}

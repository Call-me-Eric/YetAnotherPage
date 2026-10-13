import 'dart:isolate';
import 'dart:convert';
import 'dart:io';

import '../ids.dart';
import '../ink/pen_palette.dart';
import '../input/stylus_preferences.dart';
import '../ink/stroke.dart';
import '../ink/text_box.dart';
import '../paper.dart';
import 'atomic_file.dart';
import 'note_document.dart';

abstract interface class NoteLibrary {
  Future<List<OpenNote>> listNotes();

  Future<List<NoteSummary>> listSummaries();

  Future<OpenNote> createNote(String title);

  Future<OpenNote> openNote(String directoryName);

  Future<OpenNote> renameNote(OpenNote note, String title);

  Future<OpenNote> insertPage(
    OpenNote note, {
    required String pageId,
    required bool before,
  });

  Future<OpenNote> deletePage(OpenNote note, {required String pageId});

  Future<void> deleteNote(OpenNote note);

  Future<OpenNote> moveLayer(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool upward,
  });

  Future<OpenNote> setLayerVisible(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool visible,
  });

  Future<OpenNote> setLayerLocked(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool locked,
  });

  Future<OpenNote> saveTextBox(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required TextBox box,
  });

  Future<OpenNote> saveStroke(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required StrokeObject stroke,
  });

  Future<OpenNote> changeMarks(
    OpenNote note, {
    required String pageId,
    required String layerId,
    List<StrokeObject> add = const [],
    List<String> tombstone = const [],
    List<String> restore = const [],
  });
}

class NoteNameTaken implements Exception {
  NoteNameTaken(this.title);

  final String title;

  @override
  String toString() => '已经有名为「$title」的笔记';
}

/// Optional recovery capability for libraries that persist handwriting.
abstract interface class StrokeRecoveryStore {
  Future<void> checkpointStroke(
    String directoryName, {
    required String pageId,
    required String layerId,
    required StrokeObject stroke,
    required List<StrokePoint> samples,
  });
  Future<void> finishCheckpoint(
    String directoryName, {
    required String pageId,
    required String strokeId,
  });
}

class Vault implements NoteLibrary, StrokeRecoveryStore {
  Vault(this.root);

  final Directory root;

  static const deviceFileName = 'device.json';
  static const penFileName = 'pen.json';
  static const stylusFileName = 'stylus.json';
  static const noteSuffix = '.yep';

  Future<PenPalette> readPenPalette({bool highlighter = false}) async {
    final fallback = highlighter
        ? PenPalette.highlighter()
        : PenPalette.initial();
    final file = File(
      '${root.path}/${highlighter ? 'highlighter.json' : penFileName}',
    );
    if (!await file.exists()) {
      return fallback;
    }
    try {
      return PenPalette.fromJson(
        jsonDecode(await file.readAsString()),
        highlighter: highlighter,
      );
    } on FormatException {
      return fallback;
    }
  }

  Future<StylusPreferences> readStylusPreferences() async {
    final file = File('${root.path}/$stylusFileName');
    if (!await file.exists()) {
      return StylusPreferences.initial;
    }
    try {
      return StylusPreferences.fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return StylusPreferences.initial;
    }
  }

  Future<void> writeStylusPreferences(StylusPreferences preferences) async {
    await root.create(recursive: true);
    await writeJsonAtomic(
      File('${root.path}/$stylusFileName'),
      preferences.toJson(),
    );
  }

  Future<void> writePenPalette(
    PenPalette palette, {
    bool highlighter = false,
  }) async {
    await root.create(recursive: true);
    await writeJsonAtomic(
      File('${root.path}/${highlighter ? 'highlighter.json' : penFileName}'),
      palette.toJson(),
    );
  }

  Future<String> deviceId() async {
    await root.create(recursive: true);
    final file = File('${root.path}/$deviceFileName');
    if (await file.exists()) {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return json['deviceId']! as String;
    }
    final id = newId();
    await writeAtomic(file, encodeJson({'deviceId': id}));
    return id;
  }

  @override
  Future<List<OpenNote>> listNotes() async {
    if (!await root.exists()) {
      return const [];
    }
    final notes = <OpenNote>[];
    await for (final entity in root.list()) {
      if (entity is! Directory || !_isNoteDirectory(entity.path)) {
        continue;
      }
      try {
        notes.add(await openNote(_nameOf(entity)));
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    notes.sort((a, b) => a.title.compareTo(b.title));
    return notes;
  }

  @override
  Future<List<NoteSummary>> listSummaries() async {
    if (!await root.exists()) {
      return const [];
    }
    final notes = <NoteSummary>[];
    await for (final entity in root.list()) {
      if (entity is! Directory || !_isNoteDirectory(entity.path)) {
        continue;
      }
      try {
        final manifest = NoteManifest.fromJson(
          jsonDecode(await File('${entity.path}/manifest.json').readAsString())
              as Map<String, Object?>,
        );
        notes.add(
          NoteSummary(directoryName: _nameOf(entity), manifest: manifest),
        );
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    notes.sort((a, b) => a.title.compareTo(b.title));
    return notes;
  }

  @override
  Future<OpenNote> createNote(String title) async {
    await root.create(recursive: true);
    final noteId = newId();
    final pageId = newId();
    final layerId = newId();
    final manifest = NoteManifest(
      id: noteId,
      title: _displayTitle(title),
      formatVersion: formatVersion,
      pageOrder: [pageId],
    );
    final layer = LayerFile(
      id: layerId,
      name: defaultInkLayerName,
      objects: const [],
      deletedObjectIds: const [],
    );
    final page = PageFile(
      id: pageId,
      width: a4Width,
      height: a4Height,
      layers: [layer],
      deletedLayerIds: const [],
    );
    final directoryName = await _uniqueDirectoryName(manifest.title);
    final staging = Directory('${root.path}/.$directoryName.partial');
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    try {
      await _writeNote(staging, manifest: manifest, pages: [page]);
      await staging.rename('${root.path}/$directoryName');
    } catch (error) {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
    return openNote(directoryName);
  }

  @override
  Future<OpenNote> openNote(String directoryName) {
    final rootPath = root.path;
    return Isolate.run(
      () => Vault(Directory(rootPath))._openNote(directoryName),
    );
  }

  Future<OpenNote> _openNote(String directoryName) async {
    final directory = Directory('${root.path}/$directoryName');
    final manifestFile = File('${directory.path}/manifest.json');
    final manifest = NoteManifest.fromJson(
      jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>,
    );
    final pages = <PageFile>[];
    for (final pageId in manifest.pageOrder) {
      if (manifest.deletedPageIds.contains(pageId)) {
        continue;
      }
      final pageDirectory = Directory('${directory.path}/pages/$pageId');
      final pageJson = jsonDecode(
        await File('${pageDirectory.path}/page.json').readAsString(),
      ) as Map<String, Object?>;
      final layerOrder = (pageJson['layerOrder']! as List<Object?>)
          .cast<String>();
      final layers = <LayerFile>[];
      for (final layerId in layerOrder) {
        final layerJson = jsonDecode(
          await File('${pageDirectory.path}/$layerId.json').readAsString(),
        ) as Map<String, Object?>;
        layers.add(
          LayerFile.fromJson(await _expandStrokeRefs(pageDirectory, layerJson)),
        );
      }
      pages.add(
        PageFile(
          id: pageId,
          width: (pageJson['width']! as num).toDouble(),
          height: (pageJson['height']! as num).toDouble(),
          layers: layers,
          deletedLayerIds: (pageJson['deletedLayerIds']! as List<Object?>)
              .cast<String>(),
        ),
      );
    }
    return _recoverCheckpoints(
      OpenNote(directoryName: directoryName, manifest: manifest, pages: pages),
    );
  }

  @override
  Future<void> checkpointStroke(
    String directoryName, {
    required String pageId,
    required String layerId,
    required StrokeObject stroke,
    required List<StrokePoint> samples,
  }) async {
    if (samples.isEmpty) return;
    final directory = Directory(
      '${root.path}/$directoryName/pages/$pageId/journal',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}/${stroke.id}.jsonl');
    final lines = <String>[];
    if (!await file.exists()) {
      lines.add(
        jsonEncode({
          'layerId': layerId,
          'stroke': stroke.copyWith(points: []).toJson(),
        }),
      );
    }
    lines.addAll(samples.map((sample) => jsonEncode(sample.toJson())));
    await file.writeAsString(
      '${lines.join('\n')}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<void> finishCheckpoint(
    String directoryName, {
    required String pageId,
    required String strokeId,
  }) async {
    final file = File(
      '${root.path}/$directoryName/pages/$pageId/journal/$strokeId.jsonl',
    );
    if (await file.exists()) await file.delete();
  }

  Future<OpenNote> _recoverCheckpoints(OpenNote note) async {
    for (final page in note.pages) {
      final directory = Directory(
        '${root.path}/${note.directoryName}/pages/${page.id}/journal',
      );
      if (!await directory.exists()) continue;
      final files = await directory
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.jsonl'))
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final lines = await file.readAsLines();
        if (lines.isEmpty) continue;
        Map<String, dynamic> header;
        try {
          header = jsonDecode(lines.first) as Map<String, dynamic>;
        } on FormatException {
          continue;
        }
        final layerId = header['layerId'];
        if (layerId is! String || header['stroke'] is! Map) continue;
        final layers = page.layers.where(
          (layer) =>
              layer.id == layerId && !page.deletedLayerIds.contains(layer.id),
        );
        if (layers.isEmpty) continue;
        final stroke = StrokeObject.fromJson(
          Map<String, Object?>.from(header['stroke'] as Map),
        );
        // A crash between committing the layer and removing the journal must
        // not resurrect a subsequently erased/undone stroke.
        final known = layers.single.objects.any(
          (object) => object is Map && object['id'] == stroke.id,
        );
        if (!known) {
          final samples = <StrokePoint>[];
          for (var i = 1; i < lines.length; i++) {
            try {
              samples.add(
                StrokePoint.fromJson(
                  Map<String, Object?>.from(jsonDecode(lines[i]) as Map),
                ),
              );
            } on FormatException {
              break;
            }
          }
          if (samples.isNotEmpty) {
            note = await changeMarks(
              note,
              pageId: page.id,
              layerId: layerId,
              add: [bakePenStroke(stroke.copyWith(points: samples))],
            );
          }
        }
        await file.delete();
      }
    }
    return note;
  }

  @override
  Future<OpenNote> renameNote(OpenNote note, String title) async {
    final displayTitle = _displayTitle(title);
    final current = Directory('${root.path}/${note.directoryName}');
    final desired = '${_directoryBase(displayTitle)}$noteSuffix';
    if (desired != note.directoryName &&
        await Directory('${root.path}/$desired').exists()) {
      throw NoteNameTaken(displayTitle);
    }
    final nextName = desired;
    final updated = note.manifest.copyWith(title: displayTitle);
    await writeJsonAtomic(
      File('${current.path}/manifest.json'),
      updated.toJson(),
    );
    if (nextName != note.directoryName) {
      await current.rename('${root.path}/$nextName');
    }
    return OpenNote(
      directoryName: nextName,
      manifest: updated,
      pages: note.pages,
    );
  }

  @override
  Future<OpenNote> insertPage(
    OpenNote note, {
    required String pageId,
    required bool before,
  }) async {
    final index = note.pages.indexWhere((page) => page.id == pageId);
    if (index < 0) {
      throw ArgumentError('未知页面 $pageId');
    }
    final page = emptyCopyOf(
      note.pages[index],
      id: newId(),
      layerIds: [for (final _ in note.pages[index].layers) newId()],
    );
    final directory = Directory('${root.path}/${note.directoryName}');
    await _writePage(directory, page);
    final order = [...note.manifest.pageOrder];
    order.insert(before ? index : index + 1, page.id);
    await writeJsonAtomic(
      File('${directory.path}/manifest.json'),
      note.manifest.copyWith(pageOrder: order).toJson(),
    );
    return openNote(note.directoryName);
  }

  @override
  Future<OpenNote> deletePage(OpenNote note, {required String pageId}) async {
    if (!note.manifest.pageOrder.contains(pageId) ||
        note.manifest.deletedPageIds.contains(pageId)) {
      throw ArgumentError('未知页面 $pageId');
    }
    if (note.pages.length <= 1) {
      throw StateError('至少保留一页');
    }
    final deleted = [...note.manifest.deletedPageIds];
    if (!deleted.contains(pageId)) {
      deleted.add(pageId);
    }
    final directory = Directory('${root.path}/${note.directoryName}');
    await writeAtomic(
      File('${directory.path}/manifest.json'),
      encodeJson(
        note.manifest
            .copyWith(
              pageOrder: [
                for (final id in note.manifest.pageOrder)
                  if (id != pageId) id,
              ],
              deletedPageIds: deleted,
            )
            .toJson(),
      ),
    );
    return openNote(note.directoryName);
  }

  @override
  Future<void> deleteNote(OpenNote note) async {
    final directory = Directory('${root.path}/${note.directoryName}');
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  @override
  Future<OpenNote> moveLayer(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool upward,
  }) async {
    final page = _page(note, pageId);
    final moved = page.moveLayer(layerId, upward: upward);
    if (identical(moved, page)) {
      return note;
    }
    await _writePage(Directory('${root.path}/${note.directoryName}'), moved);
    return openNote(note.directoryName);
  }

  @override
  Future<OpenNote> setLayerVisible(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool visible,
  }) {
    return _updateLayer(
      note,
      pageId,
      layerId,
      (layer) => layer.copyWith(visible: visible),
    );
  }

  @override
  Future<OpenNote> setLayerLocked(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required bool locked,
  }) {
    return _updateLayer(
      note,
      pageId,
      layerId,
      (layer) => layer.copyWith(locked: locked),
    );
  }

  @override
  Future<OpenNote> saveTextBox(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required TextBox box,
  }) async {
    final page = _page(note, pageId);
    final layer = page.layers.firstWhere(
      (item) => item.id == layerId,
      orElse: () => throw ArgumentError('未知图层 $layerId'),
    );
    final memoryObjects = replaceTextBox(layer.objects, box);
    final directory = Directory(
      '${root.path}/${note.directoryName}/pages/$pageId',
    );
    final stored = layer.copyWith(
      objects: [for (final object in memoryObjects) _storedObject(object)],
    );
    await writeJsonAtomic(
      File('${directory.path}/$layerId.json'),
      stored.toJson(),
    );
    return OpenNote(
      directoryName: note.directoryName,
      manifest: note.manifest,
      pages: [
        for (final item in note.pages)
          if (item.id == page.id)
            page.updateLayer(
              layer.id,
              (_) => layer.copyWith(objects: memoryObjects),
            )
          else
            item,
      ],
    );
  }

  @override
  Future<OpenNote> saveStroke(
    OpenNote note, {
    required String pageId,
    required String layerId,
    required StrokeObject stroke,
  }) async {
    final page = _page(note, pageId);
    final layer = page.layers.firstWhere(
      (item) => item.id == layerId,
      orElse: () => throw ArgumentError('未知图层 $layerId'),
    );
    final existing = strokesIn(layer.objects)
        .where((item) => item.id == stroke.id);
    if (existing.isNotEmpty && existing.first.finalized) {
      return note;
    }
    final memoryObjects = [
      for (final object in layer.objects)
        if (_strokeId(object) != stroke.id) object,
      stroke.toJson(),
    ];
    final directory = Directory(
      '${root.path}/${note.directoryName}/pages/$pageId',
    );
    await _spillStrokes(directory, memoryObjects);
    final stored = layer.copyWith(
      objects: [for (final object in memoryObjects) _storedObject(object)],
    );
    await writeJsonAtomic(
      File('${directory.path}/$layerId.json'),
      stored.toJson(),
    );
    return OpenNote(
      directoryName: note.directoryName,
      manifest: note.manifest,
      pages: [
        for (final item in note.pages)
          if (item.id == page.id)
            page.updateLayer(
              layer.id,
              (_) => layer.copyWith(
                objects: memoryObjects,
                strokeCache: {...layer.strokeCache, stroke.id: stroke},
              ),
            )
          else
            item,
      ],
    );
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
    final page = _page(note, pageId);
    final layer = page.layers.firstWhere(
      (item) => item.id == layerId,
      orElse: () => throw ArgumentError('未知图层 $layerId'),
    );
    final deleted = [...layer.deletedObjectIds];
    for (final id in tombstone) {
      if (!deleted.contains(id)) {
        deleted.add(id);
      }
    }
    deleted.removeWhere(restore.contains);
    final known = <String>{
      for (final object in layer.objects) ?_strokeId(object),
    };
    // Idempotent: memory may already contain [add] from a sync local apply.
    final memoryObjects = [
      ...layer.objects,
      for (final stroke in add)
        if (known.add(stroke.id)) stroke.toJson(),
    ];
    final directory = Directory(
      '${root.path}/${note.directoryName}/pages/$pageId',
    );
    await _spillStrokes(directory, [for (final stroke in add) stroke.toJson()]);
    final stored = layer.copyWith(
      objects: [for (final object in memoryObjects) _storedObject(object)],
      deletedObjectIds: deleted,
    );
    await writeJsonAtomic(
      File('${directory.path}/$layerId.json'),
      stored.toJson(),
    );
    final cache = {...layer.strokeCache};
    for (final stroke in add) {
      cache.putIfAbsent(stroke.id, () => stroke);
    }
    final memory = layer.copyWith(
      objects: memoryObjects,
      deletedObjectIds: deleted,
      strokeCache: cache,
    );
    return OpenNote(
      directoryName: note.directoryName,
      manifest: note.manifest,
      pages: [
        for (final item in note.pages)
          if (item.id == page.id)
            page.updateLayer(layer.id, (_) => memory)
          else
            item,
      ],
    );
  }

  String? _strokeId(Object? object) {
    if (object is! Map) {
      return null;
    }
    final type = object['type'];
    final id = object['id'];
    if (id is! String || (type != 'stroke' && type != 'strokeRef')) {
      return null;
    }
    return id;
  }

  Object? _storedObject(Object? object) {
    final id = _strokeId(object);
    if (id == null) {
      return object;
    }
    return {'type': 'strokeRef', 'id': id};
  }

  Future<void> _spillStrokes(
    Directory pageDirectory,
    List<Object?> objects,
  ) async {
    final strokes = Directory('${pageDirectory.path}/strokes');
    await strokes.create(recursive: true);
    for (final object in objects) {
      if (object is! Map ||
          object['type'] != 'stroke' ||
          object['points'] is! List) {
        continue;
      }
      final id = object['id'];
      if (id is! String) {
        continue;
      }
      final file = File('${strokes.path}/$id.json');
      if (await file.exists()) {
        final previous = jsonDecode(await file.readAsString());
        if (previous is Map && previous['finalized'] == true) continue;
      }
      await writeJsonAtomic(
        file,
        Map<String, Object?>.from(object).cast<String, Object>(),
      );
    }
  }

  Future<Map<String, Object?>> _expandStrokeRefs(
    Directory pageDirectory,
    Map<String, Object?> layerJson,
  ) async {
    final objects = layerJson['objects'];
    if (objects is! List) {
      return layerJson;
    }
    final expanded = <Object?>[];
    for (final object in objects) {
      if (object is Map && object['type'] == 'strokeRef') {
        final id = object['id'];
        if (id is! String) {
          continue;
        }
        final file = File('${pageDirectory.path}/strokes/$id.json');
        if (!await file.exists()) {
          throw FileSystemException('笔画引用缺少对应文件，停止打开以防覆盖丢失的数据', file.path);
        }
        expanded.add(jsonDecode(await file.readAsString()));
        continue;
      }
      expanded.add(object);
    }
    return {...layerJson, 'objects': expanded};
  }

  Future<OpenNote> _updateLayer(
    OpenNote note,
    String pageId,
    String layerId,
    LayerFile Function(LayerFile layer) update,
  ) async {
    final page = _page(note, pageId).updateLayer(layerId, update);
    final directory = Directory(
      '${root.path}/${note.directoryName}/pages/$pageId',
    );
    final layer = page.layers.firstWhere((item) => item.id == layerId);
    await writeJsonAtomic(
      File('${directory.path}/$layerId.json'),
      layer.toJson(),
    );
    return openNote(note.directoryName);
  }

  PageFile _page(OpenNote note, String pageId) {
    return note.pages.firstWhere(
      (page) => page.id == pageId,
      orElse: () => throw ArgumentError('未知页面 $pageId'),
    );
  }

  Future<void> _writeNote(
    Directory directory, {
    required NoteManifest manifest,
    required List<PageFile> pages,
  }) async {
    await writeJsonAtomic(
      File('${directory.path}/manifest.json'),
      manifest.toJson(),
    );
    for (final page in pages) {
      await _writePage(directory, page);
    }
    await Directory('${directory.path}/assets').create();
  }

  Future<void> _writePage(Directory noteDirectory, PageFile page) async {
    final pageDirectory = Directory('${noteDirectory.path}/pages/${page.id}');
    await pageDirectory.create(recursive: true);
    await writeJsonAtomic(
      File('${pageDirectory.path}/page.json'),
      page.toJson(),
    );
    for (final layer in page.layers) {
      await writeJsonAtomic(
        File('${pageDirectory.path}/${layer.id}.json'),
        layer.toJson(),
      );
    }
  }

  Future<String> _uniqueDirectoryName(String title) async {
    final base = _directoryBase(title);
    var candidate = '$base$noteSuffix';
    var suffix = 2;
    while (await Directory('${root.path}/$candidate').exists()) {
      candidate = '$base $suffix$noteSuffix';
      suffix += 1;
    }
    return candidate;
  }

  static String _displayTitle(String title) {
    final trimmed = title.trim();
    return trimmed.isEmpty ? '未命名' : trimmed;
  }

  static String _directoryBase(String title) {
    var base = _displayTitle(title);
    if (base.toLowerCase().endsWith(noteSuffix)) {
      base = base.substring(0, base.length - noteSuffix.length).trim();
    }
    base = base
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (base.isEmpty || base == '.' || base == '..') {
      return '未命名';
    }
    return base;
  }

  static bool _isNoteDirectory(String path) {
    final name = _nameOf(Directory(path));
    return !name.startsWith('.') && name.endsWith(noteSuffix);
  }

  static String _nameOf(Directory directory) {
    final path = directory.path;
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index == -1 ? path : path.substring(index + 1);
  }
}

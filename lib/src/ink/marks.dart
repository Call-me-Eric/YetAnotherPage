import '../storage/note_document.dart';
import 'stroke.dart';

/// Applies stroke adds / tombstones / restores to an in-memory [OpenNote].
///
/// Memory is the display authority: UI and tiles read from the result
/// immediately. Persistence is write-behind and must not invent a second
/// live buffer (no settled / hidden shadows).
OpenNote applyMarks(
  OpenNote note, {
  required String pageId,
  required String layerId,
  List<StrokeObject> add = const [],
  List<String> tombstone = const [],
  List<String> restore = const [],
}) {
  if (add.isEmpty && tombstone.isEmpty && restore.isEmpty) {
    return note;
  }
  return OpenNote(
    directoryName: note.directoryName,
    manifest: note.manifest,
    pages: [
      for (final page in note.pages)
        if (page.id != pageId)
          page
        else
          page.updateLayer(layerId, (layer) {
            final deleted = [...layer.deletedObjectIds];
            for (final id in tombstone) {
              if (!deleted.contains(id)) {
                deleted.add(id);
              }
            }
            if (restore.isNotEmpty) {
              deleted.removeWhere(restore.contains);
            }
            final known = <String>{
              for (final object in layer.objects) ?_objectId(object),
            };
            final objects = [
              ...layer.objects,
              for (final stroke in add)
                if (known.add(stroke.id)) stroke.toJson(),
            ];
            final cache = {...layer.strokeCache};
            for (final stroke in add) {
              cache.putIfAbsent(stroke.id, () => stroke);
            }
            return layer.copyWith(
              objects: objects,
              deletedObjectIds: deleted,
              strokeCache: cache,
            );
          }),
    ],
  );
}

/// Live strokes on a layer (finalized, not tombstoned).
List<StrokeObject> liveStrokes(LayerFile layer) {
  final deleted = layer.deletedObjectIds.toSet();
  final result = <StrokeObject>[];
  for (final object in layer.objects) {
    if (object is! Map || object['type'] != 'stroke') continue;
    final id = object['id'];
    if (id is! String || deleted.contains(id)) continue;
    final stroke = layer.strokeCache[id] ?? strokeFromObject(object);
    if (stroke != null && stroke.finalized) result.add(stroke);
  }
  return result;
}

String? _objectId(Object? object) {
  if (object is! Map) {
    return null;
  }
  final id = object['id'];
  return id is String ? id : null;
}

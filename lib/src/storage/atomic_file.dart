import 'dart:isolate';

import 'note_document.dart';

import 'dart:io';

int _sequence = 0;

/// Publish a flushed file. Failed replacements retain the previous contents.
Future<void> writeAtomic(File file, String contents) async {
  await file.parent.create(recursive: true);
  final suffix =
      '${pid}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
  final temporary = File('${file.path}.$suffix.tmp');
  try {
    await temporary.writeAsString(contents, flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      // POSIX rename replaces atomically. Windows may refuse an existing path.
      // Never delete the original in response to an arbitrary I/O error.
      if (!Platform.isWindows || !await file.exists()) rethrow;
      final backup = File('${file.path}.$suffix.bak');
      await file.rename(backup.path);
      try {
        await temporary.rename(file.path);
      } catch (_) {
        await backup.rename(file.path);
        rethrow;
      }
      await backup.delete();
    }
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

/// Encoding a large layer/long stroke must not block handwriting frames.
Future<void> writeJsonAtomic(File file, Object value) async {
  final path = file.path;
  await Isolate.run(() async {
    await writeAtomic(File(path), encodeJson(value));
  });
}

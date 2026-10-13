import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/storage/atomic_file.dart';

void main() {
  test('concurrent atomic writes publish a complete document', () async {
    final directory = await Directory.systemTemp.createTemp('yep-atomic-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/layer.json');
    await Future.wait([
      for (var i = 0; i < 8; i++)
        writeAtomic(file, jsonEncode({'value': i, 'text': '完整的笔记'})),
    ]);
    final contents = jsonDecode(await file.readAsString()) as Map;
    expect(contents['text'], '完整的笔记');
    expect(contents['value'], inInclusiveRange(0, 7));
    expect(await directory.list().length, 1);
  });
}

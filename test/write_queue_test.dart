import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yet_another_page/src/storage/write_queue.dart';

void main() {
  test(
    'slow writes complete in order and flush waits for all writes',
    () async {
      final queue = WriteQueue();
      final gate = Completer<void>();
      final events = <int>[];
      final first = queue.add(() async {
        await gate.future;
        events.add(1);
      });
      final second = queue.add(() async {
        events.add(2);
      });
      expect(events, isEmpty);
      gate.complete();
      await Future.wait([first, second, queue.flush()]);
      expect(events, [1, 2]);
    },
  );
  test('a failure is retried before a newer snapshot is written', () async {
    final queue = WriteQueue();
    final events = <int>[];
    var attempts = 0;
    await expectLater(
      queue.add(() async {
        if (attempts++ == 0) throw StateError('disk unavailable');
        events.add(1);
      }),
      throwsStateError,
    );
    await queue.add(() async {
      events.add(2);
    });
    await queue.flush();
    expect(events, [1, 2]);
  });
}

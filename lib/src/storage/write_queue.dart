import 'dart:collection';

/// Serializes writes and retains a failed write for the next retry.
/// A newer snapshot must never overtake an older failed write.
class WriteQueue {
  final Queue<Future<void> Function()> _pending = Queue();
  Future<void>? _running;

  Future<void> add(Future<void> Function() write) {
    _pending.add(write);
    return flush();
  }

  Future<void> flush() {
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      await _pending.first();
      _pending.removeFirst();
    }
  }
}

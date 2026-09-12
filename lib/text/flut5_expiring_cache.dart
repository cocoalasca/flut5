import 'dart:collection';

/// Internal map with sliding frame expiration and allocation-free cache hits.
///
/// Entries are ordered by last use. Expiration visits only the expired prefix;
/// inspecting entries/values for capacity eviction does not refresh their age.
class Flut5ExpiringCache<K, V>(
  final int Function() currentFrame, {
  final void Function(V)? onExpire,
}) extends MapBase<K, V> {
  final _entries = HashMap<K, _Entry<K, V>>();
  final _oldestFirst = LinkedList<_Entry<K, V>>();

  @override
  V? operator [](Object? key) {
    final entry = _entries[key];
    if (entry == null) return null;
    _touch(entry);
    return entry.value;
  }

  void _touch(_Entry<K, V> entry) {
    final frame = currentFrame();
    if (entry.lastUsedFrame == frame) return;
    entry.lastUsedFrame = frame;
    entry.unlink();
    _oldestFirst.add(entry);
  }

  @override
  void operator []=(K key, V value) {
    final existing = _entries[key];
    if (existing != null) {
      existing.value = value;
      _touch(existing);
      return;
    }
    final entry = _Entry(key, value, currentFrame());
    _entries[key] = entry;
    _oldestFirst.add(entry);
  }

  @override
  Iterable<K> get keys => _entries.keys;

  @override
  Iterable<V> get values => _entries.values.map((entry) => entry.value);

  @override
  Iterable<MapEntry<K, V>> get entries =>
      _entries.values.map((entry) => MapEntry(entry.key, entry.value));

  @override
  int get length => _entries.length;

  @override
  bool containsKey(Object? key) => _entries.containsKey(key);

  @override
  V? remove(Object? key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    entry.unlink();
    return entry.value;
  }

  @override
  void clear() {
    _entries.clear();
    _oldestFirst.clear();
  }

  /// Removes entries unused for [timeoutFrames], disposing owned resources.
  void expire(int timeoutFrames) {
    final cutoff = currentFrame() - timeoutFrames;
    while (_oldestFirst.isNotEmpty) {
      final entry = _oldestFirst.first;
      if (entry.lastUsedFrame > cutoff) break;
      remove(entry.key);
      onExpire?.call(entry.value);
    }
  }
}

final class _Entry<K, V>(final K key, var V value, var int lastUsedFrame)
    extends LinkedListEntry<_Entry<K, V>>;

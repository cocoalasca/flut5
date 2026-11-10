import 'dart:collection';

/// Internal map with sliding frame expiration and allocation-free cache hits.
///
/// Entries are ordered by last use. Expiration visits only the expired prefix;
/// inspecting entries/values for capacity eviction does not refresh their age.
class Flut5ExpiringCache<K, V>(
  final int Function() currentFrame, {
  final void Function(V)? onExpire,
}) extends MapBase<K, V> {
  final _entries = HashMap<K, Flut5ExpiringEntry<K, V>>();
  final _oldestFirst = LinkedList<Flut5ExpiringEntry<K, V>>();

  @override
  V? operator [](Object? key) {
    final entry = _entries[key];
    if (entry == null) return null;
    _touch(entry);
    return entry.value;
  }

  void _touch(Flut5ExpiringEntry<K, V> entry) {
    final frame = currentFrame();
    if (entry.lastUsedFrame == frame) return;
    entry.lastUsedFrame = frame;
    entry.unlink();
    _oldestFirst.add(entry);
  }

  /// The value under [key] without counting as a use: its age is left alone.
  V? peek(Object? key) => _entries[key]?.value;

  /// The entry holding [key], for [touch] — a caller that keeps hold of a
  /// value can then mark it used without hashing its key again. `null` when
  /// [key] is absent. The entry is dead once its key is removed or expires;
  /// touching it then would put it back among the entries still to expire.
  Flut5ExpiringEntry<K, V>? entryOf(Object? key) => _entries[key];

  /// Counts a use of [entry], exactly as reading its key would.
  void touch(Flut5ExpiringEntry<K, V> entry) => _touch(entry);

  @override
  void operator []=(K key, V value) {
    final existing = _entries[key];
    if (existing != null) {
      existing.value = value;
      _touch(existing);
      return;
    }
    final entry = Flut5ExpiringEntry<K, V>._(key, value, currentFrame());
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

  /// Removes the lowest-priority values while [shouldEvict] is true.
  /// Heap construction is linear and each victim costs O(log n); ordinary
  /// cache hits need no additional bookkeeping. The snapshot holds entries,
  /// not allocated MapEntry wrappers, and never refreshes expiration ages.
  /// Callbacks must not insert entries or access values through this cache.
  void evictWhile(
    bool Function() shouldEvict,
    int Function(V, V) compare,
    void Function(V) onEvict,
  ) {
    if (!shouldEvict() || _entries.isEmpty) return;
    final heap = _entries.values.toList(growable: false);
    var size = heap.length;
    void siftDown(int root) {
      final entry = heap[root];
      while (root * 2 + 1 < size) {
        var child = root * 2 + 1;
        if (child + 1 < size &&
            compare(heap[child + 1].value, heap[child].value) < 0) {
          child++;
        }
        if (compare(entry.value, heap[child].value) <= 0) break;
        heap[root] = heap[child];
        root = child;
      }
      heap[root] = entry;
    }

    for (var i = (size >> 1) - 1; i >= 0; i--) {
      siftDown(i);
    }
    while (size > 0 && shouldEvict()) {
      final entry = heap[0];
      size--;
      if (size > 0) {
        heap[0] = heap[size];
        siftDown(0);
      }
      remove(entry.key);
      onEvict(entry.value);
    }
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

/// One key and value of a [Flut5ExpiringCache], linked in order of last
/// use.
final class Flut5ExpiringEntry<K, V>._(
  final K key,
  var V value,
  var int lastUsedFrame,
) extends LinkedListEntry<Flut5ExpiringEntry<K, V>>;

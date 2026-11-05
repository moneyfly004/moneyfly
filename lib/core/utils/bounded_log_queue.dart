import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'log_rotation.dart';

/// Logging-only FIFO queue: newest records are dropped under pressure.
/// Unlike SerialExecutor, log submissions do not retain a future per record.
class BoundedLogQueue {
  BoundedLogQueue(
    this.writeBatch, {
    this.maxPendingBytes = 256 * 1024,
    this.maxBatchBytes = 64 * 1024,
  });
  final Future<void> Function(String) writeBatch;
  final int maxPendingBytes;
  final int maxBatchBytes;
  final Queue<Object> _items = Queue<Object>();
  int pendingBytes = 0;
  int droppedRecords = 0;
  int _unreported = 0;
  bool _running = false;

  void add(String text) {
    final record = capLogRecord(text, maxBytes: maxBatchBytes);
    final bytes = utf8.encode(record).length;
    if (pendingBytes + bytes > maxPendingBytes) {
      droppedRecords++;
      _unreported++;
      return;
    }
    _items.add((record, bytes));
    pendingBytes += bytes;
    _start();
  }

  /// FIFO control barrier; callers should await these (not use for log traffic).
  Future<T> run<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _items.add(() async {
      try {
        result.complete(await action());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    _start();
    return result.future;
  }

  Future<void> flush() => run(() async {});

  void _start() {
    if (_running) return;
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    while (_items.isNotEmpty) {
      final first = _items.first;
      if (first is Future<void> Function()) {
        _items.removeFirst();
        await first();
        continue;
      }
      final b = StringBuffer();
      var size = 0;
      while (_items.isNotEmpty && _items.first is (String, int)) {
        final item = _items.first as (String, int);
        if (size + item.$2 > maxBatchBytes) break;
        _items.removeFirst();
        pendingBytes -= item.$2;
        size += item.$2;
        b.write(item.$1);
      }
      try {
        await writeBatch(b.toString());
        if (_unreported > 0) {
          final count = _unreported;
          _unreported = 0;
          await writeBatch('[log queue dropped $count records]\n');
        }
      } catch (_) {
        // Never recursively log diagnostics I/O failures.
      }
      await Future<void>.delayed(Duration.zero);
    }
    _running = false;
  }
}

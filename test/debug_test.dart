import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

void main() {
  testWidgets('debug dio raw', (tester) async {
    Object? result = 'pending';
    final f = tester.runAsync(() async {
      final d = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
      try {
        final r = await d.get('/packages').timeout(const Duration(seconds: 3));
        result = 'ok: ${r.statusCode}';
      } catch (e) {
        result = 'err: ${e.runtimeType}';
      }
    });
    await Future<void>.delayed(const Duration(seconds: 4));
    await f;
    debugPrint('RAW DIO: $result');
  });
}

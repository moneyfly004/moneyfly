import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/services/crash_logger.dart';
import 'package:moneyfly/core/utils/bounded_log_queue.dart';
import 'package:moneyfly/core/utils/log_rotation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'huge Unicode records and legacy file tails stay byte bounded',
    () async {
      final dir = await Directory.systemTemp.createTemp('bounded-log-');
      addTearDown(() => dir.delete(recursive: true));
      final huge = '😀中' * 1000000;
      final capped = capLogRecord(huge);
      expect(utf8.encode(capped).length, lessThanOrEqualTo(64 * 1024));
      expect(capped, isNot(contains('\uFFFD')));
      final file = File('${dir.path}/test.log');
      await file.writeAsString(huge);
      await appendBoundedLog(file, huge);
      expect(await file.length(), lessThanOrEqualTo(512 * 1024));
      expect(await readLogTail(file), isNot(contains('\uFFFD')));
    },
  );

  test(
    'slow writer bounds backlog and retained records stay ordered',
    () async {
      final gate = Completer<void>();
      final batches = <String>[];
      final q = BoundedLogQueue(
        (batch) async {
          await gate.future;
          batches.add(batch);
        },
        maxPendingBytes: 1024,
        maxBatchBytes: 256,
      );
      for (var i = 0; i < 10000; i++) {
        q.add('$i:${'中' * 80}\n');
      }
      expect(q.pendingBytes, lessThanOrEqualTo(1024));
      expect(q.droppedRecords, greaterThan(9000));
      gate.complete();
      await q.flush();
      final text = batches.join();
      expect(text, contains('dropped'));
      expect(text.indexOf('0:'), lessThan(text.indexOf('1:')));
      expect(q.pendingBytes, 0);
      q.add('before\n');
      await q.run(() async => batches.clear());
      q.add('after\n');
      await q.flush();
      expect(batches.join(), 'after\n');
    },
  );

  test('crash storm rolls active file and prunes during activity', () async {
    final dir = await Directory.systemTemp.createTemp('crash-storm-');
    addTearDown(() => dir.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() {
      CrashLogger.setEnabled(false);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    CrashLogger.setEnabled(true);
    final record = '😀' * 20000;
    for (var round = 0; round < 200; round++) {
      for (var i = 0; i < 10; i++) {
        CrashLogger.logForTest(record);
      }
      expect(CrashLogger.pendingBytesForTest, lessThanOrEqualTo(256 * 1024));
      await CrashLogger.flushForTest();
      final files = await Directory('${dir.path}/crash_logs').list().toList();
      expect(files.length, lessThanOrEqualTo(20));
      for (final f in files.whereType<File>()) {
        expect(await f.length(), lessThanOrEqualTo(512 * 1024));
      }
    }
    expect(await Directory('${dir.path}/crash_logs').list().length, 20);
  });

  test(
    'nested subscription bodies and exception secrets never formatted',
    () async {
      final logs = <String>[];
      final dio = Dio();
      dio.interceptors.add(ApiClient.buildLogInterceptor(logs.add));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            final response = Response(
              requestOptions: o,
              statusCode: 200,
              data: {
                'data': {
                  'subscribe_url':
                      'https://host/sub/PATH_SECRET?token=TOKEN_SECRET',
                },
              },
            );
            if (o.extra['fail'] == true) {
              h.reject(
                DioException(
                  requestOptions: o,
                  response: response,
                  message: 'EXCEPTION_SECRET',
                  error: 'ERROR_SECRET',
                ),
                true,
              );
            } else {
              h.resolve(response, true);
            }
          },
        ),
      );
      for (final fail in [false, true]) {
        try {
          await dio.post(
            'https://USER_SECRET:PASS_SECRET@host/user/subscribe?key=QUERY_SECRET',
            data: {
              'nested': {'password': 'BODY_SECRET'},
            },
            options: Options(extra: {'fail': fail}),
          );
        } on DioException {
          /* mock failure */
        }
      }
      expect(logs.length, 4);
      expect(logs.join(), isNot(contains('SECRET')));
      dio.close();
    },
  );
}

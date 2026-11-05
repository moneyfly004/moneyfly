// Mirrors transport installer bytes; only direct GitHub supplies trust metadata.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/api/gh_mirror.dart';
import 'package:moneyfly/core/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const name = 'MoneyFly-setup-9.9.9.exe';
const release =
    'https://github.com/moneyfly004/moneyfly/releases/download/v9.9.9/';

class FakeGitHub implements HttpClientAdapter {
  bool metadataDown = false, checksumDown = false, corruptPayload = false;
  String checksumName = name;
  String? checksumRedirect;
  final calls = <String>[];
  final bytes = [1, 2, 3, 4];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    calls.add(url);
    final metadata = url.contains('api.github.com');
    final sums = url.contains('SHA256SUMS');
    if ((metadata && metadataDown) ||
        (sums && checksumDown) ||
        (!metadata && !sums && !GhMirror.isMirrored(url))) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    if (metadata) {
      return ResponseBody.fromString(
        jsonEncode({
          'tag_name': 'v9.9.9',
          'assets': [
            {
              'name': name,
              'size': bytes.length,
              'browser_download_url': '$release$name',
            },
            {
              'name': 'SHA256SUMS.txt',
              'browser_download_url': '${release}SHA256SUMS.txt',
            },
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (sums) {
      if (checksumRedirect != null) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [checksumRedirect!],
          },
        );
      }
      return ResponseBody.fromString(
        '${UpdateService.sha256HexForTest(bytes)}  $checksumName\n',
        200,
      );
    }
    return ResponseBody.fromBytes(
      corruptPayload ? [4, 3, 2, 1] : bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FakeGitHub network;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UpdateService.resetForTest();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('updater_security_');
    UpdateService.debugCacheDir = () async => temp;
    network = FakeGitHub();
    UpdateService.debugGhDio = Dio()..httpClientAdapter = network;
  });
  tearDown(() {
    UpdateService.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    temp.deleteSync(recursive: true);
  });
  test(
    'authoritative metadata permits mirror payload and fresh launch verification',
    () async {
      final info = await UpdateService.instance.check();
      expect(info, isNotNull);
      final path = await UpdateService.instance.downloadInstaller(info: info);
      expect(path, isNotNull);
      expect(
        network.calls
            .where((u) => u.contains('SHA256SUMS'))
            .every((u) => u.startsWith(release)),
        isTrue,
      );
      expect(network.calls.any(GhMirror.isMirrored), isTrue);
      var launches = 0;
      UpdateService.debugStartDetached = (_, _) async {
        launches++;
        return true;
      };
      expect(
        await UpdateService.instance.installWindowsSilently(path!, info),
        isTrue,
      );
      File(path).writeAsBytesSync([4, 3, 2, 1]);
      expect(
        await UpdateService.instance.installWindowsSilently(path, info),
        isFalse,
      );
      expect(launches, 1);
      expect(
        UpdateService.mirroredUrl('https://github.com/a/b'),
        'https://github.com/a/b',
      );
    },
  );
  test('metadata outage never falls back to mirror or panel', () async {
    network.metadataDown = true;
    UpdateService.debugPanelLatestOverride = (_) async =>
        throw StateError('panel must not supply trust');
    expect(await UpdateService.instance.check(), isNull);
    expect(UpdateService.instance.lastCheckFailed, isTrue);
    expect(UpdateService.instance.lastFailure, isNotEmpty);
    expect(network.calls, hasLength(1));
  });
  test('checksum outage fails closed', () async {
    network.checksumDown = true;
    expect(await UpdateService.instance.check(), isNull);
    expect(network.calls.any(GhMirror.isMirrored), isFalse);
  });
  test('checksum redirects cannot escape GitHub', () async {
    network.checksumRedirect = 'https://evil.example/SHA256SUMS.txt';
    expect(await UpdateService.instance.check(), isNull);
    expect(network.calls.any((u) => u.contains('evil.example')), isFalse);
  });
  test('checksum filename matches exactly', () async {
    network.checksumName = '$name.evil';
    expect(await UpdateService.instance.check(), isNull);
  });
  test('mirror replacing payload is rejected', () async {
    final info = await UpdateService.instance.check();
    network.corruptPayload = true;
    expect(await UpdateService.instance.downloadInstaller(info: info), isNull);
  });
  test('caller supplied hash is not trusted metadata', () async {
    var called = false;
    UpdateService.debugDownloadOverride = (_, _) async {
      called = true;
    };
    final info = UpdateInfo(
      latestVersion: '9.9.9',
      assetName: name,
      downloadUrl: '$release$name',
      sha256: 'a' * 64,
    );
    expect(await UpdateService.instance.downloadInstaller(info: info), isNull);
    expect(called, isFalse);
  });
  test('missing hash blocks every launch sink', () async {
    var called = false;
    UpdateService.debugStartDetached = (_, _) async {
      called = true;
      return true;
    };
    UpdateService.debugLaunchInstallerOverride = (_) async {
      called = true;
      return true;
    };
    UpdateService.debugInstallMacOverride = (_) async {
      called = true;
      return MacInstallResult.installed;
    };
    expect(
      await UpdateService.instance.installWindowsSilently('/tmp/a.exe'),
      isFalse,
    );
    expect(await UpdateService.instance.launchInstaller('/tmp/a.exe'), isFalse);
    expect(
      await UpdateService.instance.installMacDmg('/tmp/a.dmg'),
      MacInstallResult.failed,
    );
    expect(called, isFalse);
  });
  test(
    'unsafe cross-platform basenames cannot reach disk or downloader',
    () async {
      var called = false;
      UpdateService.debugDownloadOverride = (_, _) async {
        called = true;
      };
      for (final bad in [
        '../a.exe',
        r'..\a.exe',
        '/a.exe',
        r'C:\a.exe',
        'a.exe:ads',
        'NUL.exe',
        'a.exe.',
        'a.exe ',
        '.',
        '..',
        'a\u0000.exe',
      ]) {
        final info = UpdateService.trustInfoForTest(
          UpdateInfo(
            latestVersion: '9.9.9',
            assetName: bad,
            downloadUrl: '$release$name',
            sha256: 'a' * 64,
          ),
        );
        expect(
          await UpdateService.instance.downloadedInstaller(info),
          isNull,
          reason: bad,
        );
        expect(
          await UpdateService.instance.downloadInstaller(info: info),
          isNull,
          reason: bad,
        );
      }
      expect(called, isFalse);
    },
  );
  test('symlink installer and escaped cache directory are rejected', () async {
    if (Platform.isWindows) return;
    final outside = Directory.systemTemp.createTempSync('updater_outside_');
    try {
      final file = File('${outside.path}/$name')
        ..writeAsBytesSync(network.bytes);
      final dir = Directory('${temp.path}/update')..createSync();
      final link = Link('${dir.path}/$name')..createSync(file.path);
      final info = await UpdateService.instance.check();
      expect(await UpdateService.instance.downloadedInstaller(info), isNull);
      expect(
        await UpdateService.instance.verifyInstaller(link.path, info),
        isFalse,
      );
      link.deleteSync();
      dir.deleteSync();
      Link(dir.path).createSync(outside.path);
      expect(
        await UpdateService.instance.downloadInstaller(info: info),
        isNull,
      );
      expect(file.readAsBytesSync(), network.bytes);
    } finally {
      outside.deleteSync(recursive: true);
    }
  });
}

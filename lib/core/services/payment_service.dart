import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';
import 'local_paths.dart';

/// 支付 / 套餐目录服务：支付方式列表 + 套餐列表。
/// 目录数据变化频率低，做内存 + 磁盘缓存，购买页冷启动先展示、后台刷新，
/// 避免每次进入都整页转圈。
class PaymentService {
  PaymentService._();
  static final PaymentService instance = PaymentService._();

  static const _cacheFileName = 'package_catalog.json';

  /// 磁盘缓存写串行队列，避免 plans/methods 两个写方并发交错
  static Future<void> _cacheIoQueue = Future.value();

  List<Plan>? _plans;
  List<PayMethod>? _methods;

  /// 套餐列表（[force] 强制刷新；默认命中内存缓存）
  Future<List<Plan>> plans({bool force = false}) async {
    if (!force && _plans != null) return _plans!;
    final data = await ApiClient.instance.get(Endpoints.packages);
    final list = (data is List ? data : <dynamic>[])
        .map((e) => Plan.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => a.price.compareTo(b.price));
    _plans = list;
    unawaited(_enqueueCacheIo(_persist));
    return list;
  }

  /// 支付方式列表（[force] 强制刷新；默认命中内存缓存）
  Future<List<PayMethod>> methods({bool force = false}) async {
    if (!force && _methods != null) return _methods!;
    final data = await ApiClient.instance.get(Endpoints.paymentMethods);
    final list = (data is List ? data : <dynamic>[])
        .map((e) => PayMethod.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    _methods = list;
    unawaited(_enqueueCacheIo(_persist));
    return list;
  }

  /// 读取磁盘缓存的目录（冷启动进入购买页先展示，再后台刷新）
  Future<({List<Plan> plans, List<PayMethod> methods})?> loadCatalog() async {
    try {
      final f = await _cacheFile();
      if (f == null || !f.existsSync()) return null;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        final plans = (decoded['plans'] as List? ?? const [])
            .map((e) => Plan.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        final methods = (decoded['methods'] as List? ?? const [])
            .map((e) => PayMethod.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (plans.isEmpty && methods.isEmpty) return null;
        return (plans: plans, methods: methods);
      }
    } catch (_) {}
    return null;
  }

  /// 把已有目录注入内存缓存（不落盘；购买页冷启动展示磁盘缓存用）
  void adoptCatalog(List<Plan> plans, List<PayMethod> methods) {
    _plans = plans;
    _methods = methods;
  }

  Future<File?> _cacheFile() async {
    final dir = await LocalPaths.supportDir();
    if (dir == null) return null;
    return File('${dir.path}/$_cacheFileName');
  }

  Future<void> _persist() async {
    try {
      final f = await _cacheFile();
      if (f == null) return;
      final plans = _plans;
      final methods = _methods;
      if (plans == null && methods == null) return;
      await f.writeAsString(
        jsonEncode({
          'plans': (plans ?? const []).map((p) => p.toJson()).toList(),
          'methods': (methods ?? const []).map((m) => m.toJson()).toList(),
        }),
        flush: true,
      );
    } catch (_) {}
  }

  static Future<void> _enqueueCacheIo(Future<void> Function() job) {
    final run = _cacheIoQueue.then((_) => job());
    _cacheIoQueue = run.catchError((_) {});
    return run;
  }
}

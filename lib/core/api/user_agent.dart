import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// MoneyFly User-Agent + 设备信息头
///
/// UA 规范：`MoneyFly/<应用版本> (<操作系统特征串>)`
///
/// 额外通过 X-MF-* 自定义头向后端传递设备详情（型号/品牌/OS/类型），
/// 即使 UA 被截断或解析不全，后端也能准确识别设备。
class UserAgent {
  UserAgent._();

  /// 设备详情头（resolve 后填充），由 ApiClient 拦截器注入每个请求
  static Map<String, String> deviceHeaders = {};

  static String build({required String version, String? osSection}) {
    final v = version.trim();
    final os = osSection?.trim() ?? '';
    if (os.isEmpty) return 'MoneyFly/$v';
    return 'MoneyFly/$v ($os)';
  }

  // ---------- 各平台特征串 ----------

  static String androidSection(String release, String model, String buildId) {
    final buf = StringBuffer('Linux; Android ${release.trim()}');
    if (model.trim().isNotEmpty && buildId.trim().isNotEmpty) {
      buf.write('; ${model.trim()} Build/${buildId.trim()}');
    }
    return buf.toString();
  }

  static String windowsSection(int major, int minor) =>
      'Windows NT $major.$minor';

  static String macosSection(int major, int minor) =>
      'Macintosh; Mac OS X ${major}_$minor';

  static String iosSection(String machine, String systemVersion) =>
      'iPhone$machine; iOS $systemVersion';

  // ---------- 运行时解析 ----------

  static Future<String> resolveOsSection() async {
    if (kIsWeb) return '';
    try {
      final plugin = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          return androidSection(a.version.release, a.model, a.id);
        case TargetPlatform.windows:
          final w = await plugin.windowsInfo;
          return windowsSection(w.majorVersion, w.minorVersion);
        case TargetPlatform.macOS:
          final m = await plugin.macOsInfo;
          return macosSection(m.majorVersion, m.minorVersion);
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          return iosSection(i.utsname.machine, i.systemVersion);
        default:
          return '';
      }
    } catch (_) {
      return '';
    }
  }

  /// 采集设备详情（填充 deviceHeaders），resolve() 内部调用
  static Future<void> _collectDeviceHeaders() async {
    if (kIsWeb) return;
    try {
      final plugin = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          deviceHeaders = {
            'X-MF-Device-Model': a.model,
            'X-MF-Device-Brand': a.brand,
            'X-MF-OS': 'Android ${a.version.release}',
            'X-MF-Device-Type': 'mobile',
          };
        case TargetPlatform.windows:
          final w = await plugin.windowsInfo;
          deviceHeaders = {
            'X-MF-Device-Model': w.productName,
            'X-MF-Device-Brand': 'PC',
            'X-MF-OS': 'Windows ${w.majorVersion}.${w.minorVersion}',
            'X-MF-Device-Type': 'desktop',
          };
        case TargetPlatform.macOS:
          final m = await plugin.macOsInfo;
          deviceHeaders = {
            'X-MF-Device-Model': m.model,
            'X-MF-Device-Brand': 'Apple',
            'X-MF-OS': 'macOS ${m.majorVersion}.${m.minorVersion}',
            'X-MF-Device-Type': 'desktop',
          };
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          deviceHeaders = {
            'X-MF-Device-Model': i.utsname.machine,
            'X-MF-Device-Brand': 'Apple',
            'X-MF-OS': 'iOS ${i.systemVersion}',
            'X-MF-Device-Type': i.utsname.machine.toLowerCase().contains('ipad') ? 'tablet' : 'mobile',
          };
        default:
          break;
      }
      // 过滤空值
      deviceHeaders.removeWhere((_, v) => v.isEmpty);
    } catch (_) {}
  }

  /// 解析完整 UA + 设备详情头（启动时由 main() await 调用）
  static Future<String> resolve({required String version}) async {
    final os = await resolveOsSection();
    await _collectDeviceHeaders();
    return build(version: version, osSection: os);
  }
}

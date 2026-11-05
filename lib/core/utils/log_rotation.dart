import 'dart:convert';
import 'dart:io';

/// Scan only the retained prefix, without encoding the entire hostile record.
String capLogRecord(String text, {int maxBytes = 64 * 1024}) {
  const marker = '\n[truncated]\n';
  final budget = maxBytes - marker.length;
  if (budget < 0) throw ArgumentError.value(maxBytes);
  var bytes = 0;
  var end = 0;
  for (final rune in text.runes) {
    final n = rune <= 0x7f ? 1 : (rune <= 0x7ff ? 2 : (rune <= 0xffff ? 3 : 4));
    if (bytes + n > budget) return '${text.substring(0, end)}$marker';
    bytes += n;
    end += rune > 0xffff ? 2 : 1;
  }
  return text;
}

/// Seek a bounded tail even for legacy multi-gigabyte logs.
Future<String> readLogTail(File file, {int maxBytes = 512 * 1024}) async {
  if (!await file.exists()) return '';
  final handle = await file.open();
  try {
    final length = await handle.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    await handle.setPosition(start);
    final bytes = await handle.read(maxBytes);
    var cut = 0;
    if (start > 0) {
      while (cut < bytes.length && bytes[cut] & 0xc0 == 0x80) {
        cut++;
      }
      final nl = bytes.indexOf(10, cut);
      if (nl >= 0 && nl + 1 < bytes.length) cut = nl + 1;
    }
    return utf8.decode(bytes.sublist(cut), allowMalformed: true);
  } finally {
    await handle.close();
  }
}

/// Compact BEFORE appending, so even the active file never exceeds its limit.
Future<void> appendBoundedLog(
  File file,
  String text, {
  int maxBytes = 512 * 1024,
}) async {
  final record = capLogRecord(text, maxBytes: maxBytes);
  final bytes = utf8.encode(record);
  final length = await file.exists() ? await file.length() : 0;
  if (length + bytes.length > maxBytes) {
    final budget = (maxBytes - bytes.length) ~/ 2;
    final tail = budget == 0 ? '' : await readLogTail(file, maxBytes: budget);
    await file.writeAsString(
      budget < 13 ? '' : capLogRecord(tail, maxBytes: budget),
    );
  }
  await file.writeAsBytes(bytes, mode: FileMode.append);
}

/// 日志旋转：取后半段保留，找中点后的第一个换行再截断，保证：
/// - 不在半个 UTF-16 代理对（emoji）中间切，避免写出损坏字符；
/// - 不切断一行，首行始终完整。
///
/// 找不到换行（超长单行，例如整份配置/超长 URL 被当作一条错误日志写入）时
/// **按字节硬截尾**：旧实现原样返回，等于 512KB 上限完全失效（文件可无界增长，
/// 且每次写入都要全量读回 → O(n²) 读盘）。
String keepSecondHalf(String content) {
  final nl = content.indexOf('\n', content.length ~/ 2);
  if (nl >= 0 && nl + 1 < content.length) return content.substring(nl + 1);
  // 无可用换行 → 保留后半段，并把起点对齐到非 UTF-16 代理对边界，
  // 避免首字符是半个 emoji
  var cut = content.length ~/ 2;
  if (cut > 0 && _isLowSurrogate(content.codeUnitAt(cut))) cut++;
  return cut < content.length ? content.substring(cut) : content;
}

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

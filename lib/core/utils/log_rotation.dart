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

bool _isLowSurrogate(int codeUnit) =>
    codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

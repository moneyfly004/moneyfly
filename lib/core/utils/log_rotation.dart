/// 日志旋转：取后半段保留，找中点后的第一个换行再截断，保证：
/// - 不在半个 UTF-16 代理对（emoji）中间切，避免写出损坏字符；
/// - 不切断一行，首行始终完整。
///
/// 找不到换行（超长单行）或换行已是末尾时原样返回（宁可不截断也不丢日志）。
String keepSecondHalf(String content) {
  final nl = content.indexOf('\n', content.length ~/ 2);
  if (nl < 0 || nl + 1 >= content.length) return content;
  return content.substring(nl + 1);
}

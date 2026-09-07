// ignore_for_file: avoid_print
//
// 纯新增测试文件（不修改任何既有文件，包括 lib/l10n/app_strings.dart 与既有测试）。
//
// 目的：i18n 文案一致性守卫。lib/l10n/app_strings.dart 中 _zh / _en 是两组
// 手工维护的 Map<String, String>，历史上出现过：
//   * en 缺键时静默回退中文（见 t(): map[key] ?? _zh[key] ?? key）；
//   * 代码里引用的 key 两张表都没有 → 界面直接渲染原始 key。
//
// 本测试对源文件做纯文本解析（不 import AppStrings，规避其私有 map 成员）：
//   1) zh / en 两组 key 集合必须完全相等（列出差集）；
//   2) lib/ 下所有 .dart 对 AppStrings.t('KEY') 的字面量引用，KEY 必须同时
//      存在于 zh 与 en（允许“定义了但未引用”，反向不约束）；
//   3) 带 {name} 占位符的文案：每个带参 t() 调用（字面量 map 参数）必须覆盖
//      对应语言文案里的全部占位符，否则 {x} 会原样渲染。
//
// 解析规则以文件实际内容为准（key 行形如 `    'key': '...',`，值可能跨行以
// 相邻字符串字面量拼接，值可能用双引号包裹、含转义单引号）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _stringsPath = 'lib/l10n/app_strings.dart';
const String _libDir = 'lib';

final RegExp _keyLineRe = RegExp(r"^[ \t]*'([^']*)':");

/// 读 UTF-8 文本文件（允许少量畸形字节）。
String _readUtf8(String path) =>
    utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);

/// 判断字符是否为 Dart 源码空白（含换行）。
bool _isWs(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

/// 跳过空白（含跨行）。
int _skipWs(String s, int i) {
  while (i < s.length && _isWs(s[i])) {
    i++;
  }
  return i;
}

/// 从 [i]（指向开引号）读取 Dart 单/双引号字符串，返回闭合引号后的下标。
int _skipString(String s, int i) {
  final String q = s[i];
  i++;
  while (i < s.length) {
    if (s[i] == '\\') {
      i += 2;
      continue;
    }
    if (s[i] == q) {
      return i + 1;
    }
    i++;
  }
  return s.length;
}

/// 解析 _zh / _en 之一：key 行集合 + 每个 key 的整段值文本
/// （跨行相邻字符串字面量按语义拼接，保留原始转义序列，不做转义解码 ——
/// 我们只关心 {name} 占位符，是否解码转义不影响结果）。
class _StringMap {
  final Map<String, int> keys; // key -> 1-based 行号
  final Map<String, String> values; // key -> 拼接后的原始值文本
  _StringMap(this.keys, this.values);
}

_StringMap _parseStringMap(List<String> lines, String mapName) {
  // 定位声明行：static const Map<String, String> _zh = {
  int decl = -1;
  for (int i = 0; i < lines.length; i++) {
    final t = lines[i].trimLeft();
    if (t.startsWith('static const Map<String, String> _$mapName')) {
      decl = i;
      break;
    }
  }
  if (decl < 0) {
    throw StateError('未找到 Map<String, String> _$mapName 声明');
  }
  // 声明行可能把 '{' 放在下一行：从声明行往后找第一个含 '{' 的行。
  int open = decl;
  while (open < lines.length && !lines[open].contains('{')) {
    open++;
  }
  final keys = <String, int>{};
  final values = <String, String>{};
  for (int r = open + 1; r < lines.length; r++) {
    final line = lines[r];
    if (line.trim() == '};') {
      break; // 本 map 结束
    }
    final m = _keyLineRe.firstMatch(line);
    if (m == null) {
      continue; // 注释行 / 相邻字符串字面量的续行（行首无 "key':"）
    }
    final key = m.group(1)!;
    keys[key] = r + 1;
    values[key] = _readEntryValue(lines, r, m.end);
  }
  return _StringMap(keys, values);
}

/// 从 [lineIdx] 行、[col] 列（'key': 冒号之后）开始读取一个 map 条目的值。
/// 值 = 若干 Dart 相邻字符串字面量（可能跨行）直到顶层逗号。
String _readEntryValue(List<String> lines, int lineIdx, int col) {
  final b = StringBuffer();
  int row = lineIdx;
  int c = col;
  void next() {
    final l = lines[row];
    if (c < l.length - 1) {
      c++;
    } else {
      row++;
      c = 0;
    }
  }

  String? ch() {
    if (row >= lines.length) return null;
    final l = lines[row];
    return c < l.length ? l[c] : '\n'; // 行尾按换行空白处理
  }

  while (true) {
    // 跳过空白/换行
    while (true) {
      final x = ch();
      if (x != null && _isWs(x)) {
        next();
      } else {
        break;
      }
    }
    final x = ch();
    if (x == null || x == ',') {
      return b.toString(); // 到达条目结束（逗号）或文件尾
    }
    if (x == "'" || x == '"') {
      final String q = x;
      next(); // 越过开引号
      while (true) {
        final cc = ch();
        if (cc == null) {
          return b.toString(); // 防御：意外文件尾
        }
        if (cc == q) {
          next(); // 越过闭引号，随后回到外层循环（可能紧跟 ',' 或相邻字面量）
          break;
        }
        if (cc == '\\') {
          b.write(cc);
          next();
          final e = ch();
          if (e == null) return b.toString();
          b.write(e);
          next();
          continue;
        }
        b.write(cc);
        next();
      }
    } else {
      // 异常字符（理论上只有注释等）→ 跳过本行剩余部分
      while (!(row >= lines.length) && ch() != '\n') {
        next();
      }
    }
  }
}

/// 提取文案值里的占位符 {name}。
final RegExp _phRe = RegExp(r'\{([A-Za-z0-9_]+)\}');

Set<String> _placeholders(String value) =>
    _phRe.allMatches(value).map((m) => m.group(1)!).toSet();

/// 在 [s] 上从 [i] 出发做引号感知的括号配对扫描，返回配对的闭括号下标
/// （支持 (), [], {}；字符串字面量内的括号不算）。
int _findClosingDelimiter(String s, int i) {
  final Map<String, String> pair = {'(': ')', '[': ']', '{': '}'};
  final List<String> stack = <String>[];
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (pair.containsKey(c)) {
      stack.add(c);
    } else if (c == ')' || c == ']' || c == '}') {
      if (stack.isEmpty) return i;
      if (pair[stack.last] == c) {
        stack.removeLast();
        if (stack.isEmpty) return i;
      }
    }
    i++;
  }
  return s.length;
}

/// 调用记录。
class _Call {
  final String key; // 字面量 key；非字面量调用为 ''
  final bool literalKey;
  final Set<String>? argNames; // 有字面量 map 参数时为参数名集合；否则为 null
  final String loc; // file:line
  _Call(this.key, this.literalKey, this.argNames, this.loc);
}

int _lineOf(String content, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < content.length; i++) {
    if (content[i] == '\n') line++;
  }
  return line;
}

/// 扫描单个文件里的 AppStrings.t(...) 调用。
List<_Call> _scanCalls(String content, String path) {
  final calls = <_Call>[];
  final re = RegExp(r'AppStrings\.t\s*\(');
  for (final sm in re.allMatches(content)) {
    final loc = '$path:${_lineOf(content, sm.start)}';
    // 引号感知找配对的 ')' 作为调用结束。
    final close = _findClosingDelimiter(content, sm.end - 1); // 从 '(' 开始
    final callText = content.substring(sm.start, close + 1);
    final km = RegExp(r"""t\s*\(\s*(['"])(.*?)\1""").firstMatch(callText);
    if (km == null) {
      // 非字面量 key（动态拼 key）：无法静态核验，单独上报。
      calls.add(_Call('', false, null, loc));
      continue;
    }
    final key = km.group(2)!;
    Set<String>? argNames;
    var i = _skipWs(callText, km.end);
    if (i < callText.length && callText[i] == ',') {
      i = _skipWs(callText, i + 1);
      if (i < callText.length && callText[i] == '{') {
        final mapEnd = _findClosingDelimiter(callText, i);
        final slice = callText.substring(i, mapEnd + 1);
        argNames = _mapLiteralKeys(slice);
      }
      // 否则第二参是变量/表达式 map：无法静态解析，保持 null。
    }
    calls.add(_Call(key, true, argNames, loc));
  }
  return calls;
}

/// 解析 map 字面量（slice 以 '{' 开头）的字符串 key 集合（结构式扫描，
/// 只把“每条目开头的字符串 + ':'”当作 key，值表达式整体跳过，避免误抓）。
Set<String> _mapLiteralKeys(String slice) {
  final names = <String>{};
  var i = 1; // 越过 '{'
  while (true) {
    i = _skipWs(slice, i);
    if (i >= slice.length || slice[i] == '}') break;
    final c = slice[i];
    if (c == "'" || c == '"') {
      final q = c;
      var j = i + 1;
      while (j < slice.length && slice[j] != q) {
        if (slice[j] == '\\') j++;
        j++;
      }
      if (j >= slice.length) break; // 未闭合：放弃本 map
      final name = slice.substring(i + 1, j);
      final k = _skipWs(slice, j + 1);
      if (k < slice.length && slice[k] == ':') {
        names.add(name);
        i = _skipValueEnd(slice, k + 1);
      } else {
        i = k; // 非 key/value 形态，跳过该字符串继续
      }
    } else {
      i++;
    }
  }
  return names;
}

/// 跳过 map 值表达式，直到顶层 ',' 或 '}'。
int _skipValueEnd(String s, int i) {
  var paren = 0, brack = 0, brace = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '(') {
      paren++;
    } else if (c == ')') {
      paren--;
    } else if (c == '[') {
      brack++;
    } else if (c == ']') {
      brack--;
    } else if (c == '{') {
      brace++;
    } else if (c == '}') {
      if (paren == 0 && brack == 0 && brace == 0) return i;
      brace--;
    } else if (c == ',' && paren == 0 && brack == 0 && brace == 0) {
      return i;
    }
    i++;
  }
  return s.length;
}

void main() {
  final strings = _readUtf8(_stringsPath).split('\n');
  final zh = _parseStringMap(strings, 'zh');
  final en = _parseStringMap(strings, 'en');

  // 扫描 lib/ 全部 .dart
  final allCalls = <_Call>[];
  final refs = <String, List<String>>{}; // key -> 引用位置列表
  final nonLiteral = <String>[];
  final libFiles = Directory(_libDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in libFiles) {
    final content = _readUtf8(f.path);
    final cs = _scanCalls(content, f.path.replaceAll('\\', '/'));
    for (final c in cs) {
      allCalls.add(c);
      if (!c.literalKey) {
        nonLiteral.add(c.loc);
        continue;
      }
      (refs[c.key] ??= <String>[]).add(c.loc);
    }
  }

  group('i18n 文案一致性（test/i18n_consistency_test.dart）', () {
    test('1) _zh 与 _en 的 key 集合完全相等', () {
      // 解析健全性自检：若因解析 bug 一个 key 都没抓到，先大声报错。
      expect(zh.keys.length, greaterThan(400),
          reason: '解析自检失败：_zh 只解析到 ${zh.keys.length} 个 key，'
              '疑似解析 bug（当前文件约 500+ 个）');
      expect(en.keys.length, greaterThan(400),
          reason: '解析自检失败：_en 只解析到 ${en.keys.length} 个 key，'
              '疑似解析 bug（当前文件约 500+ 个）');
      expect(zh.keys.length, en.keys.length,
          reason: 'zh/en key 总数不一致（先看下面差集）');

      final zhOnly = zh.keys.keys.where((k) => !en.keys.containsKey(k)).toList()
        ..sort();
      final enOnly = en.keys.keys.where((k) => !zh.keys.containsKey(k)).toList()
        ..sort();

      final zhOnlyLines =
          zhOnly.map((k) => '  zh:$k (zh 行 ${zh.keys[k]})').join('\n');
      final enOnlyLines =
          enOnly.map((k) => '  en:$k (en 行 ${en.keys[k]})').join('\n');
      final sb = StringBuffer('zh/en key 集合不一致：\n');
      if (zhOnly.isNotEmpty) {
        sb.writeln('── 只在 zh、en 缺失（en 缺键会静默回退中文）──');
        sb.writeln(zhOnlyLines);
      }
      if (enOnly.isNotEmpty) {
        sb.writeln('── 只在 en、zh 缺失 ──');
        sb.writeln(enOnlyLines);
      }
      if (zhOnly.isEmpty && enOnly.isEmpty) {
        sb.write('（无差异）');
      }
      expect(zhOnly, isEmpty, reason: sb.toString());
      expect(enOnly, isEmpty, reason: sb.toString());

      print('1) zh key 数 = ${zh.keys.length}，en key 数 = ${en.keys.length}'
          '，差集 = ${zhOnly.length + enOnly.length}');
    });

    test('2) lib/ 代码引用的 key 必须存在于 zh 与 en', () {
      expect(refs, isNotEmpty, reason: '解析自检失败：lib/ 下未扫到任何引用');

      final missingBoth =
          refs.keys.where((k) => !zh.keys.containsKey(k)).toList()..sort();
      final missingEn =
          refs.keys.where((k) => !en.keys.containsKey(k)).toList()..sort();

      final sb = StringBuffer('以下 key 被 lib/ 代码引用但文案表缺失'
          '（界面会渲染原始 key）：\n');
      for (final k in [...missingBoth, ...missingEn]) {
        sb.writeln('  $k  ← 引用位置: ${refs[k]!.join(', ')}');
      }
      if (missingBoth.isEmpty && missingEn.isEmpty) {
        sb.write('（无缺失）');
      }
      expect(missingBoth, isEmpty, reason: sb.toString());
      expect(missingEn, isEmpty, reason: sb.toString());

      final unused = zh.keys.keys.where((k) => !refs.containsKey(k)).toList();
      final dynNote = nonLiteral.isEmpty
          ? '无'
          : '（位置: ${nonLiteral.join('; ')}）\n'
              '    此类 key 由配置/变量间接传入（如 main.dart 的 '
              '_mainNavEntries.labelKey），本测试无法静态核验其取值，'
              '请人工确认这些 key 都写进了 _zh 与 _en。';
      print('2) 引用调用总数 = ${allCalls.length}，被引用的不同 key = '
          '${refs.keys.length}；zh/en 均存在、仅定义未引用 = ${unused.length}'
          '（允许，反向不约束）');
      print('   动态 key 调用（不可静态核验）: $dynNote');
      if (missingBoth.isNotEmpty) {
        print('   缺失 key 清单: ${missingBoth.join(', ')}');
      }
    });

    test('3) 带参 t() 调用里的占位符需被对应语言文案的 {x} 覆盖', () {
      final failures = <String>[];
      var literalArgCalls = 0;
      var unverifiableArgCalls = 0;
      for (final c in allCalls) {
        if (!c.literalKey) continue;
        final argNames = c.argNames;
        if (argNames == null) {
          // 无参调用：文案无占位符即可，有占位符但从不传参属于
          // 上一条/本条之外的作者意图，这里只统计。
          unverifiableArgCalls++;
          continue;
        }
        literalArgCalls++;
        final phZ = _placeholders(zh.values[c.key] ?? '');
        final phE = _placeholders(en.values[c.key] ?? '');
        final mz = phZ.difference(argNames).toList()..sort();
        final me = phE.difference(argNames).toList()..sort();
        if (mz.isNotEmpty) {
          failures.add('  [zh] $c.key @ ${c.loc}：文案含占位符 '
              '{${mz.join('} {')}} 但调用只传了 {${argNames.toList()..sort()}}，'
              '将原样渲染');
        }
        if (me.isNotEmpty) {
          failures.add('  [en] $c.key @ ${c.loc}：文案含占位符 '
              '{${me.join('} {')}} 但调用只传了 {${argNames.toList()..sort()}}，'
              '将原样渲染');
        }
      }
      final sb = StringBuffer('以下带参调用存在占位符缺失（对应语言文案会渲染原始'
          ' {x}）：\n');
      if (failures.isEmpty) {
        sb.write('（无）');
      } else {
        sb.write(failures.join('\n'));
      }
      expect(failures, isEmpty, reason: sb.toString());

      print('3) 带字面量 map 参数的调用 = $literalArgCalls，'
          '无参/不可静态解析 = $unverifiableArgCalls，占位符问题 = '
          '${failures.length}');
    });
  });
}

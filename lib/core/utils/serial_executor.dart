import 'dart:async';

/// 串行执行器：任务按入队顺序依次执行，杜绝并发「读-改-写」交错
/// （日志追加/设置写盘/缓存写盘等场景通用）。任务抛错只中断该任务本身，
/// 不中断后续队列。
class SerialExecutor {
  Future<void> _tail = Future.value();

  /// 入队一个任务，返回该任务的 future（可 await 单个任务结果）。
  Future<void> run(Future<void> Function() job) {
    final run = _tail.then((_) => job());
    _tail = run.catchError((_) {});
    return run;
  }
}

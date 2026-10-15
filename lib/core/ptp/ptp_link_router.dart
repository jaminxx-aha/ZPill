/// transport 级链路路由器:让单例 [PtpSession] 在 USB / PTP-IP 两条链路间
/// 切换,而不必重建整条下游对象图(repository/thumbnails/downloader/
/// transferEngine/controllers 全部绑在 session 上)。
///
/// 语义地雷(压测定案):
/// - **close() 永不 close 内层** —— `UsbPtpTransport.close()` 是不可逆的
///   单例毒化(转发一次 USB 永久报废)。本类的 close() = detach + 让
///   在途 execute 以 [PtpLinkDetachedException] 失败,内层传输层原封不动。
///   实际装配中无人调用 close()(连接层 teardown 走 detach + 关闭无线
///   实例),此实现只保证「被调了也不炸」。
/// - detach 时在途 execute **绑定旧链**:以旧链自己的结果/异常完成,
///   不被取消(无线链路随即 close 毒化它们,PtpSession 的串行门秒释放)。
/// - 事件:attach 接内层 events 流、detach 取消订阅 —— 卸下后旧链事件
///   不再进广播。
library;

import 'dart:async';
import 'dart:typed_data';

import 'ptp_transport.dart';

/// 无链路可用时的 execute 失败(未 attach / 已 detach / 路由器已 close)。
///
/// 必须 implements Exception:PtpSession.close 的清理路径只 catch
/// `on Exception`,StateError 会逃逸。
final class PtpLinkDetachedException implements Exception {
  const PtpLinkDetachedException(this.message);

  final String message;

  @override
  String toString() => 'PtpLinkDetachedException: $message';
}

/// 链路路由器:当前内层 + 在途事务簿记。
///
/// attach/detach 由连接层(CameraConnectionImpl)在 connect/teardown 时
/// 驱动;execute 转发当前内层。本类自身无超时/重试 —— 链路活性由各
/// 内层(USB 看门狗 / PTP-IP 毒化语义)负责。
final class PtpLinkRouter implements PtpTransport, PtpCancelCapable {
  PtpTransport? _inner;
  StreamSubscription<PtpEvent>? _eventsSub;
  bool _closed = false;
  final _pending = <Completer<PtpResult>>{};

  final _eventsCtrl = StreamController<PtpEvent>.broadcast();

  @override
  Stream<PtpEvent> get events => _eventsCtrl.stream;

  /// 取消-排水透传:内层具备能力(PTP-IP)即转发,否则(USB / 未挂
  /// 内层 / 已关)false no-op。在途 execute 以内层自己的语义收口
  /// (PtpCancelledException / 旧链结果),路由器簿记的 Completer 随
  /// 之接力,无需额外处理。
  @override
  Future<bool> cancelInFlight() async {
    if (_closed) return false;
    // if-case 模式绑定:is 检查不提升到与声明类型无关的能力接口
    if (_inner case final PtpCancelCapable capable) {
      return capable.cancelInFlight();
    }
    return false;
  }

  /// 挂载链路(替换式:旧内层只解绑、不关闭,由调用方管理生命周期)。
  void attach(PtpTransport inner) {
    if (_closed) {
      throw StateError('路由器已关闭');
    }
    detach();
    _inner = inner;
    _eventsSub = inner.events.listen(
      _eventsCtrl.add,
      onError: (Object e) => _eventsCtrl.addError(e),
    );
  }

  /// 卸载链路:挡住后续 execute;在途事务按旧链自己的结果完成;
  /// 事件订阅取消(旧链事件不再进广播)。
  void detach() {
    _eventsSub?.cancel();
    _eventsSub = null;
    _inner = null;
  }

  /// 必须 async:同步 throw 不会包成失败 Future,expectLater/await 与
  /// 上层 `on Exception` 清理都接不住(2026-10-01 USB 看门狗同款教训)。
  @override
  Future<PtpResult> execute(PtpRequest request,
      {void Function(Uint8List chunk)? onData}) async {
    if (_closed) {
      throw const PtpLinkDetachedException('链路路由器已关闭');
    }
    final inner = _inner;
    if (inner == null) {
      throw const PtpLinkDetachedException('无链路:连接建立前不可执行操作');
    }
    // 包一层 Completer:close() 要能让在途事务立刻失败,而 detach()
    // 不打扰它们(以旧链结果完成)。
    final completer = Completer<PtpResult>();
    _pending.add(completer);
    unawaited(inner.execute(request, onData: onData).then(
      (result) {
        _pending.remove(completer);
        if (!completer.isCompleted) completer.complete(result);
      },
      onError: (Object e, StackTrace st) {
        _pending.remove(completer);
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    ));
    return completer.future;
  }

  /// 路由器级关闭:detach + 在途事务以 [PtpLinkDetachedException] 失败。
  /// **永不 close 内层**(UsbPtpTransport 单例不可逆毒化,转发即报废)。
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    detach();
    for (final completer in _pending) {
      if (!completer.isCompleted) {
        completer.completeError(
            const PtpLinkDetachedException('链路路由器已关闭'));
      }
    }
    _pending.clear();
    await _eventsCtrl.close();
  }
}

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:nikon_pill/core/ptpusb/usb_transport.dart';

/// 假字节管道:bulk IN 队列 + 单片余量,模拟 USB 短读序列。
///
/// bulkRead 语义对齐 UsbBytePipe 契约:返回至多 maxLen、≥1 字节或抛
/// TimeoutException;队列分片比 maxLen 长时只给 maxLen,余量留到下次读。
final class FakeUsbBytePipe implements UsbBytePipe {
  final List<Uint8List> outWrites = [];
  final Queue<Uint8List> _inChunks = Queue();
  Uint8List _leftover = Uint8List(0);
  final StreamController<Uint8List> _eventCtrl = StreamController.broadcast();

  /// drainIn 调用计数(中止后排空断言用)。
  int drainCalls = 0;

  /// drainIn 行为注入:null=正常(清超读余量+待读队列);非 null 时
  /// 注入行为先于清理执行 —— 行为里入队的字节视作「排空期间相机还在
  /// 吐、被本轮吸干」(native:清 leftover → 静默窗循环吸到静默为止)。
  Future<void> Function()? drainImpl;

  /// 入队一段「设备发来的」字节。
  void enqueue(Uint8List bytes) => _inChunks.add(bytes);

  /// 按 [sizes] 把 [bytes] 切片入队(尾段自动入队),制造短读序列。
  void enqueueSplit(Uint8List bytes, List<int> sizes) {
    var off = 0;
    for (final s in sizes) {
      enqueue(Uint8List.fromList(bytes.sublist(off, off + s)));
      off += s;
    }
    if (off < bytes.length) {
      enqueue(Uint8List.fromList(bytes.sublist(off)));
    }
  }

  /// 往 interrupt 流注入一条事件字节。
  void emitEvent(Uint8List bytes) => _eventCtrl.add(bytes);

  @override
  Future<void> bulkOut(Uint8List bytes) async => outWrites.add(bytes);

  @override
  Future<Uint8List> bulkRead(int maxLen, {required int timeoutMs}) async {
    if (_leftover.isEmpty) {
      if (_inChunks.isEmpty) {
        throw TimeoutException('fake bulkRead: 窗口内无数据');
      }
      _leftover = _inChunks.removeFirst();
    }
    final take = math.min(maxLen, _leftover.length);
    final out = Uint8List.sublistView(_leftover, 0, take);
    _leftover = Uint8List.sublistView(_leftover, take);
    return out;
  }

  @override
  Stream<Uint8List> get interruptEvents => _eventCtrl.stream;

  /// 对齐 native 契约:排空 = 丢弃管道里的一切残余(超读余量 + 待读
  /// 队列);被中止事务压在队列里的字节,下一事务不再读到。
  @override
  Future<void> drainIn() async {
    drainCalls++;
    final impl = drainImpl;
    if (impl != null) await impl();
    _leftover = Uint8List(0);
    _inChunks.clear();
  }
}

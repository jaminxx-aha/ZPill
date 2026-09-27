/// 目录导航:进入文件夹 / 后退(路径栈,TODO.md §三 P1)。
///
/// 纯逻辑、无 IO,单测覆盖(test/core/browser/directory_navigator_test.dart)。
library;

import 'object_entry.dart';
import 'object_repository.dart';

final class DirectoryNavigator {
  DirectoryNavigator({required this.repository});

  final ObjectRepository repository;

  final List<ObjectEntry> _stack = [];

  /// 当前所在文件夹;null 表示根目录。
  ObjectEntry? get currentFolder => _stack.isEmpty ? null : _stack.last;

  bool get canGoUp => _stack.isNotEmpty;

  /// 进入子文件夹(仅接受 [ObjectKind.folder])并返回其内容。
  Future<List<ObjectEntry>> enter(ObjectEntry folder) async {
    if (!folder.isFolder) {
      throw ArgumentError('enter() 只接受文件夹对象: ${folder.name}');
    }
    final entries = await repository.listFolder(parentHandle: folder.handle);
    _stack.add(folder);
    return entries;
  }

  /// 后退一级;已在根目录时返回根内容。
  Future<List<ObjectEntry>> goUp() {
    if (_stack.isNotEmpty) _stack.removeLast();
    return refresh();
  }

  /// 重列当前目录(下拉刷新 / 事件通知目录变化后调用)。
  Future<List<ObjectEntry>> refresh() =>
      repository.listFolder(parentHandle: currentFolder?.handle ?? 0);
}

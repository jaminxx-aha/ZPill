import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_pill/core/browser/directory_navigator.dart';
import 'package:nikon_pill/core/browser/object_entry.dart';
import 'package:nikon_pill/core/browser/object_repository.dart';
import 'package:nikon_pill/core/ptpip/object_format.dart';

/// Fake 仓库:目录树 root/{DCIM(文件夹), a.jpg}, DCIM/{b.nef}
final class _FakeRepository implements ObjectRepository {
  @override
  Future<List<ObjectEntry>> listFolder({int parentHandle = 0}) async {
    if (parentHandle == 0) {
      return [_folder(1, 'DCIM'), _image(2, 'a.jpg', 1024)];
    }
    if (parentHandle == 1) {
      return [_image(3, 'b.nef', 50 * 1024 * 1024)];
    }
    return const [];
  }

  @override
  Future<ObjectEntry> entryFor(int handle) => throw UnimplementedError();

  @override
  Future<String> thumbPathFor(int handle) => throw UnimplementedError();
}

ObjectEntry _folder(int handle, String name) => ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: 0,
      kind: ObjectKind.folder,
      formatCode: ObjectFormatCode.association,
    );

ObjectEntry _image(int handle, String name, int size) =>
    ObjectEntry(handle: handle, name: name, sizeInBytes: size, kind: ObjectKind.image);

void main() {
  group('DirectoryNavigator 目录导航(TODO.md §三 P1:路径栈)', () {
    test('进入文件夹 / 后退 / 根目录刷新', () async {
      final nav = DirectoryNavigator(repository: _FakeRepository());

      final root = await nav.refresh();
      expect(root.map((e) => e.name), ['DCIM', 'a.jpg']);
      expect(nav.currentFolder, isNull);
      expect(nav.canGoUp, isFalse);

      final dcim = root.first;
      final inside = await nav.enter(dcim);
      expect(inside.map((e) => e.name), ['b.nef']);
      expect(nav.currentFolder?.name, 'DCIM');
      expect(nav.canGoUp, isTrue);

      final back = await nav.goUp();
      expect(back.map((e) => e.name), ['DCIM', 'a.jpg']);
      expect(nav.currentFolder, isNull);
    });

    test('enter() 拒绝非文件夹对象', () async {
      final nav = DirectoryNavigator(repository: _FakeRepository());
      final file = (await nav.refresh()).last; // a.jpg
      expect(() => nav.enter(file), throwsArgumentError);
    });
  });
}

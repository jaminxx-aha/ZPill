/// 浏览页(TODO.md §三):目录列表 + 传输入队 + 多选/过滤/排序(P2)。
library;

import 'package:flutter/material.dart';

import '../../core/browser/directory_navigator.dart';
import '../../core/browser/object_entry.dart';

class BrowserController extends ChangeNotifier {
  // TODO(P1): 注入 DirectoryNavigator(ObjectRepositoryImpl + PtpIpSession)
  final DirectoryNavigator? navigator;

  BrowserController({this.navigator});

  List<ObjectEntry> entries = const [];
  bool loading = false;

  // TODO(P1): load() = navigator.refresh();enter()/goUp() 绑定条目点击与返回
  // TODO(P2): 多选模式(点选/长按/全选/已选大小合计)、类型过滤(JPEG/NEF/
  // TIFF/MP4/MOV)、排序(名称/日期/大小)—— 过滤排序状态放本类,按钮绑这里
  Future<void> load() async {
    loading = true;
    notifyListeners();
    // TODO(P1): entries = await navigator!.refresh();
    await Future<void>.delayed(Duration.zero);
    entries = const [];
    loading = false;
    notifyListeners();
  }

  Future<void> transferSelected() async {
    // TODO(P1): 选中项 → TransferEngine.enqueue(去重)
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  // TODO(P1): 提升为共享实例,并连接后 initState 调 controller.load()
  final BrowserController _controller = BrowserController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览'),
        // TODO(P2): 类型过滤与排序入口,绑定 BrowserController
        actions: const [Icon(Icons.filter_list), SizedBox(width: 12)],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (controller.entries.isEmpty) {
            return const Center(child: Text('连接相机后加载目录(P1)'));
          }
          return ListView.builder(
            itemCount: controller.entries.length,
            itemBuilder: (_, i) => const ListTile(dense: true),
          );
        },
      ),
      // TODO(P1): 返回键拦截 → navigator.goUp();「传输」按钮 → transferSelected()
    );
  }
}

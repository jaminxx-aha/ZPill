/// 传输页(TODO.md §四 P2):进行中 / 历史 / 总进度、取消、清空。
library;

import 'package:flutter/material.dart';

import '../../core/transfer/transfer_task.dart';

class TransfersController extends ChangeNotifier {
  List<TransferTask> tasks = const [];

  // TODO(P1): 订阅 TransferEngine.tasks 驱动本列表;
  // 速度/剩余时间用 SpeedEstimator 按字节增量真实计算(P2)。
  Future<void> cancel(String taskId) async {
    // TODO(P2): engine.cancel(taskId)
  }

  Future<void> clearHistory() async {
    // TODO(P2): engine.clearHistory()
  }
}

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key});

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  // TODO(P1): 提升为共享实例,订阅 TransferEngine.tasks
  final TransfersController _controller = TransfersController();

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
        title: const Text('传输'),
        actions: [
          IconButton(
            tooltip: '清空历史',
            onPressed: controller.clearHistory,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.tasks.isEmpty) {
            return const Center(child: Text('暂无传输任务'));
          }
          return ListView.builder(
            itemCount: controller.tasks.length,
            // TODO(P2): 任务卡片 —— 进度条 + 速度/剩余时间 + 取消按钮(绑 controller)
            itemBuilder: (_, i) => const ListTile(dense: true),
          );
        },
      ),
    );
  }
}

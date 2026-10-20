/// 相机文件操作:删除编排 —— 组成员逐个 DeleteObject,
/// 成功的出仓库缓存(removeHandles),失败计数继续(单文件被卡不拖
/// 死整批)。**不可逆**,调用方(UI)负责确认对话框。
library;

import 'object_repository.dart';
import 'photo_group.dart';
import '../ptp/ptp_session.dart';

final class DeleteResult {
  const DeleteResult({required this.deleted, required this.failed});

  /// 删掉的文件数(逐文件计,双格式组可能部分成功)。
  final int deleted;

  /// 相机拒绝/传输失败的文件数。
  final int failed;

  bool get allFailed => deleted == 0 && failed > 0;
}

final class CameraFileOps {
  const CameraFileOps({required this.session, required this.repository});

  final PtpSession session;
  final ObjectRepository repository;

  /// 删除相册条目(RAW+JPG 组 = 全部成员;视频单文件)。
  ///
  /// 逐成员 0x100B;单文件失败只计数(组内其余成员继续、后续组继续),
  /// 全部结束后一次性把**成功删除**的句柄出缓存(部分失败的组留在
  /// 相册里,下次刷新重配对)。
  Future<DeleteResult> deleteGroups(Iterable<PhotoGroup> groups) async {
    final okHandles = <int>[];
    var failed = 0;
    for (final group in groups) {
      for (final entry in group.members) {
        try {
          await session.deleteObject(entry.handle);
          okHandles.add(entry.handle);
        } on Exception {
          failed++;
        }
      }
    }
    if (okHandles.isNotEmpty) {
      repository.removeHandles(okHandles);
    }
    return DeleteResult(deleted: okHandles.length, failed: failed);
  }
}

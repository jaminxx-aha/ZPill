/// 相册评级控制器:真源 = 相机(MTP 0xDC8A Rating,官方 §6.6.3.3),
/// 状态在 [ObjectRepository] 的评级缓存(乐观上屏/回滚都在 rateGroup
/// 内),本控制器只做转发、通知与改评成功沿的图库快照传播。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/object_repository.dart';
import '../../core/browser/photo_group.dart';

/// 评分设置 UI 总闸:评分功能现存问题待修,先只藏「设置评级」入口
/// (查看器顶栏打星钮,唯一设评沿;photo_viewer_page)。评级展示与
/// 筛选(网格角标、筛选弹层评级分区、显示·评级行、图库评分)不受
/// 此闸,数据层 0xDC8A 读取照常。修复后置 true 恢复(守闸用例在
/// photo_viewer_page_test,翻闸时改回 findsOneWidget)。
const kRatingUiEnabled = false;

final class AlbumRatingsController extends ChangeNotifier {
  AlbumRatingsController({required this.repository, this.onPropagate}) {
    _sub = repository.updates.listen((_) => notifyListeners());
  }

  final ObjectRepository repository;

  /// 改评成功沿的传播回调(图库文件快照;AppServices 注入,可空)。
  final Future<void> Function(PhotoGroup group, int stars)? onPropagate;

  StreamSubscription<AlbumsUpdate>? _sub;

  /// 组当前评分(0 = 未评;相机评级未建立时恒 0,徽标/筛选随之隐藏)。
  int ratingOf(PhotoGroup group) => repository.ratingForGroup(group);

  /// 组「已评级·档位未知」(NEF 形态:有星但 API 拿不到档位)。
  bool ratedUnknown(PhotoGroup group) =>
      repository.groupRatedUnknown(group);

  /// 组垃圾星(机身「垃圾桶+星」0 档态)。
  bool trashStar(PhotoGroup group) => repository.groupTrashStar(group);

  /// 相机评级数据是否已建立(筛选分区只在建立后展示)。
  bool get available => repository.ratingsLoaded;

  /// 即时补读当前组的评级(网格格 build 沿,轻量段):图像只发 0xDC8A
  /// 星档一笔,视频走容器 NCTG;昂贵的 256KB 删除候选甄别留给
  /// [ensureTrash] 驻留沿,滚过格不占链。
  void ensure(PhotoGroup group) =>
      repository.requestRating(group.primary.handle, trashProbe: false);

  /// 查看器沿全链(星档 + 删除候选甄别):单件在目,全答不构成队列。
  void ensureFull(PhotoGroup group) =>
      repository.requestRating(group.primary.handle);

  /// 驻留沿补删除候选甄别(256KB XMP 头读;NEF 兼档位兜底)。去重集
  /// 保证与后台甄别/查看器全链互不重发。
  void ensureTrash(PhotoGroup group) =>
      repository.requestTrashProbe(group.primary.handle);

  /// 打星([stars] 0 = 清除):相机写入,失败原样上抛(乐观上屏由
  /// 仓库回滚);成功后传播图库快照(传播失败不挡 —— 相机已落账,
  /// 下次下载重写快照)。
  Future<void> rate(PhotoGroup group, int stars) async {
    await repository.rateGroup(group, stars);
    try {
      await onPropagate?.call(group, stars);
    } on Object {
      // 快照传播失败不挡评级主流程
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

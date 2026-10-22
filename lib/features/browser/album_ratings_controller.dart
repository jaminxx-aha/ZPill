/// 相册评级控制器:真源 = 相机(MTP 0xDC8A Rating,官方 §6.6.3.3),
/// 状态在 [ObjectRepository] 的评级缓存(乐观上屏/回滚都在 rateGroup
/// 内),本控制器只做转发、通知与改评成功沿的图库快照传播。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/object_repository.dart';
import '../../core/browser/photo_group.dart';

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

  /// 即时补读当前组的评级(查看器打开/翻页沿):后台补读未到的先拉,
  /// 0 = 已问过未评,不重复发。
  void ensure(PhotoGroup group) =>
      repository.requestRating(group.primary.handle);

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

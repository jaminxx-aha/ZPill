/// 评级筛选档(相机相册与图库筛选弹层共用)。机身评级条 7 态:
/// 删除候选(垃圾桶+星)/ 未评分 / ★1-5 —— 删除候选标记的协议落点
/// 待取证(0x9434 bit0、0xDC8A、头 64KB XMP 三通道均未现形,深挖中)。
/// 星档精确匹配;「已评级」收编档位未知形态(NEF 位图有星但 0xDC8A
/// 拒且 XMP 头读无标记)。
library;

enum RatingFilter {
  all('libpage.all', 0, isAll: true),
  none('grid.ratingNone', 0),
  trash('grid.ratingTrash', 0),
  rated('grid.ratingRated', 0),
  one('', 1),
  two('', 2),
  three('', 3),
  four('', 4),
  five('', 5);

  const RatingFilter(this.label, this.stars, {this.isAll = false});

  /// 档位文案键(all/none/trash/rated;星档行画星无文案,空串不消费)。
  final String label;

  /// 档位星数(非星档恒 0,展示行自行画星)。
  final int stars;

  /// all = 不筛;星档 = 评级等于该星数;none/trash/rated 见 [allows]。
  final bool isAll;

  bool allows(
    int rating, {
    bool ratedUnknown = false,
    bool trashStar = false,
  }) =>
      switch (this) {
        all => true,
        none => rating == 0 && !ratedUnknown && !trashStar,
        trash => trashStar && rating == 0,
        rated => rating > 0 || ratedUnknown,
        _ => rating == stars,
      };
}

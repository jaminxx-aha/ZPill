/// 相册视图模型:浏览页只呈现「相册」,不再暴露文件夹树。
///
/// 相册 = 直接包含照片/视频子对象的文件夹 —— MISC 之类纯杂项目录
/// 自然消失;另有一个汇总相册聚合全部照片与视频(用户需求:
/// 「相册可以按照文件夹区分,或者汇总」,两种都要)。
library;

import 'object_repository.dart';
import 'photo_group.dart';

final class CameraAlbum {
  const CameraAlbum({
    required this.name,
    required this.folderHandle,
    required this.items,
  });

  /// 汇总「全部照片」相册的 folderHandle 哨兵(相机句柄从非 0 起)。
  static const int allPhotosHandle = 0;

  /// 汇总相册:全部 image/video,按 [ObjectRepositoryImpl.compareEntries]
  /// 排序(新的在前)。name = t() 键(真实相册 name 是相机上报文件夹名,
  /// 直通不译;汇总相册吐抽象键,消费点 photo_grid_page 包 t)。
  factory CameraAlbum.allPhotos(List<PhotoGroup> items) => CameraAlbum(
        name: 'grid.allPhotos',
        folderHandle: allPhotosHandle,
        items: List.unmodifiable(items),
      );

  /// 相册名(文件夹对象名;汇总相册为汇总键,见 [CameraAlbum.allPhotos])。
  final String name;

  /// 对应文件夹对象的 handle;[allPhotosHandle] 表示汇总相册。
  final int folderHandle;

  /// 相册内容(合并后的照片条目:RAW+JPG 一组,见 [PhotoGroup];
  /// 按拍摄时间倒序,新的在前)。
  final List<PhotoGroup> items;

  bool get isAggregate => folderHandle == allPhotosHandle;

  bool get isEmpty => items.isEmpty;

  /// 封面:最新一张(网格卡片背景)。
  PhotoGroup? get cover => items.isEmpty ? null : items.first;

  /// 最新拍摄时间(相册排序用;无时间信息为 null)。
  DateTime? get newestAt => cover?.capturedAt;
}

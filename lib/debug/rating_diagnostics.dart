/// 相机评级(MTP 0xDC8A)真机定向诊断(debug 构建,连接沿自动跑一次)。
///
/// 背景(2026-10-22 真机首验):相机上评星 App 读不到、App 打星相机
/// 不改 —— 双向皆哑,且代码路径把拒答全吞了(探针静默降级、写失败仅
/// SnackBar)。本序列逐环取证,每环独立回答一个问题:
/// ① 0x9801 能力表:0xDC8A 在不在册(规格书 §6.6.3.3 明文支持,固件
///    是否真开门另说);
/// ② 0x9802 GetObjectPropDesc(0xDC8A, JPEG):数据类型/GetSet/FORM
///    原文(相机口径的读写性与取值域);
/// ③ 0x9805 按夹 P3=0xDC8A:批量读返回什么(空数据集也是证据);
/// ④ 0x9803 读单对象:裸值字节或错误码;
/// ⑤ 0x9804 写(+读回):写 ★3 到最新一张照片(PTP_RATING_WRITE=true
///    才发,默认关),再读回看相机收没收;NEF 件同步试一发(规格说
///    0x3000 不在适用表,验证拒答形态)。
///
/// 输出走 debugPrint(标签 [评级诊断]);用完不删,评级链后续真机
/// 首验可复用。跑法:
/// `flutter run --dart-define=PTP_RATING_DIAG=true [--dart-define=PTP_RATING_WRITE=true]`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/browser/album.dart';
import '../core/browser/object_entry.dart';
import '../core/browser/object_repository.dart';
import '../core/browser/photo_group.dart';
import '../core/ptp/operation_codes.dart';
import '../core/ptp/ptp_session.dart';
import '../core/ptpip/object_format.dart';
import '../core/utils/byte_reader.dart';
import '../platform/services.dart';

const bool kRatingDiagnostics = bool.fromEnvironment('PTP_RATING_DIAG');
const bool kRatingWriteProbe = bool.fromEnvironment('PTP_RATING_WRITE');

final class RatingDiagnostics {
  RatingDiagnostics._();

  static final List<String> _lines = [];

  static void _p(Object? msg) {
    final line = '[评级诊断] $msg';
    _lines.add(line);
    debugPrint(line); // debug 构建进统一日志;Release 走文件(见 run 尾)
  }

  static String _h(int v) =>
      '0x${v.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  static String _hex(Uint8List bytes, [int max = 48]) {
    final shown = bytes.take(max).map((b) => b.toRadixString(16).padLeft(2, '0'));
    final tail = bytes.length > max ? '…(+${bytes.length - max}B)' : '';
    return '${shown.join(' ')}$tail';
  }

  /// 连接沿(侧链让路窗后)调用;自带异常兜底,永不抛出。
  static Future<void> run({
    required PtpSession session,
    required ObjectRepository repository,
  }) async {
    try {
      await _run(session, repository);
    } catch (e, s) {
      _p('诊断自身异常: $e');
      _p('$s');
    } finally {
      // Release 的 print 不进进程 stdout(走 os_log,devicectl --console
      // 抓不到):全文落 dataDir/rating_diag.txt,装机侧 devicectl copy
      // from appDataContainer 拉。写失败不遮诊断(内存里还有)。
      try {
        final dir = await PlatformServices.gallery.dataDir();
        File('$dir/rating_diag.txt').writeAsStringSync(
            '${_lines.join('\n')}\n', flush: true);
      } on Object {
        // 落盘失败不抛
      }
    }
  }

  /// 轮询仓库载入(会话真开的判据:应用自己的枚举通路),至多 30s。
  /// 失败静默(未连上/无照片语义归调用方,后续环自行报错)。
  static Future<List<CameraAlbum>> _waitForAlbums(
      ObjectRepository repository) async {
    for (var i = 0; i < 10; i++) {
      try {
        final albums = await repository.loadAlbums();
        if (albums.isNotEmpty) return albums;
      } on Exception {
        // 会话未开/链路抖动:过 3s 再试
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return const [];
  }

  static Future<void> _run(
      PtpSession session, ObjectRepository repository) async {
    // 不设 kDebugMode 闸:诊断随 Release 包真机跑(dart-define 显式开才
    // 到这里),全文落 dataDir/rating_diag.txt(见 run 尾)。
    _p('── 开始(写探针=${kRatingWriteProbe ? '开' : '关'}) ──');

    // ⓪ 等会话真开 + 取样:钥匙用 loadAlbums(应用自己的枚举通路,
    // 真机已证可用)——首轮曾拿 0x9801 当钥匙,实测 Zf 对 0x9801 恒回
    // 0x2006(Session_Not_Open 假象,相册枚举同期正常 = 能力表假门
    // 又一员),不能作会话状态判据。至多 30s;仍失败则照常跑后续环
    //(各环自己报错)。
    final albums = await _waitForAlbums(repository);
    // 取样必须真 JPEG:上轮踩坑 —— 最新组是 NEF 组(primary 回落
    // members.first),「JPG 拒答」实际也是 NEF;0x3000 不在 §6.6.3.3
    // 适用表,NEF 被拒是合规形态,不能当死路证据。全库优先挑首个有
    // JPG 的组,纯 RAW 库才退首条目(如实打 ⚠️ 标)。
    PhotoGroup? newest;
    outer:
    for (final album in albums) {
      for (final group in album.items) {
        newest ??= group; // 兜底:首条目
        if (group.hasJpg) {
          newest = group;
          break outer;
        }
      }
    }
    if (newest == null) {
      _p('── 结束(仓库 30s 内无可取样条目,未连上/无照片;①~⑤未跑)──');
      return;
    }

    // ① 0x9801 能力表:0xDC8A 在不在册(非致命:0x9801 本身可能是假门)。
    var props = const <int>[];
    try {
      props = await session.getObjectPropsSupported();
      _p('① 0x9801 对象属性表 ${props.length} 项: '
          '${props.map(_h).join(' ')}');
      _p('① 0xDC8A ${props.contains(PtpObjectPropCode.rating) ? '在册 ✓' : '不在册 ✗(读不到写不进的总根因候选)'}');
    } on PtpResponseException catch (e) {
      _p('① 0x9801 拒答: $e(能力表假门形态,仅记录)');
    }

    // ② 0x9802 Desc(JPEG 形):类型/GetSet/FORM 原文。
    try {
      final desc = await session.getObjectPropDesc(
          PtpObjectPropCode.rating, ObjectFormatCode.exifJpeg);
      _p('② 0x9802 Desc(u16 类型 + u8 GetSet + FORM)= ${_hex(desc)}');
    } on PtpResponseException catch (e) {
      _p('② 0x9802 拒答: $e');
    }

    final jpg = newest.primary;
    final nef = newest.raw;
    _p('取样(${newest.hasJpg ? '真 JPEG 组' : '⚠️ 纯 RAW 组,只有 NEF 可打'}): '
        '${jpg.name}(${jpg.kind}/${_h(jpg.formatCode ?? 0)}, handle=${_h(jpg.handle)}, '
        'parent=${_h(jpg.parentHandle)}, 仓库评级=${repository.ratingForHandle(jpg.handle)})');

    // ③ 0x9805 按夹批量(P3=0xDC8A,depth=1)。degradeOnFailure=false:
    // 探针拒答只证该形态,不毒化 App 枚举快路。
    try {
      final list = await session.getObjectPropList(jpg.parentHandle,
          propCode: PtpObjectPropCode.rating,
          depth: 1,
          degradeOnFailure: false);
      _p('③ 0x9805 P3=0xDC8A 返回 ${list.length} 条:');
      for (final p in list.take(8)) {
        _p('   handle=${_h(p.handle)} type=${_h(p.dataType)} '
            'raw=[${_hex(p.rawValue, 8)}] value=${p.value}');
      }
      if (list.isEmpty) {
        _p('③ 空数据集:相机 OK 但不给评级数据(属性未激活/无评级态)');
      }
    } on PtpResponseException catch (e) {
      _p('③ 0x9805 拒答: $e');
    }

    // ④ 0x9803 读单对象(JPG)。
    try {
      final value =
          await session.getObjectPropValue(jpg.handle, PtpObjectPropCode.rating);
      _p('④ 0x9803 ${jpg.name} = [${_hex(value, 8)}]'
          '${value.length >= 2 ? '(u16=${ByteReader(value).u16()})' : ''}');
    } on PtpResponseException catch (e) {
      _p('④ 0x9803 拒答: $e');
    }
    if (nef != null) {
      try {
        final value = await session.getObjectPropValue(
            nef.handle, PtpObjectPropCode.rating);
        _p('④ 0x9803 NEF(${nef.name}) = [${_hex(value, 8)}]');
      } on PtpResponseException catch (e) {
        _p('④ 0x9803 NEF 拒答: $e');
      }
    }

    // ⑤ 0x9804 写(+读回):50 = ★3(PTP_RATING_WRITE=true 才发)。
    if (kRatingWriteProbe) {
      try {
        await session.setObjectPropValue(jpg.handle, PtpObjectPropCode.rating,
            Uint8List.fromList([50, 0]));
        _p('⑤ 0x9804 ${jpg.name} 写 50(★3) → OK');
        final back = await session
            .getObjectPropValue(jpg.handle, PtpObjectPropCode.rating);
        _p('⑤ 读回 = [${_hex(back, 8)}]'
            '${back.length >= 2 ? '(u16=${ByteReader(back).u16()})' : ''}'
            ' —— 相机上播放该张核对星级');
      } on PtpResponseException catch (e) {
        _p('⑤ 0x9804 ${jpg.name} 拒答: $e');
      }
      if (nef != null) {
        try {
          await session.setObjectPropValue(
              nef.handle, PtpObjectPropCode.rating, Uint8List.fromList([50, 0]));
          _p('⑤ 0x9804 NEF 写 50 → OK(规格预期拒,居然过了)');
        } on PtpResponseException catch (e) {
          _p('⑤ 0x9804 NEF 拒答(规格预期形态): $e');
        }
      }
    } else {
      _p('⑤ 写探针未开(--dart-define=PTP_RATING_WRITE=true)');
    }

    // ⑥ 0x9434 GetObjectsMetaData:尼康专有批量元数据,ObjectAttribute
    // bit0 = Rating 有无 —— NEF 评级的候选批量通道(SnapBridge 疑似路)。
    // 有无旗标全格式应可得;星级档位仍只能适用格式逐张 0x9803。
    try {
      final raw = await session.getObjectsMetaDataRaw();
      List<PtpObjectMeta> metas;
      try {
        metas = parseObjectsMetaData(raw);
      } on FormatException {
        // 布局与文档表不符:原文十六进制取证(首 160B + 总长),下轮定布局。
        _p('⑥ 0x9434 应答 ${raw.length}B,17B 步进解不开,原文: '
            '${raw.take(160).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        _p('── 结束(⑥ 布局待定)──');
        return;
      }
      final rated = metas.where((m) => m.hasRating).length;
      final protectedCount = metas.where((m) => m.isProtected).length;
      _p('⑥ 0x9434 返回 ${metas.length} 条(bit0 有星 $rated / bit1 保护 '
          '$protectedCount)');
      final byHandle = {for (final m in metas) m.handle: m};
      // ObjectAttribute 完整 32 位:bit0=Rating/bit1=Protected 之外,
      // 删除候选可能占别的位(规格标 Reserved,固件未必守约)。
      for (final m in metas) {
        final entryName = await tryName(repository, m.handle);
        _p('⑥ 属性 ${m.attribute.toRadixString(2).padLeft(32, '0')} '
            '(${_h(m.attribute)}) $entryName');
      }
      final sampleHandles = [jpg.handle, if (nef != null) nef.handle];
      for (final h in sampleHandles) {
        final m = byHandle[h];
        _p('⑥ 取样 ${_h(h)}: ${m == null ? '不在元数据表' : (m.hasRating ? 'bit0=1 有星' : 'bit0=0 无星')}'
            '${m?.isProtected ?? false ? '(保护)' : ''}');
      }
      // 全卡逐张读:每个对象 0xDC8A 原值都读(不分 bit0)—— 垃圾星与
      // 未评级是否协议可分的终审(此前只读 bit0=1 的,垃圾星若不置位
      // 就被漏掉;7 张全态样张正好一枪标定)。
      for (final m in metas) {
        var name = _h(m.handle);
        var isFolder = false;
        ObjectEntry? entry;
        try {
          entry = await repository.entryFor(m.handle);
          name = entry.name;
          isFolder = entry.isFolder;
        } on Exception {
          // 不在册(SDRAM/已删):句柄兜底
        }
        if (isFolder) {
          _p('⑥ $name(夹) 跳过');
          continue;
        }
        try {
          final value = await session
              .getObjectPropValue(m.handle, PtpObjectPropCode.rating);
          _p('⑥ $name(${_h(m.handle)}) bit0=${m.hasRating ? 1 : 0} '
              '= [${_hex(value, 8)}]'
              '${value.length >= 2 ? '(u16=${ByteReader(value).u16()})' : ''}');
        } on PtpResponseException catch (e) {
          _p('⑥ $name(${_h(m.handle)}) bit0=${m.hasRating ? 1 : 0} 拒答: $e');
        }
        // ⑦ 文件元数据深挖(用户判:标记必在文件里):头/尾各 256KB
        // 扫 Rating 痕迹 + XMP 包全文截段 —— 删除候选标记的落点取证。
        try {
          final size = entry?.sizeInBytes ?? 0;
          final head = await session.getPartialObject(m.handle, 0, 262144);
          var tail = Uint8List(0);
          if (size > 262144) {
            tail = await session
                .getPartialObject(m.handle, size - 262144, 262144);
          }
          String scan(String zone, Uint8List bytes) {
            final text = String.fromCharCodes(bytes);
            final ratingMatch =
                RegExp(r'<xmp:Rating>([^<]*)</xmp:Rating>').firstMatch(text);
            final ratingCount = 'Rating'.allMatches(text).length;
            final hasXmp = text.contains('<x:xmpmeta');
            if (ratingMatch != null) {
              return '$zone xmp:Rating=${ratingMatch.group(1)} '
                  '(Rating 字样 $ratingCount 处, XMP=$hasXmp)';
            }
            if (ratingCount > 0) {
              final at = text.indexOf('Rating');
              final from = at < 40 ? 0 : at - 40;
              final ctx = text
                  .substring(from, (at + 80).clamp(0, text.length))
                  .replaceAll('\n', ' ');
              return '$zone 无 xmp:Rating 但 Rating 字样 $ratingCount 处, '
                  'XMP=$hasXmp, 首处上下文: …$ctx…';
            }
            return '$zone 无任何 Rating 痕迹 (XMP=$hasXmp)';
          }

          _p('⑦ $name(${_h(m.handle)}) bit0=${m.hasRating ? 1 : 0} '
              'size=$size');
          _p('⑦   ${scan('头', head)}');
          if (tail.isNotEmpty) _p('⑦   ${scan('尾', tail)}');
          // XMP 包全文截段:垃圾星/未评分/有星的包体直接对读。
          final headText = String.fromCharCodes(head);
          const metaStart = '<x:xmpmeta';
          const metaEnd = '</x:xmpmeta>';
          final s = headText.indexOf(metaStart);
          final e = headText.indexOf(metaEnd);
          if (s >= 0 && e > s) {
            final packet = headText
                .substring(s, e + metaEnd.length)
                .replaceAll(RegExp(r'\s+'), ' ');
            _p('⑦   XMP 包(${packet.length}字符): '
                '${packet.substring(0, packet.length.clamp(0, 1400))}');
          }
        } on Exception catch (e) {
          _p('⑦ $name 深挖失败: $e');
        }
        // ⑧ 视频(MOV/MP4)box 结构行走:顶层 ftyp/mdat/moov 逐箱跳读
        // (每步只读 16B 头),moov 内再走一层找 udta/XMP/meta —— 容器
        // 里到底嵌不嵌评级/删除候选标记的终审。
        if (isVideoFilename(name)) {
          try {
            final size = entry?.sizeInBytes ?? 0;
            final found =
                await _walkVideoBoxes(session, m.handle, size);
            _p('⑧ $name 容器扫描: ${found.isEmpty ? '无任何 Rating 痕迹' : found}');
          } on Exception catch (e) {
            _p('⑧ $name 容器扫描失败: $e');
          }
        }
      }
    } on PtpResponseException catch (e) {
      _p('⑥ 0x9434 拒答: $e');
    }
    _p('── 结束 ──');
  }

  /// 句柄名兜底(不在册给句柄十六进制)。
  static Future<String> tryName(ObjectRepository repository, int handle) async {
    try {
      return (await repository.entryFor(handle)).name;
    } on Exception {
      return _h(handle);
    }
  }

  /// MP4/MOV 顶层箱行走(mdat 按尺寸跳过,不读载荷):moov 找到后再
  /// 走一层子箱,udta/XMP/meta 载荷读出搜 Rating 痕迹。读次数硬上限
  /// 60(诊断纪律:有限步取证)。
  static Future<String> _walkVideoBoxes(
      PtpSession session, int handle, int size) async {
    final hits = <String>[];
    var reads = 0;
    Future<Uint8List?> read(int off, int len) async {
      if (reads++ > 60 || off < 0 || off + len > size) return null;
      return session.getPartialObject(handle, off, len);
    }

    Future<void> walk(int start, int end, int depth) async {
      // ignore: avoid_print
      _p('⑧   walk start=$start end=$end depth=$depth');
      var offset = start;
      while (offset + 8 <= end && reads <= 60) {
        final hdr = await read(offset, 64);
        if (hdr == null || hdr.length < 8) {
          _p('⑧   箱头读不足 @${offset.toRadixString(16)}: '
              '${hdr == null ? 'null' : '${hdr.length}B [${_hex(hdr, 8)}]'}');
          return;
        }
        // MP4 箱尺寸是**大端序**(ISO BMFF;PTP ByteReader 是小端,勿混
        // —— 首版小端读出 4 亿大箱静默止步,一行箱图都没出)。
        var boxSize =
            (hdr[0] << 24) | (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
        final type = String.fromCharCodes(hdr.sublist(4, 8));
        if (boxSize == 1) {
          if (hdr.length < 16) return;
          var large = 0;
          for (final b in hdr.sublist(8, 16)) {
            large = (large << 8) | b;
          }
          boxSize = large;
        } else if (boxSize == 0) {
          boxSize = end - offset; // 到文件/父箱末尾
        }
        if (boxSize < 8 || offset + boxSize > end) {
          _p('⑧   病箱 $type @${offset.toRadixString(16)} 大小 $boxSize, 止步');
          return;
        }
        if (depth == 0) {
          _p('⑧   箱 $type @${offset.toRadixString(16)} 大小 $boxSize');
        }
        if (type == 'moov' && depth == 0) {
          await walk(offset + 8, offset + boxSize, depth + 1);
        } else if (depth == 1) {
          // 全子箱清单;udta 可能是 MB 级(真机 1.98MB)—— 分块全读,
          // 扫删除候选/评级的可能落点关键词。
          _p('⑧   子箱 $type @${offset.toRadixString(16)} 大小 $boxSize');
          if (type == 'udta') {
            const chunk = 262144;
            var got = 0;
            final raw = BytesBuilder();
            while (got < boxSize && reads <= 120) {
              final len = chunk.clamp(0, boxSize - got);
              final payload = await read(offset + got, len);
              if (payload == null) break;
              raw.add(payload);
              got += len;
            }
            final udta = raw.toBytes();
            _p('⑧   udta 全读 ${udta.length}/${boxSize}B');
            // udta 子箱行走(BE 尺寸)—— raw 含父箱 8B 头,子箱从 +8 起;
            // NCDT 是唯一子箱(~2MB),NCHD/NCTG 在它里面,再走一层。
            var uoff = 8;
            while (uoff + 8 <= udta.length) {
              final bsize = (udta[uoff] << 24) |
                  (udta[uoff + 1] << 16) |
                  (udta[uoff + 2] << 8) |
                  udta[uoff + 3];
              if (bsize < 8 || uoff + bsize > udta.length) break;
              final btype = String.fromCharCodes(
                  udta.sublist(uoff + 4, uoff + 8));
              _p('⑨   udta 子箱 $btype 大小 $bsize');
              if (btype == 'NCDT') {
                // NCDT 内层:NCHD(头部)/NCTG(标签表)/……
                var noff = uoff + 8;
                final nend = uoff + bsize;
                while (noff + 8 <= nend) {
                  final nsize = (udta[noff] << 24) |
                      (udta[noff + 1] << 16) |
                      (udta[noff + 2] << 8) |
                      udta[noff + 3];
                  if (nsize < 8 || noff + nsize > nend) break;
                  final ntype = String.fromCharCodes(
                      udta.sublist(noff + 4, noff + 8));
                  _p('⑨   NCDT 子箱 $ntype 大小 $nsize');
                  if (ntype == 'NCTG') {
                    // 全载荷十六进制(垃圾桶 MP4 vs 有星 MOV 离线对差,
                    // 标记字节直接找;条目 = [u16 tag][u16 count][value],
                    // 每 tag 的类型查静态表,诊断不做逐条解析)。
                    final payload = udta.sublist(noff + 8, noff + nsize);
                    final hex = payload
                        .map((b) => b.toRadixString(16).padLeft(2, '0'))
                        .join();
                    for (var i = 0; i < hex.length; i += 1100) {
                      _p('⑨   NCTG[${i ~/ 1100}] '
                          '${hex.substring(i, (i + 1100).clamp(0, hex.length))}');
                    }
                  }
                  noff += nsize;
                }
              }
              uoff += bsize;
            }
          } else if (boxSize <= 200000 && (type == 'XMP ' || type == 'meta' || type == 'NCTG')) {
            final payload = await read(offset, boxSize);
            if (payload != null) {
              final text = String.fromCharCodes(payload);
              final printable = text.replaceAll(RegExp(r'[^\x20-\x7e]'), '.');
              _p('⑧   $type 载荷 ASCII(${payload.length}B): '
                  '${printable.substring(0, printable.length.clamp(0, 1600))}');
            }
          }
        }
        offset += boxSize;
      }
    }

    await walk(0, size, 0);
    return hits.join(' | ');
  }
}

import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/ptp/device_prop.dart';
import 'package:nikon_pill/core/ptp/operation_codes.dart';
import 'package:nikon_pill/features/remote/remote_capture_strip.dart';
import 'package:nikon_pill/features/remote/shooting_param_catalog.dart';

ShootingParam _param(int code) =>
    kShootingParams.singleWhere((p) => p.code == code);

void main() {
  test('目录顺序与码表(标准区在册 + 厂商区候选;序 = 刷新/展示序)', () {
    expect(kShootingParams.map((p) => p.code), [
      PtpDevicePropCode.exposureProgramMode,
      PtpDevicePropCode.fNumber,
      PtpDevicePropCode.exposureTime,
      PtpDevicePropCode.exposureIndex,
      PtpDevicePropCode.exposureBiasCompensation,
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.wbColorTemp,
      PtpDevicePropCode.flashMode,
      PtpDevicePropCode.exposureMeteringMode,
      PtpDevicePropCode.stillFocusMode,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
      PtpDevicePropCode.rawCompressionType,
      PtpDevicePropCode.captureAreaCrop,
      PtpDevicePropCode.stillFocusMeteringMode,
      0x0001D006, // 主体检测(Ex 扩展码)
      0x0001D01C, // 色调(Ex 扩展码)
      PtpDevicePropCode.activePicCtrlItem,
    ]);
  });

  test('display:模式尼康方言表(2=P/3=A/4=S,U 段与场景段齐)',
      () {
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(1), 'param.modeM');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(2), 'param.modeP',
        reason: '尼康方言 2=P(ISO 标准表 2=自动是错的)');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(3), 'param.modeA');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(4), 'param.modeS');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(0x8010), 'param.auto');
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(0x8050), 'U1');
  });

  test('display:白平衡/色温/闪光尼康方言表', () {
    expect(_param(PtpDevicePropCode.whiteBalance).display(2), 'param.auto');
    expect(_param(PtpDevicePropCode.whiteBalance).display(6), 'param.incandescent');
    expect(_param(PtpDevicePropCode.whiteBalance).display(0x8010), 'param.cloudy');
    expect(_param(PtpDevicePropCode.whiteBalance).display(0x8012), 'param.colorTemp');
    expect(_param(PtpDevicePropCode.wbColorTemp).display(5500), '5500K');
    expect(_param(PtpDevicePropCode.flashMode).display(2), 'common.off');
    expect(_param(PtpDevicePropCode.flashMode).display(0x8010), 'param.fillFlash');
    expect(_param(PtpDevicePropCode.flashMode).display(0x8012), 'param.rearCurtain');
  });

  test('display:释放模式全表(单张/连拍档/自拍/C 高速档)', () {
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(1), 'param.single');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(2), 'param.burstHigh');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(0x8010), 'param.burstLow');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(0x8011), 'remote.selfTimer');
    expect(_param(PtpDevicePropCode.stillCaptureMode).display(0x811E), 'param.burstC30');
  });

  test('display:画质 14 值表 + RAW 压缩 + 图像区域', () {
    expect(_param(PtpDevicePropCode.compressionSetting).display(0), 'param.jpegBasic');
    expect(_param(PtpDevicePropCode.compressionSetting).display(5), 'param.jpegFineStar');
    expect(_param(PtpDevicePropCode.compressionSetting).display(7), 'RAW');
    expect(_param(PtpDevicePropCode.compressionSetting).display(12), 'param.rawJpegFine');
    expect(_param(PtpDevicePropCode.rawCompressionType).display(0), 'param.lossless');
    expect(_param(PtpDevicePropCode.rawCompressionType).display(4), 'param.he');
    expect(_param(PtpDevicePropCode.captureAreaCrop).display(0), 'FX');
    expect(_param(PtpDevicePropCode.captureAreaCrop).display(2), 'DX');
    expect(_param(PtpDevicePropCode.captureAreaCrop).display(5), '16:9');
  });

  test('display:优化校准内置组 + 段位格式化(创意/自定义/云)', () {
    final p = _param(PtpDevicePropCode.activePicCtrlItem);
    expect(p.pickValues, isNull,
        reason: '取值域走相机 FORM(真机 46 项;静态 11 项直供曾把 desc '
            '读短路砍掉值域,2026-10-07 用户反馈根因)');
    expect(p.display(1), 'param.standard');
    expect(p.display(4), 'param.monochrome');
    expect(p.display(103), 'Pop');
    expect(p.display(202), '自定义 2');
    expect(p.display(305), '云 5');
  });

  test('display:数值格式化(光圈/快门打包分数/ISO/EV)', () {
    expect(_param(PtpDevicePropCode.fNumber).display(280), 'f/2.8');
    // 快门值 = 0xD100 打包分数(num<<16|den)
    expect(_param(PtpDevicePropCode.exposureTime).display(1 << 16 | 100),
        '1/100s');
    expect(_param(PtpDevicePropCode.exposureTime).display(4 << 16 | 1), '4s');
    expect(_param(PtpDevicePropCode.exposureTime).display(13 << 16 | 10),
        '13/10s');
    expect(_param(PtpDevicePropCode.exposureTime).display(0xFFFFFFFF), 'param.bulb');
    expect(_param(PtpDevicePropCode.exposureTime).display(0xFFFFFFFE), 'param.xSync');
    expect(_param(PtpDevicePropCode.exposureTime).display(0xFFFFFFFD), 'param.time');
    // ISO 裸数值(2026-10-08 竖屏内联读出行起,值不再内嵌前缀)
    expect(_param(PtpDevicePropCode.exposureIndex).display(200), '200');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(300), '+0.3');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(-700),
        '-0.7');
    expect(
        _param(PtpDevicePropCode.exposureBiasCompensation).display(0), '0.0');
  });

  test('display:表外值裸显(语言中性)+ 未读占位', () {
    expect(_param(PtpDevicePropCode.exposureMeteringMode).display(7), '7',
        reason: '测光表外值(2/3/4/0x8010 在表),兜底裸值与 ISO 同口径');
    expect(_param(PtpDevicePropCode.whiteBalance).display(3), '3'); // 表外枚举
    expect(_param(PtpDevicePropCode.exposureProgramMode).display(null), '--');
    expect(kShootingParams.any((p) => p.code == PtpDevicePropCode.imageSize),
        isFalse,
        reason: '图像尺寸(0x5003 STR 型)已移出目录');
  });

  test('读写路径路由:ISO/快门读写全走厂商码,模式由转盘拥有只读', () {
    // Z 系真机口径(OpenZCine):静照 ISO/快门的标准码只读且不跟厂商写
    // —— 写走 0xD0B4/0xD100,值读走 0xD0B5/0xD100。
    final iso = _param(PtpDevicePropCode.exposureIndex);
    expect(iso.readCode, PtpDevicePropCode.isoControlSensitivity);
    expect(iso.writeCode, PtpDevicePropCode.exposureIndexEx);
    expect(iso.writeType, PtpDataType.uint32);
    expect(iso.writeConvert, isNull, reason: 'ISO 裸数直写');
    final shutter = _param(PtpDevicePropCode.exposureTime);
    expect(shutter.readCode, PtpDevicePropCode.stillShutterSpeed);
    expect(shutter.writeCode, PtpDevicePropCode.stillShutterSpeed);
    expect(shutter.writeType, PtpDataType.uint32);
    expect(shutter.writeConvert, isNull, reason: '面板值已是打包分数');
    expect(shutter.dialOwned, isTrue, reason: '机顶快门拨盘拥有 → 接管后才可调');
    expect(_param(PtpDevicePropCode.exposureIndex).dialOwned, isTrue,
        reason: 'ISO 按键+指令拨盘调整(2026-10-06 真机 0x200F)→ 接管后才可调');
    expect(_param(PtpDevicePropCode.fNumber).dialOwned, isTrue,
        reason: '光圈为指令拨盘参数(A/M 主拨盘)→ 接管后才可调');
    // 其余参数无路由(读码 = 写码 = 展示码)
    for (final code in [
      PtpDevicePropCode.fNumber,
      PtpDevicePropCode.whiteBalance,
      PtpDevicePropCode.stillCaptureMode,
      PtpDevicePropCode.compressionSetting,
      PtpDevicePropCode.rawCompressionType,
      PtpDevicePropCode.activePicCtrlItem,
    ]) {
      expect(_param(code).writeCode, isNull, reason: '0x$code 无需路由');
      expect(_param(code).readCode, isNull);
    }
    // 模式:机顶转盘物理拥有 → dialOwned(接管后可写,OpenZCine 同款
    // 0x500E u16 标准写路径);对焦只留 0xD061 单一芯片(0x500A 只读
    // 镜像已移出,避免「对焦/对焦模式」双芯片)。
    expect(_param(PtpDevicePropCode.exposureProgramMode).readOnly, isFalse);
    expect(_param(PtpDevicePropCode.exposureProgramMode).dialOwned, isTrue);
    expect(kShootingParams.any((p) => p.code == PtpDevicePropCode.focusMode),
        isFalse,
        reason: '0x500A 只读镜像移出目录');
    expect(_param(PtpDevicePropCode.exposureMeteringMode).display(3), 'param.matrix',
        reason: '尼康方言:3=矩阵(ISO 标准表 3=点是错的)');
    expect(_param(PtpDevicePropCode.fNumber).readOnly, isFalse);
  });

  test('AF 区域:Zf FORM 七值标签(2026-10-07 USB 形状实证)+ 取值域走相机', () {
    final p = _param(PtpDevicePropCode.stillFocusMeteringMode);
    expect(p.pickValues, isNull,
        reason: 'Zf 与 OpenZCine 两套人马,直供表会覆盖真机 FORM');
    expect(p.display(0x8010), 'param.singlePoint');
    expect(p.display(0x8011), 'param.auto');
    expect(p.display(0x8017), 'param.pinpoint');
    expect(p.display(0x8018), 'param.wideS');
    expect(p.display(0x8019), 'param.wideL');
    expect(p.display(0x801E), 'param.wideC1');
    expect(p.display(0x801F), 'param.wideC2');
  });

  test('AF 区域宽C1/C2 触屏定位提示:饱和轴单轴生效,其余值无提示', () {
    expect(afAreaAxisHint(0x801E), 'param.wideC1Hint');
    expect(afAreaAxisHint(0x801F), 'param.wideC2Hint');
    expect(afAreaAxisHint(0x8010), isNull, reason: '单点/自动/精确/宽S/L 双轴可移');
    expect(afAreaAxisHint(null), isNull);
  });

  test('快门取值域直供表:标准档打包值 + Bulb 哨兵(X 同步/Time 仍拨盘位)', () {
    final pick = _param(PtpDevicePropCode.exposureTime).pickValues!;
    expect(pick.first, 1 << 16 | 8000, reason: '1/8000s 打包');
    expect(pick, containsAll(<int>[1 << 16 | 100, 13 << 16 | 10, 30 << 16 | 1]));
    expect(pick.last, 0xFFFFFFFF, reason: 'Bulb 收尾');
    expect(pick, isNot(contains(0xFFFFFFFD)),
        reason: 'T 门不入表(2026-10-17 真机定案:0xD100 写入合法但 0x9207 '
            '拍照路径官方规格明文拒绝,能选不能拍;机顶拨 T 读回仍显 param.time)');
    expect(pick, isNot(contains(0xFFFFFFFE)), reason: 'X 同步仍是机顶拨盘位');
    // 其余参数取值域仍走相机 PropDesc
    expect(_param(PtpDevicePropCode.exposureIndex).pickValues, isNull);
  });

  test('曝光三要素标记 prominent(大芯片行),其余进横滚行', () {
    expect(kShootingParams
        .where((p) => p.prominent)
        .map((p) => p.label), ['info.aperture', 'param.shutter', 'ISO']);
    expect(kShootingParams.where((p) => p.prominent), hasLength(3));
  });

  group('视频参数族(2026-10-12 官方指令书 §6.5.3/§6.5.12)', () {
    test('全部 videoOnly 且并入合并查找表;照片目录不含它们', () {
      expect(kVideoShootingParams, isNotEmpty);
      for (final p in kVideoShootingParams) {
        expect(p.videoOnly, isTrue, reason: '${p.label} 必须 videoOnly');
        expect(shootingParamByCode[p.code], same(p),
            reason: '${p.label} 要能被写路由/事件过滤找到');
      }
      for (final p in kShootingParams) {
        expect(p.videoOnly, isFalse, reason: '静照目录不设 videoOnly');
      }
      // 码空间不相交(合并表无覆盖)
      final codes = [
        ...kShootingParams.map((p) => p.code),
        ...kVideoShootingParams.map((p) => p.code)
      ];
      expect(codes.toSet().length, codes.length, reason: '静照/视频码不重叠');
    });

    test('官方逐字标签:视频WB 0x8015 同照片设置 / N-Log 只读 / TC HDMI 档', () {
      final wb = shootingParamByCode[PtpDevicePropCode.movieWhiteBalance]!;
      expect(wb.display(0x8015), 'param.sameAsPhotos');
      expect(wb.display(2), 'param.auto', reason: '复用静照 WB 值空间');

      final log = shootingParamByCode[PtpDevicePropCode.movieLogOutput]!;
      expect(log.readOnly, isTrue, reason: '§6.5.12.4 Get-only');
      expect(log.display(1), 'common.on');

      final tc = shootingParamByCode[PtpDevicePropCode.recordTimeCodes]!;
      expect(tc.display(2), 'param.onHdmi');

      final countUp = shootingParamByCode[PtpDevicePropCode.timeCodeCountUpMethod]!;
      expect(countUp.display(0), 'Rec Run');
      expect(countUp.display(1), 'Free Run');

      final vr = shootingParamByCode[PtpDevicePropCode.movieVibrationReduction]!;
      expect(vr.display(100), 'param.sameAsPhotos');

      final tone = shootingParamByCode[PtpDevicePropCode.movieH265ToneMode]!;
      expect(tone.display(1), 'N-Log');
      expect(tone.writeType, PtpDataType.uint8, reason: 'Ex 扩展码显式 u8');
    });

    test('曝光四件套格式化:光圈 ×100 / 快门打包分数 / EV 千分档', () {
      final f = shootingParamByCode[PtpDevicePropCode.movieFnumber]!;
      expect(f.display(200), 'f/2.0');
      final shut = shootingParamByCode[PtpDevicePropCode.movieShutterSpeed]!;
      expect(shut.display(1 << 16 | 250), '1/250s');
      final ev =
          shootingParamByCode[PtpDevicePropCode.movieExposureBiasCompensation]!;
      expect(ev.display(333), '+0.3');
      final iso = shootingParamByCode[PtpDevicePropCode.movieExposureIndex]!;
      expect(iso.display(100), '100');
    });

    test('orderedCaptureParams:照片档不含视频族,视频档追加在目录尾', () {
      final photo = orderedCaptureParams();
      expect(photo.any((p) => p.videoOnly), isFalse);
      final video = orderedCaptureParams(videoMode: true);
      expect(video.any((p) => p.videoOnly), isTrue);
      expect(video.length, photo.length + kVideoShootingParams.length);
      expect(video.last.code, PtpDevicePropCode.movieH265ToneMode,
          reason: '视频族按目录序追加在尾部');
    });
  });
}

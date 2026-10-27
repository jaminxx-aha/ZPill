/**
 * ZPill RAW/HEIF 解码通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/raw_decoder.dart(MethodChannel
 * `zpill/raw`,`decode({path, maxPixelSize})` → JPEG 字节):
 * - **HIF/HEIF**:@ohos.multimedia.image 的 ImageSource 解码 → 长边
 *   压档(desiredSize 按比缩放,不变形)→ ImagePacker 打包 JPEG(0.85)
 *   回传;
 * - **JPG/JPEG**:同一管线;EXIF 方向原生转正(对齐 iOS ImageIO
 *   kCGImageSourceCreateThumbnailWithTransform 语义,产物 = 已转正裸
 *   JPEG,引擎直显不再旋)。kit 是否代转 EXIF 不可假设 —— 换挡类
 *   (6/8)以解码宽高对照存储宽高自证(与 HIF irot 的纵横比判定同
 *   手法),未转补 rotate;180°(orientation 3)宽高不变无法自证,按
 *   kit 已转处理,真机探针定案后收口;镜像类(2/4/5/7)kit 无镜像
 *   变换,闸上直拒落原图源(宁缺毋歪,相机也不产)。图库 JPG 小档
 *   管线吃本通道(2026-10-26 快速下滑黑块根修,此前 ohos 上 JPG 恒走
 *   全幅原图解码,滚动供数跟不上)。
 * - **NEF/NRW**:**LibRaw 真解码**(rawdecoder.so,LibRaw 0.22.3 静态
 *   编入,LICENSE.LGPL/CDDL)—— 全显影管线(相机白平衡/sRGB/8bit/
 *   自动亮度),halfSize superpixel 半尺寸免 demosaic 提速(长边减半
 *   仍罩 2560 观看档),RGBA → createPixelMap → 长边压档(scale)→
 *   ImagePacker 同出口。方向由 LibRaw flip 语义自理(随 EXIF Orientation
 *   转正),与 iOS ImageIO 同为真解码直出,网格缩略/查看器大图共用
 *   (nef_thumb.dart 内嵌 160×120 兜底仅作 LibRaw 失败时的最后回落)。
 *
 * 其余扩展名一律 FlutterError:PNG/GIF/WebP 等真引擎可解格式留在引擎
 * 原图源 —— 方向引擎自理(小档管线的 JPG 已上收,见上)。iOS 侧
 * RawDecodePlugin.swift 无门槛全接,平台差集见各自文件头。
 *
 * 字节陷阱(同 VideoPlugin):ImagePacker.packToData 回 ArrayBuffer,
 * MethodChannel 序列化不认 ArrayBuffer(落 object 分支序列化成空
 * map),必须 new Uint8Array 包一层再 success —— Dart 侧才能收成
 * Uint8List(iOS FlutterStandardTypedData 同款教训)。
 *
 * 通道调用在平台线程,解码重活全异步(await 链),result 回调在完成
 * 时交付(与 iOS 后台队列 + 主线程回投同语义)。LibRaw 解码进一步
 * 落在 napi 异步工作线程(见 cpp/napi_init.cpp),JS 线程零阻塞。
 */
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import rawdecoder from 'librawdecoder.so';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  Log,
} from '@ohos/flutter_ohos';
import { NativeLog } from '../log/NativeLog';

const TAG = 'RawDecodePlugin';
const CHANNEL = 'zpill/raw';

/** 头读窗口:HEIF meta 链在 mdat 之前(Zf HIF 实测 ~1.8KB),64KB 罩住。 */
const HEAD_BYTES = 65536;

/** napi 返回人设(cpp/napi_init.cpp 的 decodeToRgba 契约)。 */
interface RawRgbaResult {
  width: number;
  height: number;
  ms: string;
  data: Uint8Array;
}

/** rawdecoder.so 人设(静态 .so 导入无类型,显式收口防 any 漫溢)。 */
interface RawDecoderNapi {
  decodeToRgba(path: string, halfSize: boolean): Promise<RawRgbaResult>;
}

const rawdecoderNapi = rawdecoder as RawDecoderNapi;

/** decodeRaw 出产:JPEG 字节 + napi 侧分段耗时(调观测用)。 */
interface RawJpeg {
  jpeg: Uint8Array;
  ms: string;
}

/** `zpill/raw` 通道实现(ohos:HIF/HEIF/JPG 长边压档出 JPEG)。 */
export class RawDecodePlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'RawDecodePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'decode') {
      result.notImplemented();
      return;
    }
    const path = call.argument('path') as string | null;
    const maxPixelSize = (call.argument('maxPixelSize') as number) ?? 512;
    if (path === null || path === undefined || path.length === 0) {
      result.error('bad_args', 'decode 须传 path', null);
      return;
    }
    const lower = path.toLowerCase();
    if (lower.endsWith('.nef') || lower.endsWith('.nrw')) {
      const started = Date.now();
      this.decodeRaw(path, maxPixelSize).then((r) => {
        Log.w(TAG, `NEF 真解码 ${maxPixelSize}px 总 ${Date.now() - started}ms [${r.ms}] ${r.jpeg.length}B`);
        result.success(r.jpeg);
      }).catch((err: Object) => {
        Log.w(TAG, `NEF decode 异常:${JSON.stringify(err)}`);
        result.error('decode_failed', `NEF 解码失败:${JSON.stringify(err)}`, null);
      });
      return;
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      // JPG 小档(图库缩略管线吃):镜像类方向直拒落原图源(kit 无
      // 镜像变换,宁缺毋歪;相机也不产 2/4/5/7)。方向值随解码带入,
      // decode 内做换挡类自证补转。
      const ori = RawDecodePlugin.readJpegOrientation(path);
      if (ori === 2 || ori === 4 || ori === 5 || ori === 7) {
        result.error('unsupported_format', `JPG 镜像方向不产小档:${path}`, null);
        return;
      }
      this.decode(path, maxPixelSize, ori).then((bytes) => {
        result.success(bytes);
      }).catch((err: Object) => {
        Log.w(TAG, `JPG decode 异常:${JSON.stringify(err)}`);
        result.error('decode_failed', `JPG 解码失败:${JSON.stringify(err)}`, null);
      });
      return;
    }
    if (!lower.endsWith('.hif') && !lower.endsWith('.heif')) {
      // PNG/GIF/WebP 等真引擎可解件留引擎原图源(见文件头)。
      result.error('unsupported_format',
        `ohos 解码只接 HIF/HEIF/JPG/JPEG/NEF/NRW:${path}`, null);
      return;
    }
    this.decode(path, maxPixelSize, 0).then((bytes) => {
      result.success(bytes);
    }).catch((err: Object) => {
      Log.w(TAG, `decode 异常:${JSON.stringify(err)}`);
      result.error('decode_failed', `HIF 解码失败:${JSON.stringify(err)}`, null);
    });
  }

  /** NEF/NRW:LibRaw 真解码(halfSize superpixel)→ RGBA → PixelMap
   *  → 长边压档(scale 保比)→ JPEG 0.85。方向随 LibRaw flip 转正。 */
  private async decodeRaw(path: string, maxPixelSize: number):
    Promise<RawJpeg> {
    let packer: image.ImagePacker | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      const out = await rawdecoderNapi.decodeToRgba(path, true);
      // 同步形建面(24MB 拷贝 ~10ms,异步形重载与回调形归并出
      // void&Promise 歧义,ArkTS 严模式拒收);srcPixelFormat = 源即
      // RGBA8888(napi 侧产出),PixelMap 本体按默认格式持有。
      pixelMap = image.createPixelMapSync(out.data.buffer as ArrayBuffer, {
        size: { width: out.width, height: out.height },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      const long = Math.max(out.width, out.height);
      if (long > maxPixelSize && long > 0) {
        const ratio = maxPixelSize / long;
        try {
          await pixelMap.scale(ratio, ratio);
        } catch (err) {
          Log.w(TAG, `scale 失败,用原尺寸:${JSON.stringify(err)}`);
        }
      }
      packer = image.createImagePacker();
      const buf = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 85,
      });
      return { jpeg: new Uint8Array(buf), ms: out.ms };
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
    }
  }

  /** 解码:长边压档(desiredSize 保比)→ JPEG 0.85 → Uint8Array。
   *  [jpegOrientation] = JPG EXIF Orientation(非 JPG 传 0):换挡类
   *  6/8 走解码宽高自证补转(见下),其余值按 kit 已转处理。 */
  private async decode(path: string, maxPixelSize: number,
    jpegOrientation: number): Promise<Uint8Array> {
    let source: image.ImageSource | null = null;
    let packer: image.ImagePacker | null = null;
    let pixelMap: image.PixelMap | null = null;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const long = Math.max(info.size.width, info.size.height);
      const opts: image.DecodingOptions = {};
      if (long > maxPixelSize && long > 0) {
        const ratio = maxPixelSize / long;
        opts.desiredSize = {
          width: Math.round(info.size.width * ratio),
          height: Math.round(info.size.height * ratio),
        };
      }
      pixelMap = await source.createPixelMap(opts);
      if (jpegOrientation === 6 || jpegOrientation === 8) {
        // JPG EXIF 方向转正(对齐 iOS ImageIO WithTransform 语义)。kit
        // 是否代转 EXIF 不可假设 —— 沿 HIF irot 的纵横比自证手法:换挡
        // 类(6/8)以解码宽高对照存储宽高(奇数角旋转宽高互换:已换 =
        // kit 已转,不再补;未换 = 补转,PixelMap.rotate 正向顺时针
        // 6→90、8→270)。存储方形不可判,按 kit 已转处理(相机传感
        // 3:2/4:3 不产方图);180°(orientation 3)宽高不变同样无法
        // 自证,同按 kit 已转处理,真机探针定案后收口;镜像类在闸上
        // 已拒(宁缺毋歪)。desiredSize 压档不改纵横比,比值对照成立。
        const dec = await pixelMap.getImageInfo();
        const square = info.size.width === info.size.height;
        const kitSwapped = (info.size.width > info.size.height) !==
          (dec.size.width > dec.size.height);
        if (!square && !kitSwapped) {
          try {
            await pixelMap.rotate(jpegOrientation === 6 ? 90 : 270);
          } catch (err) {
            Log.w(TAG, `JPG rotate 失败,按未转处理:${JSON.stringify(err)}`);
          }
        }
      }
      const lower = path.toLowerCase();
      if (lower.endsWith('.hif') || lower.endsWith('.heif')) {
        // HEIF irot 补转:主图展示旋转写在 ipco 的 irot 盒、经 ipma 绑
        // 主图( exhibiting = 存储图**逆时针**转 angle*90,ISO 23008-12
        // §6.5.4;Apple ImageIO 样张实锤 Orientation 6=CW90→angle 3、
        // 8=CCW90→1)。image kit 是否代转不可假设 —— 以解码纵横比对照
        // ispe 判定(奇数角旋转宽高互换):已转不再补,未转补转,
        // PixelMap.rotate 正向顺时针故取 (360-ccw)%360。头读另开一只
        // fd —— 主 fd 已交给 ImageSource,不能挪它的读写位。
        const t = RawDecodePlugin.readPrimaryTransform(path);
        const oddTurn = (t.degreesCcw / 90) % 2 === 1;
        if (t.degreesCcw !== 0) {
          const outLandscape = info.size.width > info.size.height;
          const ispeLandscape = t.ispeW > t.ispeH;
          const kitApplied = oddTurn && (outLandscape !== ispeLandscape);
          if (!kitApplied) {
            try {
              await pixelMap.rotate((360 - t.degreesCcw) % 360);
            } catch (err) {
              Log.w(TAG, `rotate 失败,按未转处理:${JSON.stringify(err)}`);
            }
          }
        }
      }
      packer = image.createImagePacker();
      const buf = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 85,
      });
      return new Uint8Array(buf);
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (source !== null) {
        try {
          await source.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (_) {
          // 释放尽力而为
        }
      }
    }
  }

  /** 头读 + 主图变换解析(另开 fd,失败按零值不转)。 */
  private static readPrimaryTransform(path: string): PrimaryTransform {
    let headFile: fs.File | null = null;
    try {
      headFile = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const headBuf = new ArrayBuffer(HEAD_BYTES);
      const headRead = fs.readSync(headFile.fd, headBuf, {
        offset: 0,
        length: HEAD_BYTES,
      });
      return RawDecodePlugin.primaryTransform(
        new Uint8Array(headBuf, 0, headRead),
      );
    } catch (err) {
      Log.w(TAG, `irot 头读失败,按未转处理:${JSON.stringify(err)}`);
      return { degreesCcw: 0, ispeW: 0, ispeH: 0 };
    } finally {
      if (headFile !== null) {
        try {
          fs.closeSync(headFile);
        } catch (_) {
          // 释放尽力而为
        }
      }
    }
  }

  /** HEIF 主图(pitm)的 irot 角(度,**逆时针**展示语义;无 irot/
   *  解析失败 0)与 ispe 存储宽高(0 值 = 未知)。irot 必须经 ipma
   *  确认绑在主图上(缩略/预览项可各带各的变换,勿按「首个 irot」
   *  误转)。irot 双形态:标准 FullBox 13B(payload bits 5-4)与
   *  紧凑形 9B(payload 平面小值 —— Apple ImageIO 与 Nikon 同用,
   *  2026-10-24 ImageIO 样张实锤 Orientation 6→0x3、8→0x1、1→0x0)。
   */
  static primaryTransform(head: Uint8Array): PrimaryTransform {
    const u32 = (p: number): number =>
      ((head[p] << 24) | (head[p + 1] << 16) | (head[p + 2] << 8) | head[p + 3]) >>> 0;
    const u16 = (p: number): number => ((head[p] << 8) | head[p + 1]);
    const type = (p: number): string =>
      String.fromCharCode(head[p], head[p + 1], head[p + 2], head[p + 3]);

    let primaryId = 0;
    const propAngle = new Map<number, number>(); // ipco 1 基序号 → 逆时针度
    const propIspe = new Map<number, number[]>(); // ipco 序号 → [w, h]
    let out: PrimaryTransform = { degreesCcw: 0, ispeW: 0, ispeH: 0 };

    let pos = 0;
    while (pos + 8 <= head.length) {
      const size = u32(pos);
      if (size < 8 || pos + size > head.length) {
        break;
      }
      if (type(pos + 4) !== 'meta') {
        pos += size;
        continue;
      }
      // meta 是 FullBox:子盒从 +12 起(跳 version/flags)。
      const metaEnd = pos + size;
      let q = pos + 12;
      while (q + 8 <= metaEnd) {
        const qSize = u32(q);
        if (qSize < 8 || q + qSize > metaEnd) {
          break;
        }
        const qType = type(q + 4);
        if (qType === 'pitm' && qSize >= 14 && head[q + 8] === 0) {
          primaryId = u16(q + 12);
        } else if (qType === 'iprp' && qSize >= 8) {
          let r = q + 8;
          let ipma = -1;
          const iprpEnd = q + qSize;
          while (r + 8 <= iprpEnd) {
            const rSize = u32(r);
            if (rSize < 8 || r + rSize > iprpEnd) {
              break;
            }
            const rType = type(r + 4);
            if (rType === 'ipco') {
              let s = r + 8;
              let index = 1; // ipma 属性序号 1 基
              const ipcoEnd = r + rSize;
              while (s + 8 <= ipcoEnd) {
                const sSize = u32(s);
                if (sSize < 8 || s + sSize > ipcoEnd) {
                  break;
                }
                if (type(s + 4) === 'irot') {
                  const payload = sSize >= 13 ? head[s + 12] : head[s + 8];
                  propAngle.set(index, (sSize >= 13
                    ? (payload >> 4) & 0x3
                    : payload & 0x3) * 90);
                } else if (type(s + 4) === 'ispe' && sSize >= 20) {
                  propIspe.set(index, [u32(s + 12), u32(s + 16)]);
                }
                s += sSize;
                index++;
              }
            } else if (rType === 'ipma') {
              ipma = r;
            }
            r += rSize;
          }
          if (ipma >= 0) {
            out = RawDecodePlugin.transformFromIpma(
              head, ipma, primaryId, propAngle, propIspe);
          }
        }
        q += qSize;
      }
      break; // meta 只走一个
    }
    return out;
  }

  /** ipma 里主图关联的首个 irot 角与其 ispe;无关联/截断/解析失败回零值。 */
  private static transformFromIpma(head: Uint8Array, at: number,
    primaryId: number, propAngle: Map<number, number>,
    propIspe: Map<number, number[]>): PrimaryTransform {
    const u32 = (p: number): number =>
      ((head[p] << 24) | (head[p + 1] << 16) | (head[p + 2] << 8) | head[p + 3]) >>> 0;
    const u16 = (p: number): number => ((head[p] << 8) | head[p + 1]);
    const wideItem = head[at + 8] >= 1; // version ≥ 1:item_id 32 位
    const wideIndex = (u32(at + 8) & 0x1) !== 0; // flags bit0:索引 15 位
    const result: PrimaryTransform = { degreesCcw: 0, ispeW: 0, ispeH: 0 };
    let p = at + 12;
    if (p + 4 > head.length) {
      return result;
    }
    let count = u32(p);
    p += 4;
    while (count-- > 0) {
      if (p + (wideItem ? 4 : 2) + 1 > head.length) {
        break;
      }
      const itemId = wideItem ? u32(p) : u16(p);
      p += wideItem ? 4 : 2;
      const assocCount = head[p];
      p += 1;
      const primaryHit = itemId === primaryId;
      for (let i = 0; i < assocCount; i++) {
        if (p + (wideIndex ? 2 : 1) > head.length) {
          return result;
        }
        const raw = wideIndex ? u16(p) : head[p];
        p += wideIndex ? 2 : 1;
        if (!primaryHit) {
          continue;
        }
        // essential 位去尾:2 字节形 = 15 位索引(bit15),1 字节形 =
        // 7 位索引(bit7)—— 0x81 必须剥成 1,勿按 15 位掩码照搬。
        const index = wideIndex ? (raw & 0x7FFF) : (raw & 0x7F);
        if (result.degreesCcw === 0 && propAngle.has(index)) {
          result.degreesCcw = propAngle.get(index)!;
        }
        if (result.ispeW === 0 && propIspe.has(index)) {
          const wh = propIspe.get(index)!;
          result.ispeW = wh[0];
          result.ispeH = wh[1];
        }
      }
    }
    return result;
  }

  /** JPEG 头读 + EXIF Orientation 解析(另开 fd,失败回 0 按未转处理)。 */
  static readJpegOrientation(path: string): number {
    let headFile: fs.File | null = null;
    try {
      headFile = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const headBuf = new ArrayBuffer(HEAD_BYTES);
      const headRead = fs.readSync(headFile.fd, headBuf, {
        offset: 0,
        length: HEAD_BYTES,
      });
      return RawDecodePlugin.jpegOrientationOf(
        new Uint8Array(headBuf, 0, headRead));
    } catch (err) {
      Log.w(TAG, `EXIF 头读失败,按未转处理:${JSON.stringify(err)}`);
      return 0;
    } finally {
      if (headFile !== null) {
        try {
          fs.closeSync(headFile);
        } catch (_) {
          // 释放尽力而为
        }
      }
    }
  }

  /** 头字节 → EXIF Orientation(1-8;无段/无标签/非 JPEG 回 0)。
   *  语义同 Dart 侧 core/media/jpeg_orientation.dart(移植底稿):
   *  SOI 后段扫至 SOS,APP1(Exif\0\0)内 TIFF IFD0 条目表取 0x0112。
   *  Exif 段截断容忍(方向条目表在段内前 ~400B;Zf JPG 的 APP1 声明
   *  65534B,头读盖不住整段)。 */
  static jpegOrientationOf(head: Uint8Array): number {
    if (head.length < 4 || head[0] !== 0xFF || head[1] !== 0xD8) {
      return 0;
    }
    let off = 2;
    while (off + 4 <= head.length) {
      if (head[off] !== 0xFF) {
        return 0; // 段失步:不是可解的 JPEG 头
      }
      const marker = head[off + 1];
      if (marker === 0xD8 || marker === 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
        off += 2; // 独立标记,无长度
        continue;
      }
      if (marker === 0xDA) {
        return 0; // SOS:EXIF 必在其前
      }
      const segLen = (head[off + 2] << 8) | head[off + 3];
      if (segLen < 2) {
        return 0;
      }
      const isExifApp1 = marker === 0xE1 &&
        head.length >= off + 10 && segLen >= 8 &&
        head[off + 4] === 0x45 && head[off + 5] === 0x78 &&
        head[off + 6] === 0x69 && head[off + 7] === 0x66 &&
        head[off + 8] === 0x00 && head[off + 9] === 0x00;
      const segEnd = off + 2 + segLen;
      if (segEnd > head.length && !isExifApp1) {
        return 0; // 截断的非 Exif 段:后面(即便有数据)读不出段界
      }
      if (isExifApp1) {
        // TIFF 从段载荷 +6 起(跳 Exif\0\0);段尾截断夹到可用字节。
        return RawDecodePlugin.ifd0Orientation(head, off + 10,
          segEnd > head.length ? head.length : segEnd);
      }
      off += 2 + segLen;
    }
    return 0;
  }

  /** TIFF(IFD0 相对偏移起于 tiffAt,数据止于 end)条目表 Orientation;
   *  结构不符回 0。II/MM 双端序,条目 = 0x0112 SHORT×1(值内联)。 */
  static ifd0Orientation(head: Uint8Array, tiffAt: number,
    end: number): number {
    if (tiffAt + 8 > end) {
      return 0;
    }
    const little = head[tiffAt] === 0x49;
    if ((little ? head[tiffAt] : head[tiffAt + 1]) !==
      (little ? 0x49 : 0x4D)) {
      return 0;
    }
    const u16 = (p: number): number => little
      ? head[p] | (head[p + 1] << 8)
      : ((head[p] << 8) | head[p + 1]);
    const u32 = (p: number): number => little
      ? (head[p] | (head[p + 1] << 8) | (head[p + 2] << 16) |
        (head[p + 3] << 24)) >>> 0
      : ((head[p] << 24) | (head[p + 1] << 16) | (head[p + 2] << 8) |
        head[p + 3]) >>> 0;
    const ifd0 = u32(tiffAt + 4);
    if (ifd0 < 8 || tiffAt + ifd0 + 2 > end) {
      return 0;
    }
    const count = u16(tiffAt + ifd0);
    for (let i = 0; i < count; i++) {
      const e = tiffAt + ifd0 + 2 + i * 12;
      if (e + 12 > end) {
        break;
      }
      if (u16(e) === 0x0112 && u16(e + 2) === 3 && u32(e + 4) === 1) {
        return u16(e + 8); // 值内联(SHORT×1 ≤ 4B)
      }
    }
    return 0;
  }
}

/** 主图变换信息:degreesCcw = irot 展示旋转(逆时针,度);ispe =
 *  存储宽高(0 值 = 头里没解出)。 */
interface PrimaryTransform {
  degreesCcw: number;
  ispeW: number;
  ispeH: number;
}

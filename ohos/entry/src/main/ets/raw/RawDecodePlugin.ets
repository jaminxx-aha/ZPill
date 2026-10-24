/**
 * NikonPill RAW/HEIF 解码通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/raw_decoder.dart(MethodChannel
 * `nikonpill/raw`,`decode({path, maxPixelSize})` → JPEG 字节):
 * @ohos.multimedia.image 的 ImageSource 解码 → 长边压档(desiredSize
 * 按比缩放,不变形)→ ImagePacker 打包 JPEG(0.85)回传。
 *
 * **只接 HIF/HEIF**(扩展名闸,其余一律 FlutterError):ohos image
 * kit 无 RAW 解码(NEF 网格缩略由 Dart 侧内嵌缩略提取兜底,
 * core/media/nef_thumb.dart);JPG/PNG 等引擎可解格式也留在引擎原图
 * 源 —— 方向引擎自理,避免 image kit 的 EXIF 方向语义与引擎解码不一致
 * 造成二次旋转。iOS 侧 RawDecodePlugin.swift 无门槛全接,平台差集见
 * 各自文件头。
 *
 * 字节陷阱(同 VideoPlugin):ImagePacker.packToData 回 ArrayBuffer,
 * MethodChannel 序列化不认 ArrayBuffer(落 object 分支序列化成空
 * map),必须 new Uint8Array 包一层再 success —— Dart 侧才能收成
 * Uint8List(iOS FlutterStandardTypedData 同款教训)。
 *
 * 通道调用在平台线程,解码重活全异步(await 链),result 回调在完成
 * 时交付(与 iOS 后台队列 + 主线程回投同语义)。
 */
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
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
const CHANNEL = 'nikonpill/raw';

/** 头读窗口:HEIF meta 链在 mdat 之前(Zf HIF 实测 ~1.8KB),64KB 罩住。 */
const HEAD_BYTES = 65536;

/** `nikonpill/raw` 通道实现(ohos:仅 HIF/HEIF,长边压档出 JPEG)。 */
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
    if (!lower.endsWith('.hif') && !lower.endsWith('.heif')) {
      // NEF 等交 Dart 侧内嵌缩略兜底;JPG 等留引擎原图源(见文件头)。
      result.error('unsupported_format', `ohos 解码只接 HIF/HEIF:${path}`, null);
      return;
    }
    this.decode(path, maxPixelSize).then((bytes) => {
      result.success(bytes);
    }).catch((err: Object) => {
      Log.w(TAG, `decode 异常:${JSON.stringify(err)}`);
      result.error('decode_failed', `HIF 解码失败:${JSON.stringify(err)}`, null);
    });
  }

  /** 解码:长边压档(desiredSize 保比)→ JPEG 0.85 → Uint8Array。 */
  private async decode(path: string, maxPixelSize: number):
    Promise<Uint8Array> {
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
}

/** 主图变换信息:degreesCcw = irot 展示旋转(逆时针,度);ispe =
 *  存储宽高(0 值 = 头里没解出)。 */
interface PrimaryTransform {
  degreesCcw: number;
  ispeW: number;
  ispeH: number;
}

/**
 * 「保存到图库」会话(SaveButton 安全控件路径)。
 *
 * 背景:showAssetsCreationDialog 在本机(HarmonyOS 6)因系统对话框进程
 * 冷启动而 SetUIContent 超时,SDK 抛 14000011,且事后零落库 —— 该路径
 * 整体弃用(真机 4/4 复现)。替代:三方应用免 ACL 写媒体库的官方姿势
 * 是 SaveButton 安全控件 —— 用户点击后应用获得 ~10s 临时授权,窗口期内
 * createAsset 占位 + 拷入字节,全程无跨进程 UI。
 *
 * 流程:GalleryPlugin.importFiles 只登记请求并亮面板(Index.ets 内的
 * SaveSheet 覆盖层);用户点 SaveButton → performSave() 在授权窗口内
 * 逐个 createAsset + 拷贝;结果(授权 URI 列表/空=取消)经回调一次性
 * 交回 importFiles 的 MethodResult。
 *
 * 模块级单例:插件与 UI 同进程同模块实例,不经过 AppStorage/LocalStorage
 * (FlutterAbility 用私有 LocalStorage 加载 Index,共享存储不可达)。
 */
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import { Log } from '@ohos/flutter_ohos';

const TAG = 'SaveSession';

/** 单个待保存文件(Dart importFiles 入参项)。 */
export interface SaveRequest {
  path: string;
  kind: string;
  filename: string;
}

/** 保存结果回调:授权 URI 列表(与请求等长);空列表 = 用户取消。 */
export type SaveFinish = (uris: Array<string>) => void;

/** 面板可见性监听(Index.ets 注册;注册时回放当前态以便页面重建后恢复)。 */
export type SaveVisibilityListener = (visible: boolean) => void;

export class SaveSession {
  private static requests: Array<SaveRequest> = [];
  private static finishCallback: SaveFinish | null = null;
  private static visibilityListener: SaveVisibilityListener | null = null;
  private static performing = false;

  static isActive(): boolean {
    return SaveSession.finishCallback !== null;
  }

  static count(): number {
    return SaveSession.requests.length;
  }

  static setVisibilityListener(listener: SaveVisibilityListener | null): void {
    SaveSession.visibilityListener = listener;
    if (listener !== null) {
      listener(SaveSession.isActive());
    }
  }

  /**
   * 登记一批保存请求并亮出保存面板。
   * @returns false = UI 未挂载(Index 尚未注册监听),调用方应直接报错。
   */
  static open(requests: Array<SaveRequest>, finish: SaveFinish): boolean {
    if (SaveSession.visibilityListener === null) {
      return false;
    }
    SaveSession.requests = requests;
    SaveSession.finishCallback = finish;
    const l = SaveSession.visibilityListener;
    if (l !== null) {
      l(true);
    }
    return true;
  }

  /** 用户取消(遮罩/取消按钮/返回键);保存进行中则忽略(防半途删源)。 */
  static cancel(): void {
    if (SaveSession.performing) {
      return;
    }
    SaveSession.settle([]);
  }

  /** 保存完成:授权 URI 列表交回。 */
  static finish(uris: Array<string>): void {
    SaveSession.settle(uris);
  }

  private static settle(uris: Array<string>): void {
    const cb = SaveSession.finishCallback;
    if (cb === null) {
      return;
    }
    SaveSession.requests = [];
    SaveSession.finishCallback = null;
    const l = SaveSession.visibilityListener;
    if (l !== null) {
      l(false);
    }
    cb(uris);
  }

  /**
   * 在 SaveButton 临时授权窗口内执行:createAsset 占位 + 拷入字节。
   * 任一文件失败即抛错,面板留在原地可再次点击重试(每次点击授予新的
   * 授权窗口);已拷入的部分会成为媒体库孤立文件,重试会产生重复 ——
   * 以此换取全有或全无的简单语义。
   */
  static async performSave(
    context: common.Context,
    onProgress: (done: number, total: number) => void,
  ): Promise<Array<string>> {
    const reqs = SaveSession.requests;
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    const uris: Array<string> = [];
    SaveSession.performing = true;
    try {
      for (let i = 0; i < reqs.length; i++) {
        const r = reqs[i];
        const dot = r.filename.lastIndexOf('.');
        const ext = dot > 0 ? r.filename.substring(dot + 1) : '';
        const title = dot > 0 ? r.filename.substring(0, dot) : r.filename;
        const options: photoAccessHelper.CreateOptions = { title: title };
        const photoType = r.kind === 'video'
          ? photoAccessHelper.PhotoType.VIDEO
          : photoAccessHelper.PhotoType.IMAGE;
        const uri = await helper.createAsset(photoType, ext, options);
        const src = fs.openSync(r.path, fs.OpenMode.READ_ONLY);
        try {
          const dst = fs.openSync(uri, fs.OpenMode.READ_WRITE);
          try {
            fs.copyFileSync(src.fd, dst.fd);
          } finally {
            fs.closeSync(dst);
          }
        } finally {
          fs.closeSync(src);
        }
        uris.push(uri);
        onProgress(i + 1, reqs.length);
        Log.i(TAG, `performSave: ${i + 1}/${reqs.length} ${r.filename}`);
      }
      return uris;
    } finally {
      SaveSession.performing = false;
    }
  }
}

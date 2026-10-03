/**
 * 「保存到图库」面板(Index.ets 内的 ArkUI 覆盖层,盖在 FlutterPage 上)。
 *
 * 之所以是应用自己的面板而不是系统对话框:本机 showAssetsCreationDialog
 * 稳定超时(14000011)。SaveButton 是免权限安全控件,用户点击才有
 * ~10s 临时授权,点击回调里立刻做 createAsset + 拷贝(SaveSession.
 * performSave)。临时授权失败(TEMPORARY_AUTHORIZATION_FAILED)可原地点
 * 重试,每次点击都是新窗口。
 */
import common from '@ohos.app.ability.common';
import { SaveSession } from './SaveSession';

@Component
export struct SaveSheet {
  @State saving: boolean = false;
  @State done: number = 0;
  @State message: string = '';

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 半透明遮罩:点击即取消(保存进行中忽略)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => SaveSession.cancel())
      Column({ space: 12 }) {
        Text('保存到图库')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        Text(`共 ${SaveSession.count()} 个文件`)
          .fontSize(14)
          .fontColor('#88000000')
        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(13)
            .fontColor('#D8483F')
            .maxLines(2)
        }
        if (this.saving) {
          Row({ space: 8 }) {
            LoadingProgress().width(22).height(22)
            Text(`正在保存 ${this.done}/${SaveSession.count()}`)
              .fontSize(14)
          }
        } else {
          Row({ space: 12 }) {
            Button('取消')
              .onClick(() => SaveSession.cancel())
            SaveButton({
              icon: SaveIconStyle.FULL_FILLED,
              text: SaveDescription.SAVE_TO_GALLERY,
              buttonType: ButtonType.Capsule,
            })
              .onClick(async (event: ClickEvent, result: SaveButtonOnClickResult) => {
                if (result !== SaveButtonOnClickResult.SUCCESS) {
                  this.message = '未获得保存授权,请再点一次';
                  return;
                }
                this.saving = true;
                this.done = 0;
                this.message = '';
                try {
                  const ctx = getContext(this) as common.UIAbilityContext;
                  const uris = await SaveSession.performSave(
                    ctx, (d: number, _t: number) => {
                      this.done = d;
                    });
                  // settle 会撤面板;面板已卸载后再碰 @State 也无害
                  SaveSession.finish(uris);
                } catch (e) {
                  this.saving = false;
                  this.message = `保存失败:${e}`;
                }
              })
          }
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 40 })
      .borderRadius({ topLeft: 24, topRight: 24 })
      .backgroundColor(Color.White)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}

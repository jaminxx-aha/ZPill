
import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'
import { SaveSession } from '../gallery/SaveSession'
import { SaveSheet } from '../gallery/SaveSheet'

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";
  // 「保存到图库」面板(SaveButton 安全控件)可见性,由 SaveSession 驱动
  @State saveVisible: boolean = false;

  aboutToAppear() {
    SaveSession.setVisibilityListener((visible: boolean) => {
      this.saveVisible = visible;
    });
  }

  aboutToDisappear() {
    SaveSession.setVisibilityListener(null);
  }

  build() {
    Stack() {
      Column() {
        FlutterPage({ viewId: this.viewId })
      }
      if (this.saveVisible) {
        SaveSheet()
      }
    }
  }

  onBackPress(): boolean {
    // 保存面板模态期间:返回键先关面板(保存进行中忽略),不透传 Flutter
    if (this.saveVisible) {
      SaveSession.cancel();
      return true;
    }
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}

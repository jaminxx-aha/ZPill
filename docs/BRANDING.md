# 品牌配置

内部代码标识固定为 `z_pill` / `zpill`，默认发行品牌为 ZPill。品牌配置只控制
应用身份、显示名和图标，不改变 Dart 包名或平台通道。

## 默认身份

| 平台 | 应用身份 |
| --- | --- |
| Android | `com.jaminxx.zpill` |
| iOS | `com.jaminxx.zpill` |
| HarmonyOS | `com.jaminxx.z_pill` |

直接构建时使用仓库内的 [ZPill 配置](../branding/zpill/brand.yaml)：

```bash
dart run tool/apply_brand.dart
flutter build apk --release
```

应用 Flutter 层标题默认也是 `ZPill`。如需显式传入：

```bash
flutter build apk --release \
  --dart-define=APP_BRAND_ID=zpill \
  --dart-define=APP_BRAND_NAME=ZPill \
  --dart-define=APP_BRAND_DESCRIPTION="Camera remote control and media transfer"
```

## 自定义品牌

复制示例配置到本地目录：

```bash
mkdir -p branding/local
cp branding/example-custom/brand.yaml branding/local/brand.yaml
cp branding/zpill/icon.png branding/local/icon.png
```

编辑 `branding/local/brand.yaml`，把 `icon` 改为 `icon.png`，并填写自己的应用
身份和签名材料。`branding/local/` 已在 `.gitignore` 中，不会进入提交。

应用配置：

```bash
dart run tool/apply_brand.dart --config branding/local/brand.yaml
```

工具会生成以下本地文件：

- `android/brand.local.properties`
- `ios/Flutter/Brand.local.xcconfig`
- `branding/local/generated/dart-defines.json`

同时更新 HarmonyOS 的 `bundleName`、显示名和三端图标。构建时传入：

```bash
flutter build apk --release \
  --dart-define-from-file=branding/local/generated/dart-defines.json
```

这样 Flutter 内部标题和品牌文案也使用本地配置。图标生成依赖 `python3` 和
Pillow；默认 ZPill 配置也需要这一步来同步三端图标。

自定义图标会重新生成各平台图标资源。这些生成文件不要提交；拉取上游代码或
切换回其他品牌前，先运行默认配置恢复：

```bash
dart run tool/apply_brand.dart
```

## 身份规则

- 官方 `zpill` 配置不允许修改 Bundle ID。
- 自定义配置必须使用自己的 Bundle ID，不能复用官方身份。
- 修改 Bundle ID 会把应用视为全新安装，旧应用的本地数据和配对记录不会迁移。
- iOS 与 HarmonyOS 的自定义 Bundle ID 必须使用匹配的签名证书和 profile。
- Bundle ID 已发布后不应为了品牌改名而变更，否则现有用户无法直接升级。

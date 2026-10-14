/// 英文文案目录(i18n 第一期,2026-10-14)。
///
/// **键 = 中文原文逐字精确(含标点/空格),值 = 英文**。后续按目录抽取
/// 存量文案的 agent 在此追加:键必须与页面里 `t('…')` 的原文完全一致,
/// 差一个标点即查不到 → 回落中文(l10n.dart 的 t(),诚实兜底)。
///
/// 「中文」在英文环境也显示「中文」—— 语言专名,不译。
const Map<String, String> enCatalog = {
  '跟随系统': 'Follow System',
  '中文': '中文',
  'English': 'English',

  // ── settings / shell / common(i18n-2)──
  // settings_page(「设置」「BLE 配对 / GPS 注入」与 home_shell /
  // ble_pair_page 共用同键;主题三段「跟随系统/浅色/深色」因
  // settings_page_test 的 findsOneWidget 断言暂未包 t(),不在此列)
  '设置': 'Settings',
  '深色模式': 'Dark Mode',
  '跟随系统,或锁定浅色/深色': 'Follow system, or lock light/dark',
  '语言': 'Language',
  '界面文案语言;默认中文,可跟随系统':
      'UI text language; Chinese by default, can follow system',
  '自动传输(速传)': 'Auto Transfer (Quick)',
  '连接期间相机新拍的照片自动下载并导入相册':
      'New photos taken while connected are downloaded and imported into the photo library',
  '速传格式': 'Quick Transfer Format',
  '双格式(RAW+JPG)照片按此选择下载哪个;「仅视频」只速传视频':
      'Choose which file to download for dual-format (RAW+JPG) photos; "Video only" transfers videos only',
  '视频': 'Video',
  '元数据注入(XMP)': 'Metadata Injection (XMP)',
  '下载 JPG 时写入版权/作者/评分/位置(仅影响本机副本)':
      'Write copyright/author/rating/location into JPGs on download (local copies only)',
  '作者(dc:creator)': 'Author (dc:creator)',
  '版权(dc:rights)': 'Copyright (dc:rights)',
  '写入评分': 'Write Rating',
  '已打星的照片把星级写入 xmp:Rating':
      'Write star ratings into xmp:Rating for rated photos',
  '写入位置(GPS)': 'Write Location (GPS)',
  '下载时取当前位置写入 EXIF GPS(需定位权限)':
      'Write current location into EXIF GPS on download (location permission required)',
  '水印': 'Watermark',
  '下载 JPG 时合成:角标或摄影卡片(EXIF 卡)':
      'Composite on JPG download: corner badge or photo card (EXIF card)',
  '关闭': 'Off',
  '角标': 'Corner Badge',
  '摄影卡': 'Photo Card',
  '水印文本(空 = 相机型号)': 'Watermark text (empty = camera model)',
  '监看': 'Monitoring',
  '取景画面显示层处理:上采样 / 降噪 / 旋转 / 变宽':
      'Viewfinder display processing: upscaling / denoise / rotation / de-squeeze',
  '画面上采样': 'Upscaling',
  '关': 'Off',
  '快速': 'Fast',
  '高质量': 'High Quality',
  '时域降噪': 'Temporal Denoise',
  '前后帧运动自适应混合(仅「高质量」上采样生效)':
      'Motion-adaptive blending of adjacent frames (only with High Quality upscaling)',
  '画面自动旋转': 'Auto Rotate',
  '相机竖持/倒置时画面转正显示(默认开)':
      'Rotate the feed upright when the camera is held vertical or upside-down (on by default)',
  '变宽还原(anamorphic)': 'De-squeeze (anamorphic)',
  '变形宽银幕镜头的水平挤压按倍率还原显示;当前 {v}×':
      'De-squeeze the horizontal squeeze of anamorphic lenses; currently {v}×',
  '传输质量': 'Transfer Quality',
  '原图直传(压缩传输待后续版本)':
      'Originals as-is (compressed transfer in a later version)',
  'BLE 配对 / GPS 注入': 'BLE Pairing / GPS Injection',
  '相机智能设备模式配对;拍进卡的照片原生带 EXIF 坐标':
      'Pair the camera in smart-device mode; photos shot to card get native EXIF coordinates',

  // ble_pair_page(日志面板行 = 协议诊断输出,不译,如实中文)
  '未配对': 'Not Paired',
  '已断开': 'Disconnected',
  '握手中…': 'Handshaking…',
  '已连接(注入就绪)': 'Connected (injection ready)',
  '重连中(退避 {n}s)': 'Reconnecting (backoff {n}s)',
  '定位授权:{a}': 'Location auth: {a}',
  '已配对:{name}{serial}  {date}': 'Paired: {name}{serial}  {date}',
  '  序列 {s}': '  S/N {s}',
  '会话:{state} · 定位:{fix} · GEO {geo} 帧 · TIME {time} 帧':
      'Session: {state} · Location: {fix} · GEO {geo} frames · TIME {time} frames',
  '会话:{state} · 定位:{fix} · GEO {geo} 帧 · TIME {time} 帧 · 错误:{err}':
      'Session: {state} · Location: {fix} · GEO {geo} frames · TIME {time} frames · Error: {err}',
  '无': 'None',
  '相机先进菜单「连接至智能设备」(广播窗约 30 秒),再点扫描。':
      'On the camera, open the "Connect to Smart Device" menu first (advertising window ~30s), then tap Scan.',
  'iOS:配对成功后自动断开并跳系统蓝牙页,点相机完成配对(核对配对码)→ 回本页自动重连注册。':
      'iOS: after pairing succeeds, the app disconnects and opens the system Bluetooth page; tap the camera there to finish pairing (verify the passkey) → return here to reconnect and register automatically.',
  '扫描中…': 'Scanning…',
  '扫描(30s)': 'Scan (30s)',
  '解除配对': 'Unpair',
  '重连中…': 'Reconnecting…',
  '重连(复用身份)': 'Reconnect (reuse identity)',
  '绑定中…': 'Binding…',
  '绑定经典蓝牙': 'Bind Classic Bluetooth',
  '申请后台定位': 'Request Background Location',
  '去系统蓝牙完成注册': 'Go to System Bluetooth to Finish Registration',
  '未注册时可再跳一次:系统蓝牙页点相机配对(核对配对码)→ 回本页自动重连(配对成功后通常已自动跳过一次)':
      'Not registered yet? Jump again: pair the camera in system Bluetooth (verify the passkey) → return here to reconnect automatically (usually auto-jumped once after pairing)',
  '写 TIME': 'Write TIME',
  '唤起 WiFi': 'Wake Wi-Fi',
  '读 0x2004': 'Read 0x2004',
  '断开': 'Disconnect',
  '(无名)': '(unnamed)',
  '日志(长按可选中,或点右侧复制全部)':
      'Log (long-press to select, or copy all on the right)',
  '复制全部日志': 'Copy all logs',
  '日志已复制': 'Log copied',

  // snapshot_controller(restore 报表文案在 core/remote,后续波再收)
  '拍摄配置快照': 'Shooting Config Snapshots',
  '把当前机身设置存成命名预设,或把预设恢复回相机':
      'Save current camera settings as a named preset, or restore a preset back to the camera',
  '连接相机后可拍下当前配置': 'Connect a camera to capture the current config',
  '拍配置': 'Capture',
  '未连接相机,无法拍配置': 'Camera not connected; cannot capture config',
  '已保存「{name}」({n} 项属性)': 'Saved "{name}" ({n} properties)',
  '快照失败:{e}': 'Snapshot failed: {e}',
  '快照保存失败': 'Failed to save snapshot',
  '未连接相机,无法恢复': 'Camera not connected; cannot restore',
  '恢复已被总闸关断(紧急关断)':
      'Restore is disabled by the kill switch (emergency shutoff)',
  '恢复失败:{e}': 'Restore failed: {e}',
  '{model} · {n} 项 · {date}': '{model} · {n} props · {date}',
  '恢复到相机': 'Restore to Camera',
  '删除': 'Delete',
  '命名这份配置': 'Name This Config',
  '如:婚礼室内 · A 档': 'e.g. Indoor wedding · Mode A',
  '取消': 'Cancel',
  '保存': 'Save',

  // home_shell
  '相机': 'Camera',
  '图库': 'Gallery',

  // states
  '重试': 'Retry',

  // photo_info_sheet
  '照片信息': 'Photo Info',
  '文件': 'File',
  '大小': 'Size',
  '连拍': 'Burst',
  '时间': 'Time',
  '拍摄时间': 'Captured',
  '机身': 'Camera',
  '镜头': 'Lens',
  '参数': 'Exposure',

  // embedded_video_player
  '退出全屏': 'Exit Fullscreen',
  '全屏播放': 'Play Fullscreen',
  '顺帧 24fps · {p}%': 'Conforming 24fps · {p}%',
  '24fps 顺帧': 'Conform to 24fps',
};

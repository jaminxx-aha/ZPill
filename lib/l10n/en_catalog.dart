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
  '原图直传(压缩传输待后续版本)': 'Originals as-is (compressed transfer in a later version)',
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
  '设备ID 0x{id}': 'Device ID 0x{id}',
  '此相机在等别的手机(设备ID 0x{id}):请在相机「已配对设备」菜单断开现有连接或改选本机,或确认相机没被其他手机(如 SnapBridge)占用':
      'This camera is waiting for another phone (device ID 0x{id}): disconnect the existing connection or switch to this phone in the camera\'s "Paired Devices" menu, or make sure the camera is not occupied by another phone (e.g. SnapBridge)',
  '日志(长按可选中,或点右侧复制全部)': 'Log (long-press to select, or copy all on the right)',
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

  // ── connection(i18n-3)──
  // connection_status_card(状态 label 经变量在显示点包 t;hint 由控制
  // 器/连接层产出中文键,_HintText 消费点包 t;「重试」复用 states 组)
  '未连接': 'Not Connected',
  '检测相机 WiFi…': 'Detecting camera Wi-Fi…',
  '等待相机上确认配对…': 'Waiting for camera to confirm pairing…',
  '连接中…': 'Connecting…',
  '等待配对确认…': 'Waiting for pairing confirmation…',
  '已连接': 'Connected',
  '正在重连…': 'Reconnecting…',
  '连接失败': 'Connection Failed',
  '{free} 可用 / {total}': '{free} free / {total}',
  '容量未知': 'Capacity Unknown',

  // connection_page —— 分段/取消/通用提示(AppBar「相机」复用 home_shell)
  '取消重连': 'Cancel Reconnect',
  '取消连接': 'Cancel Connection',
  '有线': 'Wired',
  'AP 热点': 'AP Hotspot',
  '同一 Wi-Fi': 'Same Wi-Fi',
  '蓝牙': 'Bluetooth',
  '· 首次无线连接会请求配对确认(相机记录本设备,之后免配对);相机屏幕出现提示时请在机身上按 OK。\n'
          '· 相机同一时间只允许一个客户端:若被 SnapBridge(尼享)抢先连上会遭拒,请先彻底关闭它。\n'
          '· 首次连接若失败,请在系统弹窗中允许访问本地网络后重试;下载大文件期间请保持 App 在前台、屏幕点亮。':
      '· The first wireless connection asks for pairing confirmation on the camera (it remembers this device; no pairing needed afterwards); press OK on the camera when prompted.\n'
          '· The camera allows only one client at a time: if SnapBridge got there first you will be rejected — close it completely first.\n'
          '· If the first connection fails, allow local network access in the system dialog and retry; keep the app in the foreground with the screen on while downloading large files.',

  // connection_page —— 蓝牙工具卡(「握手中…/重连中…/未配对/关闭」复用)
  '蓝牙连接(工具通道)': 'Bluetooth (Tools)',
  '不建立相机连接(不传图/不遥控),只用于:拍摄时注入 GPS 坐标(照片原生带 EXIF 定位)、唤醒相机 Wi-Fi。首次使用先配对相机。':
      'No camera connection (no transfer, no remote control); only for injecting GPS coordinates while shooting (photos get native EXIF location) and waking the camera Wi-Fi. Pair the camera before first use.',
  '已配对,未连接': 'Paired, Not Connected',
  '配对相机': 'Pair Camera',
  '断开蓝牙': 'Disconnect Bluetooth',
  '重连': 'Reconnect',
  'GPS 位置注入': 'GPS Injection',
  '拍摄时自动把手机定位写进相机,卡内照片原生带坐标':
      'Automatically write the phone location into the camera while shooting; photos on the card get native coordinates',
  '唤醒相机 Wi-Fi': 'Wake Camera Wi-Fi',
  '已请求相机关闭 Wi-Fi': 'Requested the camera to turn off Wi-Fi',
  '读取 Wi-Fi 凭据(0x2004)': 'Read Wi-Fi Credentials (0x2004)',
  '配对管理(日志/解除/后台定位授权)': 'Manage Pairing (log/unpair/background location)',
  '唤醒失败:{e}': 'Wake failed: {e}',
  '未知': 'Unknown',
  '未下发': 'not sent',
  '相机 Wi-Fi 已唤醒:已断开蓝牙等相机开热点「{ssid}」;凭据见「AP 热点」卡,到系统 Wi-Fi 加入后回「AP 热点」卡连接':
      'Camera Wi-Fi is awake: Bluetooth released to let the camera raise hotspot "{ssid}"; credentials are on the "AP Hotspot" card — join it via system Wi-Fi, then connect from the "AP Hotspot" card',
  '相机 Wi-Fi 已唤醒:已断开蓝牙等相机开热点「{ssid}」;到系统 Wi-Fi 加入后回「AP 热点」卡连接':
      'Camera Wi-Fi is awake: Bluetooth released to let the camera raise hotspot "{ssid}" — join it via system Wi-Fi, then connect from the "AP Hotspot" card',
  '已断开蓝牙,正在加入相机热点「{ssid}」…':
      'Bluetooth released; joining camera hotspot "{ssid}"…',
  '已加入相机热点「{ssid}」,正在连接相机…':
      'Joined camera hotspot "{ssid}"; connecting to the camera…',
  '自动加入热点失败:{e};请到系统 Wi-Fi 手动加入(密码看相机屏幕),回「AP 热点」卡连接':
      'Auto-join failed: {e} — join via system Wi-Fi manually (password on the camera screen), then connect from the "AP Hotspot" card',
  '相机 Wi-Fi 已唤醒:已断开蓝牙等相机开热点;凭据未解出:{e},密码看相机屏幕到系统 Wi-Fi 加入;传图完点「重连」恢复蓝牙':
      'Camera Wi-Fi is awake: Bluetooth released to let the camera raise its hotspot; credentials not decoded: {e} — join via system Wi-Fi (password on the camera screen); tap "Reconnect" to resume Bluetooth after transfers',
  '已解出热点「{ssid}」,见「AP 热点」卡':
      'Hotspot "{ssid}" credentials decoded; see the "AP Hotspot" card',
  '未取得凭据:{e}': 'Credentials not retrieved: {e}',
  '操作失败:{e}': 'Operation failed: {e}',

  // connection_page —— 方式卡标题(_methodTitle 就地包 t)
  '有线连接(USB)': 'Wired (USB)',
  'AP 连接(相机当热点)': 'AP (Camera as Hotspot)',
  'STA 连接(同一 Wi-Fi)': 'STA (Same Wi-Fi)',

  // connection_page —— USB / AP 卡
  '用 C-to-C 数据线连接相机与手机,解锁相机后点「USB 连接」':
      'Connect the camera and phone with a C-to-C cable, unlock the camera, then tap "USB Connect"',
  'USB 连接': 'USB Connect',
  '相机菜单:网络 → 连接至智能设备 → Wi-Fi 连接(热点模式)。先在系统 Wi-Fi 设置里加入相机热点,再回来连接。':
      'Camera menu: Network → Connect to Smart Device → Wi-Fi Connection (hotspot mode). Join the camera hotspot in system Wi-Fi settings first, then come back to connect.',
  '相机 IP(默认 192.168.1.1)': 'Camera IP (default 192.168.1.1)',
  'AP 连接': 'AP Connect',
  '点「AP 连接」后 app 将自动接管相机:机身屏幕停在「已连接到计算机」、拨盘锁定,断开连接后恢复。':
      'After tapping "AP Connect", the app takes over the camera: its screen shows "Connected to Computer" and the dials lock; released on disconnect.',
  '相机热点凭据(蓝牙通道解出)': 'Camera Hotspot Credentials (decoded via Bluetooth)',
  '密码': 'Password',
  '安全:{s} · 加入热点后回此卡点「AP 连接」':
      'Security: {s} · join the hotspot, then tap "AP Connect" on this card',
  '(空)': '(empty)',
  '复制{label}': 'Copy {label}',
  '已复制{label}': '{label} copied',

  // connection_page —— STA 卡
  '相机与手机加入同一个 Wi-Fi(相机菜单同上,选择连接到路由器网络),扫描发现相机后点选连接。':
      'Camera and phone join the same Wi-Fi (same camera menu as above, choosing the router network); scan to find the camera, then tap it to connect.',
  '扫描中…(点按停止)': 'Scanning… (tap to stop)',
  '扫描相机': 'Scan for Cameras',
  '未发现:相机须停留在「等待连接」画面才会广播(退出该画面即停止);若刚在相机上完成配对,先在相机上按 OK。也可在下方手填 IP 直连。':
      'Nothing found: the camera only broadcasts while on the "Waiting for connection" screen (leaving it stops broadcasting); if you just finished pairing on the camera, press OK on the camera first. You can also type the IP below to connect directly.',
  '相机 IP(扫描不到时手填)': 'Camera IP (type manually if the scan finds nothing)',
  '如 192.168.1.4': 'e.g. 192.168.1.4',
  '扫描网段': 'Scan Subnet',
  '扫描网段中…': 'Scanning subnet…',
  '探测被拒(相机可能被其他应用占用)':
      'Probe rejected (camera may be occupied by another app)',
  '网段扫描未发现相机:请确认相机与手机在同一个 Wi-Fi,且相机停留在「等待连接」画面':
      'No camera found on this subnet: make sure the camera and phone are on the same Wi-Fi, and the camera stays on the "Waiting for connection" screen',
  '连接': 'Connect',
  '上次:{name}': 'Last: {name}',
  '忘记这台相机': 'Forget This Camera',
  '忘记这台相机?': 'Forget This Camera?',
  '删除「{name}」的连接记录。已配对的相机会同时换新配对身份,下次连接重新配对(自动确认,无需操作)。':
      'Delete the connection record for "{name}". Paired cameras also get a new pairing identity, so the next connection pairs again (auto-confirmed, no action needed).',

  // connection_page —— 已连接视图(「删除」复用 snapshot_controller 组)
  '进入拍摄': 'Remote Shooting',
  '相册': 'Gallery',
  '断开连接': 'Disconnect',
  'USB 数据线': 'USB Cable',
  '相机相册': 'Camera Album',

  // connection_page —— 信息卡行(_infoRow 就地包 t;值列相机上报串未命中原样)
  '连接方式': 'Link',
  '设备': 'Device',
  '型号': 'Model',
  '读取中…': 'Loading…',
  '固件版本': 'Firmware',
  '序列号': 'Serial No.',
  '电池': 'Battery',
  '镜头型号': 'Lens',
  '焦距': 'Focal Length',
  '光圈': 'Aperture',

  // connection_page —— 控制器 hint(键存控制器,消费点 _HintText 包 t)
  '配对信息已发送:请在相机屏幕上按「OK」完成配对,应用将自动重连(最长约 1 分钟)':
      'Pairing info sent: press "OK" on the camera screen to finish pairing; the app reconnects automatically (up to about 1 minute)',
  '正在配对(自动确认)': 'Pairing (auto-confirmed)',
  '正在自动重连…': 'Reconnecting automatically…',

  // ── remote-pages(i18n-4)──
  // remote_page(「相机相册」复用 connection_page 组)
  '显示控制界面': 'Show Controls',

  // remote_mode_strip(「视频」复用 settings 组)
  '照片': 'Photo',

  // remote_param_sheet —— 参数编辑底单(目录 label 与 displayParamValue
  // 值文案的键存 shooting_param_catalog / remote_controller,显示点已包 t,
  // 条目归那两个文件的波次;「APP 接管」区 remote_mode_sheet 同件共用)
  '宽C1/C2 为横带/竖条区域:触屏移框仅上下/左右单轴生效':
      'Wide C1/C2 are horizontal-band/vertical-strip areas: touch-dragging the frame moves only one axis',
  '自动 ISO': 'Auto ISO',
  '该属性的取值域未知,暂不可调(待真机核对)':
      'Value range for this property is unknown; not adjustable yet (pending on-hardware check)',
  '启用 APP 接管控制?': 'Enable APP Takeover?',
  '该设置项受相机物理拨盘控制,启用接管后应用才能调整。'
          '接管期间机身拨盘可能被锁定、机身屏幕可能熄灭;'
          '点按「APP 接管中」或断开连接可解除。':
      'This setting is controlled by the camera physical dial; the app can adjust it only after takeover is enabled. '
          'While takeover is active, the body dial may be locked and the camera screen may go dark; '
          'tap "APP Takeover Active" or disconnect to release.',
  '启用': 'Enable',

  // remote_settings_panel —— 分组标题/对焦控制/监看开关/画质行/辅助芯片
  // (「监看」「关」复用既有键;「AE-L」「GPS」为拉丁串不译)
  '拍摄参数': 'Shooting Params',
  '对焦': 'Focus',
  '辅助': 'Assist',
  'MF 近': 'MF Near',
  'MF 向近(步进)': 'MF toward near (stepped)',
  'MF 远': 'MF Far',
  'MF 向远(步进)': 'MF toward far (stepped)',
  '主体追踪': 'Subject Tracking',
  '启动后相机持续追焦所选主体(点取景画面选目标),再点停止':
      'Once started, the camera keeps focusing on the selected subject (tap the viewfinder to pick a target); tap again to stop',
  '拉焦轮': 'Focus Dial',
  '机身对焦模式为 MF,远程对焦已停用': 'Camera focus mode is MF; remote focus is disabled',
  '主体追踪:AF 区域切到「自动」后可用':
      'Subject tracking: available after switching AF area to "Auto"',
  '取景': 'Viewfinder',
  '网格': 'Grids',
  '斑马纹': 'Zebra',
  '直方图': 'Histogram',
  '水平仪': 'Level',
  '伪色': 'False Color',
  '峰值': 'Peaking',
  '波形': 'Waveform',
  // 示波器族(2026-10-15):循环芯片档名 + 红绿灯带名 + N-Log 刻度行
  // (「RGB」/「N-Log」为拉丁串不译;「矢量」/「红绿灯」档名)。
  '示波器': 'Scope',
  '矢量': 'Vector',
  '红绿灯': 'Traffic Lights',
  '示波器:关→波形→RGB Parade→矢量→红绿灯 循环切换':
      'Scope: cycles Off → Waveform → RGB Parade → Vector → Traffic Lights',
  '上部': 'Top',
  '中部': 'Mid',
  '下部': 'Bot',
  '示波器刻度': 'Scope Scale',
  '全幅': 'Full Range',
  'N-Log 刻度:波形 Y 轴按合法量程 64-940 码 ↔ 0-100 IRE 标注,带 18% 灰线;须相机菜单开 N-Log 才对得上':
      'N-Log scale: waveform Y axis labeled by legal range 64-940 code ↔ 0-100 IRE with an 18% grey line; matches only when N-Log is enabled in the camera menu',
  '遮幅': 'Matte',
  '遮幅 {v}': 'Matte {v}',
  '构图遮幅:2.39/2.35/1.85 循环;画幅外压暗(变宽还原已计入)':
      'Framing matte: cycles 2.39/2.35/1.85; the area outside the frame is dimmed (de-squeeze included)',
  '安全框': 'Safe Area',
  '中心标': 'Center Mark',
  '实验性:强制关闭机背内屏(重连/重开后状态未知)':
      'Experimental: force the camera rear screen off (state after reconnect/reopen unknown)',
  '内屏': 'Rear Screen',
  '监看套色(不写帧数据):选中即自动走高质量渲染管线,shader 不可用时无 LUT':
      'Monitor LUT (frame data untouched): selecting it automatically switches to the high-quality render pipeline; no LUT when the shader is unavailable',
  '监看 LUT': 'Monitor LUT',
  // 监看 LUT 芯片标题(键存 edit/lut_presets.dart 的 builtinLuts,显示点
  // remote_settings_panel 包 t;edit/ 波 i18n-8 复用)
  '青橙': 'Teal & Orange',
  '褪色胶片': 'Faded Film',
  '冷调': 'Cool Matte',
  'N-Log 还原': 'N-Log Conversion',
  '峰值灵敏度': 'Peaking Sensitivity',
  '低': 'Low',
  '中': 'Medium',
  '高': 'High',
  '峰值颜色': 'Peaking Color',
  '金': 'Gold',
  '白': 'White',
  '红': 'Red',
  '峰值算法': 'Peaking Engine',
  '双尺度': 'Dual-Scale',
  '经典': 'Classic',
  '取景尺寸': 'Viewfinder Size',
  '跟随': 'Follow',
  '取景画质': 'Viewfinder Quality',
  'Basic 尺寸': 'Basic Size',
  'Basic 质量': 'Basic Quality',
  'Normal 尺寸': 'Normal Size',
  'Normal 质量': 'Normal Quality',
  'Fine 尺寸': 'Fine Size',
  'Fine 质量': 'Fine Quality',
  '对焦后拍': 'Focus Then Capture',
  '释放快门前先自动对焦(半按-全按;候选参数,待真机核对)':
      'Autofocus before releasing the shutter (half-press then full-press; candidate, pending on-hardware check)',
  'SDRAM 直拍': 'SDRAM Capture',
  'AF+SDRAM 一体拍(0x90CB):对象不入卡,回传 APP 存图库':
      'AF+SDRAM one-shot capture (0x90CB): nothing is written to the card; the image is sent back to the app and saved to the gallery',
  'AE/AWB 锁定(0x9426):曝光随锁定时刻固定,再点解除':
      'AE/AWB lock (0x9426): exposure is frozen at the moment of locking; tap again to release',
  'BLE 定位注入(0x2007):拍进卡的照片原生带 EXIF 坐标':
      'BLE location injection (0x2007): photos shot to the card get native EXIF coordinates',
  '未配对:设置页「BLE 配对 / GPS 注入」先配对相机':
      'Not paired: pair the camera first in Settings "BLE Pairing / GPS Injection"',
  '音量键快门': 'Volume Key Shutter',
  '音量上/下键兼作快门(拍摄页存续期生效);'
          'Android 拦键事件,iOS 观察系统音量(按键瞬时改音量并吸回,'
          '音量条已藏),ohos 未做拦截':
      'Volume up/down keys double as the shutter (effective while the shooting page is open); '
          'Android intercepts key events, iOS observes system volume (a press nudges the '
          'volume and pins it back, with the volume HUD hidden), and ohos has no native '
          'interception',
  '自拍': 'Self-timer',
  '自拍 {s}s': 'Self-timer {s}s',
  '自拍定时:关/2s/5s/10s 点选;倒计时中再点取消':
      'Self-timer: pick Off/2s/5s/10s; tap again during the countdown to cancel',
  '{s} 秒': '{s}s',
  'APP 接管中': 'APP Takeover Active',
  'APP 接管': 'APP Takeover',
  '拨盘级参数(快门/模式/ISO/光圈)需先接管才能遥控调整':
      'Dial-level params (shutter/mode/ISO/aperture) require takeover before remote adjustment',

  // ── remote-rest(i18n-5)──
  // live_view_overlays(overheatBadgeText 纯函数产出原文即 t() 键,Overheat
  // Badge 显示点包 t(),倒计时 m:ss 尾段数字串拼在译文后)
  '机内温度升高': 'Internal temperature rising',
  '机内温度较高': 'Internal temperature high',
  '机内高温,录制即将停止': 'Camera overheating; recording will stop soon',
  '即将自动停止录制': 'Recording will stop automatically',

  // remote_feed_area(取景空态/横幅;lastError 为引擎运行期串,如实回落)
  '取景中…(等待首帧)': 'Viewfinder On… (waiting for first frame)',
  '取景失败({e})': 'Viewfinder failed ({e})',
  '取景未开启\n点按画面可触控对焦': 'Viewfinder off\nTap the image to set the focus point',
  '未知错误': 'Unknown error',
  '重试取景': 'Retry Viewfinder',
  '无线拍摄需 APP 接管(机身拨盘锁定,退出拍摄自动解除)':
      'Wireless shooting needs App Takeover (camera dial locked; released automatically when you leave the shooting screen)',
  '开启 APP 接管并重试取景': 'Enable App Takeover & Retry Viewfinder',
  '连接中断 —— 正在自动重连;画面为断开前的保持帧,非实时':
      'Connection lost — reconnecting automatically; the image is the frozen frame from before the drop, not live',
  '相机忙(写卡/下载中),取景画面保持':
      'Camera busy (card write/download in progress); viewfinder frame held',
  '未连接相机 —— 请先在「相机」页建立连接':
      'Camera not connected — connect from the "Camera" page first',

  // remote_action_row(tooltip;「相机相册」复用 connection 组)
  '拍摄设置(参数 / 网格斑马纹 / 辅助)':
      'Shooting Settings (params / grids & zebra / assist)',
  '自动对焦': 'Autofocus',

  // remote_capture_strip(CaptureParamTile 的「(自动)」值后缀;label 与
  // 值文案的键见下方 shooting_param_catalog / remote_controller 组)
  '(自动)': '(auto)',

  // remote_info_pill(「已连接/APP 接管中」复用既有键;未连接相机与
  // remote_controller 共键)
  '未连接相机': 'Camera not connected',
  '{n} 张': '{n} shots',
  '纯净监看(隐藏全部控制,只留画面)': 'Clean Monitoring (hide all controls, image only)',

  // remote_mode_sheet(门头标;接管区文案复用 remote_param_sheet 组)
  '拍摄模式': 'Shooting Mode',

  // shooting_param_catalog(label/枚举值/格式化静态文案原文即 t() 键,
  // 显示点 remote_param_sheet(i18n-4)与 remote_capture_strip 已包 t;
  // 「关闭/关/快速/自拍/光圈」复用既有键,纯拉丁串 ISO/EV/FX/DX/AF-S/
  // N-Log 等不译;「创意 N/自定义 N/云 N/值 N」与快门分数为运行期
  // 插值串,无静态键,如实回落中文。「快门」是 l10n_test 钉死的
  // 「未命中回落」样例键,不入表 —— EN 下快门 tile label 回落中文,
  // 宁缺毋错)
  '模式': 'Mode',
  '白平衡': 'White Balance',
  '色温': 'Color Temperature',
  '闪光': 'Flash',
  '测光': 'Metering',
  '对焦模式': 'Focus Mode',
  '释放': 'Release',
  '画质': 'Quality',
  'RAW 压缩': 'RAW Compression',
  '图像区域': 'Image Area',
  'AF 区域': 'AF Area',
  '主体检测': 'Subject Detection',
  '色调': 'Tone Mode',
  '优化校准': 'Picture Control',
  '手动 M': 'Manual M',
  '程序 P': 'Program P',
  '光圈优先 A': 'Aperture Priority A',
  '快门优先 S': 'Shutter Priority S',
  '自动': 'Auto',
  '人像': 'Portrait',
  '风景': 'Landscape',
  '微距': 'Macro',
  '运动': 'Sports',
  '夜景': 'Night',
  '夜景人像': 'Night Portrait',
  '儿童': 'Children',
  '场景': 'Scene',
  '特效': 'Effects',
  '直射阳光': 'Direct Sunlight',
  '荧光灯': 'Fluorescent',
  '白炽灯': 'Incandescent',
  '阴天': 'Cloudy',
  '背阴': 'Shade',
  '手动预设': 'Preset Manual',
  '自然自动': 'Natural Auto',
  '防红眼': 'Red-eye Reduction',
  '补充闪光': 'Fill Flash',
  '慢速同步': 'Slow Sync',
  '后帘同步': 'Rear-curtain Sync',
  '防红眼慢速': 'Red-eye Slow Sync',
  '中央重点': 'Center-weighted',
  '矩阵': 'Matrix',
  '点测光': 'Spot',
  '高光': 'Highlight',
  '单张': 'Single',
  '低速连拍': 'Low-speed Burst',
  '高速连拍': 'High-speed Burst',
  '高速连拍+': 'High-speed Burst+',
  '连拍 C15': 'Burst C15',
  '连拍 C30': 'Burst C30',
  '连拍 C60': 'Burst C60',
  '连拍 C120': 'Burst C120',
  'JPEG 基本': 'JPEG Basic',
  'JPEG 基本★': 'JPEG Basic ★',
  'JPEG 标准': 'JPEG Normal',
  'JPEG 标准★': 'JPEG Normal ★',
  'JPEG 精细': 'JPEG Fine',
  'JPEG 精细★': 'JPEG Fine ★',
  'RAW+JPEG 基本': 'RAW+JPEG Basic',
  'RAW+JPEG 基本★': 'RAW+JPEG Basic ★',
  'RAW+JPEG 标准': 'RAW+JPEG Normal',
  'RAW+JPEG 标准★': 'RAW+JPEG Normal ★',
  'RAW+JPEG 精细': 'RAW+JPEG Fine',
  'RAW+JPEG 精细★': 'RAW+JPEG Fine ★',
  '无损压缩': 'Lossless',
  '压缩(旧型)': 'Compressed (legacy)',
  '未压缩': 'Uncompressed',
  '高效率★': 'High Efficiency ★',
  '高效率': 'High Efficiency',
  '单点': 'Single Point',
  '精确': 'Pinpoint',
  '宽S': 'Wide S',
  '宽L': 'Wide L',
  '宽C1': 'Wide C1',
  '宽C2': 'Wide C2',
  '人': 'People',
  '动物': 'Animals',
  '车辆': 'Vehicles',
  '鸟': 'Birds',
  '飞机': 'Airplanes',
  '标准': 'Standard',
  '中性': 'Neutral',
  '鲜艳': 'Vivid',
  '单色': 'Monochrome',
  '平面': 'Flat',
  'X 同步': 'X-sync',
  '视频光圈': 'Movie Aperture',
  '视频快门': 'Movie Shutter',
  '视频 ISO': 'Movie ISO',
  '视频 EV': 'Movie EV',
  '视频白平衡': 'Movie White Balance',
  '开': 'On',
  '开(HDMI 外录)': 'On (HDMI external)',
  '正常': 'Normal',
  '同照片设置': 'Same as Photos',
  '视频减震': 'Movie Stabilization',
  '电子减震': 'Electronic Stabilization',
  '录制时间码': 'Record Timecodes',
  '计数方法': 'Count-up Method',
  '丢帧': 'Drop Frame',
  '视频区域': 'Movie Image Area',
  'H.265 色调': 'H.265 Tone Mode',
  '宽C1 是横向条形区域,触屏移框仅上下生效':
      'Wide C1 is a horizontal-strip area: touch-dragging the frame moves only vertically',
  '宽C2 是纵向条形区域,触屏移框仅左右生效':
      'Wide C2 is a vertical-strip area: touch-dragging the frame moves only horizontally',

  // remote_controller(error/notice 原文即 t() 键:无 BuildContext 中文
  // 直存,消费点 remote_banner/LiveBannerHost 包 t();含 $e/$mode/响应码
  // 插值的运行期串无静态键,如实回落中文,_nikonHint 七段同此仅作插值
  // 片段)
  '请先开启取景再录制': 'Start the viewfinder before recording',
  '请先开启取景': 'Start the viewfinder first',
  '相机当前状态不允许录制 —— 请把机顶「照片/视频」切换拨杆拨到视频档后重试(取景保持开启)':
      'The camera does not allow recording right now — switch the top "photo/video" lever to video and retry (the viewfinder stays on)',
  '对焦已到近端': 'Focus reached the near limit',
  '对焦已到远端': 'Focus reached the far limit',
  '近端已到,反向驱动解锁': 'Near limit reached; drive the other way to unlock',
  '远端已到,反向驱动解锁': 'Far limit reached; drive the other way to unlock',
  '步进量过小,镜头未动': 'Step too small; the lens did not move',
  '手动对焦不可用(机械对焦环或机身忙)':
      'Manual focus unavailable (mechanical focus ring or camera busy)',
  '对焦滚轮已暂停(连续失败),稍后自动恢复':
      'Focus dial paused (repeated failures); it will resume automatically',
  '机身对焦模式为 MF —— 远程对焦不可用,请切回 AF-S/AF-C(「对焦模式」芯片可直接切换)':
      'Camera focus mode is MF — remote focus is unavailable; switch back to AF-S/AF-C (the "Focus Mode" chip switches directly)',
  '暂无取景帧,无法定位对焦点': 'No viewfinder frame yet; cannot place the focus point',
  '暂无取景帧,无法定位追踪目标':
      'No viewfinder frame yet; cannot locate the tracking target',
  '已取消对焦': 'Focus cancelled',
  '主体追踪需 AF 区域为「自动」(「AF 区域」芯片可切换)':
      'Subject tracking needs the AF area set to "Auto" (switch it from the "AF Area" chip)',
  '相机拒绝了远程切换拍摄模式 —— 请直接用机顶拨杆切换':
      'The camera refused the remote mode switch — use the top lever directly',
  '参数写入已关断,无法切换拍摄模式':
      'Parameter writing is disabled; cannot switch shooting mode',
  '快门释放失败:相机存储不可用 —— 请检查存储卡与插槽;若卡在位,可能是机身拨杆在视频档拒绝了远程拍照,请拨回照片档重试(视频档请用拍摄页的录制钮拍视频)':
      'Shutter release failed: camera storage unavailable — check the memory card and slot; if the card is seated, the lever may be in the video position and refused the remote photo — switch back to photo and retry (use the record button on the shooting page for video)',
  '快门释放失败:相机不接受快门参数(0x201D,已试全部已知形态)—— 请反馈当时的「APP 接管」与「对焦后拍」状态':
      'Shutter release failed: the camera rejected the shutter parameters (0x201D, all known forms tried) — please report the "APP Takeover" and "Focus Then Capture" states at the time',
  '快门释放失败:录像中的静照拍摄尚在进行,请稍候再试':
      'Shutter release failed: a still capture during recording is still in progress; try again shortly',
  '相机当前状态不允许拍照 —— 请把机顶「照片/视频」切换拨杆拨回照片档后重试(视频档请用拍摄页的录制钮拍视频)':
      'The camera does not allow photos right now — switch the top "photo/video" lever back to photo and retry (use the record button on the shooting page for video)',
  '拍摄完成,但未收到相机回传对象(SDRAM 对象未到,可稍后在相机相册确认)':
      'Capture finished, but no object came back from the camera (SDRAM object not received; check the camera album later)',
  'B 门收门失败:相机持续忙(已重试 3 次),曝光可能仍在进行,请再点一次快门收门或查看相机':
      'Bulb close failed: the camera stayed busy (retried 3 times); the exposure may still be running — tap the shutter once more to close it, or check the camera',
  '定时 B 门自动收门失败:相机持续忙(已重试 3 次),曝光可能仍在进行,请再点一次快门收门或查看相机':
      'Timed-bulb auto-close failed: the camera stayed busy (retried 3 times); the exposure may still be running — tap the shutter once more to close it, or check the camera',
  '曝光已结束,但快门值未能自动恢复,请在快门面板手动改回':
      'The exposure has ended, but the shutter value could not be restored automatically; set it back from the shutter panel',
  '快门在 B 门/Time 档:请用屏上快门钮按住曝光,或开启自拍定时组合为定时 B 门':
      'Shutter is in Bulb/Time: hold the on-screen shutter button to expose, or enable the self-timer to combine it into a timed Bulb exposure',
  '已拍摄(SDRAM,不入卡):未接图库通道,对象未保存':
      'Captured (SDRAM, not to card): no gallery channel attached; object not saved',
  '已拍摄并保存到图库(SDRAM,不入卡)':
      'Captured and saved to the gallery (SDRAM, not to card)',
  '已拍摄(SDRAM,不入卡):图库保存失败,可到传输页重试':
      'Captured (SDRAM, not to card): gallery save failed; retry from the transfers page',
  '已拍摄(SDRAM,不入卡):仍在后台保存到图库,进度见传输页':
      'Captured (SDRAM, not to card): still saving to the gallery in the background; see the transfers page for progress',
  '已拍摄': 'Captured',
  '参数写入已被总闸关断(kSetPropEnabled=false,紧急关断)':
      'Parameter writing is disabled by the kill switch (kSetPropEnabled=false, emergency shutoff)',
  '该参数由机身转盘控制,不支持遥控修改':
      'This parameter is owned by the camera dial; remote changes are not supported',
  '该参数当前由相机自动控制,不可手调':
      'This parameter is currently auto-controlled by the camera; not manually adjustable',
  '相机上报该属性为只读': 'The camera reports this property as read-only',
  '该值无法换算为机身写码(0x100),未发送':
      'This value cannot be converted to the camera write code (0x100); not sent',

  // ── browser(i18n-6)──
  // photo_grid_page(网格页;标题兜底「相机相册」/删除确认钮「删除」/横幅
  // 「重试」复用既有键;controller.error 是运行期 $e 插值串无静态键,
  // 消费点 states.dart 的 ErrorRetryPanel/InlineHint 显示端已包 t,英文
  // 环境如实回落中文;日期分段头的日期段(sectionDateLabel,common/
  // format)是日期格式产物不抽,同如实回落;typeLabel 角标(jpg/raw/
  // jpg+raw/×N)为拉丁协议串不抽)
  '{label} · {n} 张': '{label} · {n} Photos',
  '未知日期': 'Undated',
  '全部照片': 'All Photos',
  '已选 {n} 项': 'Selected {n} Items',
  '全选': 'Select All',
  '取消选择': 'Clear Selection',
  '刷新': 'Refresh',
  '已选 {n} 项,其中 {m} 项为双格式': 'Selected {n} items, {m} of them dual-format',
  '已选 {n} 项(照片与视频混选)': 'Selected {n} items (photos and videos mixed)',
  '没有符合「{label}」的文件,未开始下载': 'No files matching "{label}"; download not started',
  // 目的地片段键带介词「到…」:不立裸键「应用」—— edit 页的「应用」是
  // Apply 动词(i18n-8 另议),裸键会撞义
  '到相册': 'to the album',
  '到应用': 'to the app',
  ',跳过 {n} 项无 {s}': ', {n} items without {s} skipped',
  '已开始下载 {i}/{g} 项 / {f} 个文件{tag} {where}{skip},进度见「图库」页':
      'Download started: {i}/{g} items / {f} files{tag} {where}{skip}; see "Gallery" for progress',
  '删除相机上的文件?': 'Delete Files on the Camera?',
  '将删除 {n} 项(共 {f} 个文件)。\n此操作不可恢复。':
      'This will delete {n} items ({f} files in total).\nThis cannot be undone.',
  '已删除 {n} 个文件,{m} 个失败(相机拒绝或传输中断,条目保留)':
      'Deleted {n} files, {m} failed (camera refused or transfer interrupted; items kept)',
  '已删除 {n} 个文件': 'Deleted {n} files',
  '正在连接相机读取对象…': 'Connecting to the camera to read objects…',
  '正在读取相机对象 {a}/{b}…': 'Reading camera objects {a}/{b}…',
  '相机里还没有照片\n(未连接时请先在「相机」页连接)':
      'No photos on the camera yet\n(Connect from the "Camera" page first if not connected)',
  '下载到相册': 'Download to Album',
  '下载到应用': 'Download to App',

  // photo_viewer_page(查看器;「照片信息/视频/取消」复用既有键;格式
  // short 的「视频」走既有键,JPG/RAW/JPG+RAW 拉丁值未命中原文直返;
  // _snack 是 await 后消费点的 t() 收口;transfers(i18n-7)的「已取消」
  // 与 library 的「刷新/该平台暂不支持视频播放」复用本组键)
  '相机内保护(锁定)': 'Protect in Camera (Lock)',
  '解除相机内保护': 'Remove Camera Protection',
  '已设为相机内保护(只读)': 'Protected in camera (read-only)',
  '已解除相机内保护': 'Camera protection removed',
  '保护标记失败:{e} —— 请确认相机连接与卡写保护状态':
      'Protection toggle failed: {e} — check the camera connection and the card write-protect state',
  '编辑': 'Edit',
  '评分': 'Rating',
  '清除评分': 'Clear Rating',
  '连拍 ×{n}': 'Burst ×{n}',
  '这张照片有 JPG 和 RAW 两份文件': 'This photo has both a JPG and a RAW file',
  '已开始下载{where}{tag},进度见「图库」页':
      'Download started {where} {tag}; see "Gallery" for progress',
  '查看进度': 'View Progress',
  '拉取原图…': 'Fetching Original…',
  '拉取原图失败,请检查连接后重试':
      'Failed to fetch the original; check the connection and retry',
  '已取消': 'Cancelled',
  '加载视频失败,请检查连接后重试': 'Failed to load the video; check the connection and retry',
  '加载预览…': 'Loading preview…',
  '点按播放键观看': 'Tap play to watch',
  '预览不可用': 'Preview Unavailable',
  '准备播放': 'Preparing to Play',
  '该平台暂不支持视频播放': 'Video playback is not yet supported on this platform',

  // download_format_sheet(格式 label/short 的键存 core 的
  // PhotoDownloadFormat 枚举 —— 本波不动枚举,显示点包 t;
  // 「JPG + RAW」label 纯拉丁未命中原文直返;subtitle 由调用方预翻译)
  '选择下载格式': 'Choose Download Format',
  '仅 JPG': 'JPG Only',
  '仅 RAW': 'RAW Only',
  '仅视频': 'Video Only',
  '没有 JPG 的照片会跳过(视频照常)':
      'Photos without a JPG are skipped (videos still download)',
  '没有 RAW 的照片会跳过(视频照常)':
      'Photos without a RAW are skipped (videos still download)',
  '有什么下什么(缺哪个格式就只下另一个)':
      'Download whatever is there (if one format is missing, only the other downloads)',
  '只下视频,照片全部跳过': 'Videos only; all photos are skipped',

  // ── library-transfers(i18n-7)──
  // local_library_page(「图库」「刷新」「照片」「视频」「连拍」「删除」
  // 「照片信息」「该平台暂不支持视频播放」复用既有键;筛选/排序/类型
  // chips 的 label 存枚举原文即 t() 键,显示点包 t;「传输」键与下方
  // transfers_page 的 AppBar 标题同键共用)
  '全部': 'All',
  '新→旧': 'Newest First',
  '旧→新': 'Oldest First',
  '应用内还没有文件\n(在相机相册里选择「下载到应用」)':
      'No files in the app yet\n(choose "Download to App" in the camera album)',
  '没有{label}格式的文件': 'No {label} files',
  '没有符合条件的文件': 'No matching files',
  '传输': 'Transfers',
  '删除应用内文件?': 'Delete In-App File?',
  '将删除「{name}」。\n此操作不可恢复(相机上的原件不受影响)。':
      'This will delete "{name}".\nThis cannot be undone (the original on the camera is unaffected).',
  '导入系统相册': 'Import to System Album',
  '已导入系统相册(应用内文件保留)': 'Imported to the system album (the in-app file is kept)',
  '未导入(已取消或失败)': 'Not imported (cancelled or failed)',
  'LUT 导出': 'LUT Export',
  'LUT 风格': 'LUT Style',
  '导出中…': 'Exporting…',
  '导出失败': 'Export Failed',
  'LUT 解析失败': 'LUT Parse Failed',
  '已保存到系统相册': 'Saved to the system album',
  'RAW 解码失败(该平台可能不支持)': 'RAW decode failed (this platform may not support it)',

  // transfers_page(「取消」「已取消」「未知错误」复用既有键;字节数/速度
  // 为数字格式产物不抽;「失败:{e}…」模板的 {e} 运行期串经 t 未命中
  // 原样回落,标题「传输」复用上方 local_library 组)
  '清空历史': 'Clear History',
  '暂无传输任务\n(在相机相册里多选或大图页单张下载)':
      'No transfer tasks yet\n(select multiple in the camera album, or download single items from the photo viewer)',
  '排队中': 'Queued',
  '剩 {n}s': '{n}s left',
  '已导入相册': 'Imported to the album',
  '已完成 · 未导入(可重新下载再试)': 'Completed · not imported (download again to retry)',
  '已保存到应用内': 'Saved to the app',
  '失败:{e}(重试 {n} 次)': 'Failed: {e} (after {n} attempts)',

  // ── edit(i18n-8)──
  // edit_page(「取消」「无」复用既有键;LUT 芯片标题键存 edit/lut_presets
  // 的 builtinLuts —— 4 条已在 i18n-4(remote-pages 段)入表,remote_
  // settings_panel 与本页 _lutPanel 两个显示点同键包 t;剪贴板导入的
  // .cube TITLE/.xmp 表名通常为拉丁串,未命中原样回落。「应用」是 Apply
  // 动词
  // —— i18n-6 预留的决定在此落地:browser 段的「到应用/下载到应用」
  // 是名词性介词片段,不同键不撞义。toast 走 _toast 消费点收口,
  // 带参模板在调用点先 t+填充(二次 t 不命中键原样回落,无害))
  '重置': 'Reset',
  '保存到相册': 'Save to Album',
  '无法编辑此文件(仅支持 JPEG)': 'Cannot edit this file (JPEG only)',
  '旋转': 'Rotate',
  '裁剪': 'Crop',
  '调节': 'Adjust',
  '左转 90°': 'Rotate Left 90°',
  '右转 90°': 'Rotate Right 90°',
  '选择裁剪区域': 'Select Crop Area',
  '自由': 'Free',
  '原比例': 'Original',
  '应用': 'Apply',
  '亮度': 'Brightness',
  '对比': 'Contrast',
  '饱和': 'Saturation',
  '暖调': 'Warmth',
  '从剪贴板导入 .cube/.xmp': 'Import .cube/.xmp from Clipboard',
  '导入': 'Imported',
  '已保存到相册': 'Saved to the album',
  '未保存(已取消)': 'Not saved (cancelled)',
  '保存失败,请重试': 'Save failed; please retry',
  '剪贴板没有文本': 'No text in the clipboard',
  '未命名': 'Untitled',
  '已导入「{title}」({size}³)': 'Imported "{title}" ({size}³)',
  '导入失败:{e}': 'Import failed: {e}',

  // edit_page 胶片面板(i18n-8 后续波):工具名 + 分组芯片 —— 分组键存
  // core/media/film_presets 的 filmPresetGroups(固定 7 组,同 LUT 芯片
  // 标题先例入目录);预设名(87 款)是数据非键,英文环境直接取预设
  // 自带的 nameEn(参考仓 code 原文),不走 t —— 目录成本远超收益,
  // 且与 .cube TITLE 原样回落同哲学。
  '胶片': 'Film',
  '富士胶片': 'Fuji Film',
  '柯达胶片': 'Kodak Film',
  '理光人文': 'Ricoh Street',
  '索尼大师': 'Sony Masters',
  '经典黑白': 'Classic B&W',
  '电影特色': 'Cinema',
  '经典精选': 'Classic Picks',

  // connection 层静态错误兜底(i18n-8 终检补包):键存 core/camera/
  // camera_connection 与 app_services(无 BuildContext,中文直存),消费
  // 点 connection_status_card 的 _HintText 已包 t(i18n-3),静态键本波
  // 补齐;带 $e/$ip/$reason 插值的运行期串无静态键,如实回落中文
  '未发现尼康相机:请插好 USB 数据线并解锁相机后重试':
      'No Nikon camera found: plug in the USB cable, unlock the camera, then try again',
  '相机处于受限连接状态(数据操作被禁用):请关闭相机电源,重新开机后再连接':
      'The camera is in a restricted connection state (data operations disabled): turn the camera off and back on, then reconnect',
  '连接在短时间内反复中断,自动重连已暂停:'
          '请检查相机状态(电量/过热)与 Wi-Fi 链路,稍后手动重连':
      'The connection dropped repeatedly within a short time; auto-reconnect is paused: '
          'check the camera (battery / overheating) and the Wi-Fi link, then reconnect manually later',
  '相机被占用(可能被 SnapBridge/尼享连接),每 5 秒慢速重试,可点「取消」':
      'The camera is busy (possibly held by SnapBridge); retrying slowly every 5 s — tap "Cancel"',
  '正在等待相机重新接入 USB(重新插好数据线后自动续连)':
      'Waiting for the camera to come back over USB (plug the cable in again to resume automatically)',
  '取景流多次重启未恢复':
      'The viewfinder stream failed to recover after repeated restarts',

  // ── remote 间隔拍摄(静态键;控制器 notice 的运行期插值串按既定
  // 口径回落中文,同错误消息家族)──
  '间隔拍摄': 'Interval Shooting',
  '间隔拍摄参数': 'Interval Shooting Setup',
  '间隔 {a}/{b}': 'Interval {a}/{b}',
  '间隔拍摄 {a}/{b} 张': 'Interval {a}/{b} shots',
  '间隔拍摄 {a}/{b} 张 · 已暂停': 'Interval {a}/{b} shots · paused',
  '{n} 张失败': '{n} failed',
  '间隔': 'Interval',
  '张数': 'Shots',
  '{m} 分 {s} 秒': '{m}m {s}s',
  '∞ 无限': '∞ unlimited',
  '开始': 'Start',
  '每拍等相机就绪再释放;单拍失败自动跳过,连续 3 拍失败自动停止':
      'Each shot waits for the camera to be ready; a failed shot is skipped, and the run stops after 3 consecutive failures',
  '间隔拍摄(延时摄影):设间隔与张数自动连拍;运行中点按立即停止':
      'Interval shooting (time-lapse): auto-captures at the set interval and count; tap while running to stop immediately',
  '暂停间隔拍摄(当前一拍完成后挂起)':
      'Pause interval shooting (holds after the current shot finishes)',
  '恢复间隔拍摄(间隔从恢复时刻重新起算)':
      'Resume interval shooting (the interval restarts from the moment you resume)',
  '停止间隔拍摄(立即;在途一拍落地后收口)':
      'Stop interval shooting (immediate; the in-flight shot still lands)',
};

/**
 * MtaConstants.ets — MTA 接收端协议常量
 *
 * 集中定义 MTA 协议涉及的全部常量：BLE 广播/GATT UUID、WebSocket 与下载路径、
 * 协议版本、WiFi Direct 默认网关、AES 参数、超时与安全上限。
 * 数值逐字节对齐 docs/mta 逆向结论，禁止在此之外散落魔法值。
 */

export class MtaConstants {
  // ── BLE 广播 ──

  /** 广播主 serviceUuid（MTA 发现标识，非标准基址 ...008123456789） */
  static readonly ADV_SERVICE_UUID: string = '00003331-0000-1000-8000-008123456789';
  /** 主广播 serviceData UUID（6 字节：设备 ID 前 6 字节） */
  static readonly ADV_DATA_UUID: string = '000001ff-0000-1000-8000-00805f9b34fb';
  /** 扫描响应 serviceData UUID（27 字节：设备 ID 尾段 + 设备名 + 0x01） */
  static readonly SCAN_RSP_UUID: string = '0000ffff-0000-1000-8000-00805f9b34fb';
  /** 主广播 serviceData 长度（字节） */
  static readonly ADV_DATA_LENGTH: number = 6;
  /** 扫描响应 serviceData 长度（字节） */
  static readonly SCAN_RSP_LENGTH: number = 27;
  /** 扫描响应中设备 ID 尾段起始偏移（[0..10) 承载设备 ID 第 6..16 字节，对齐厂商扫描端合并记录偏移 35..45 的读取口径） */
  static readonly SCAN_RSP_ID_TAIL_OFFSET: number = 0;
  /** 扫描响应中设备 ID 尾段长度（字节） */
  static readonly SCAN_RSP_ID_TAIL_LENGTH: number = 10;
  /** 扫描响应中设备名字段起始偏移 */
  static readonly SCAN_RSP_NAME_OFFSET: number = 10;
  /** 扫描响应中设备名字段长度（字节） */
  static readonly SCAN_RSP_NAME_LENGTH: number = 16;
  /** 发送者/设备 ID 长度（字节）：16 字节，对齐厂商逆向规格（主广播前 6 字节 + 扫描响应尾段 10 字节拼接还原） */
  static readonly SENDER_ID_LENGTH: number = 16;
  /** 扫描响应名称区可容纳的最大字节数（真机与参考实现同值 16；放不下时截到 15 字节并写 \t 截断标记） */
  static readonly DEVICE_NAME_MAX_BYTES: number = 16;
  /** 扫描响应名称区未用字节的填充值：真机广播实测均为 0x00（扫描端以首个 0x00 为名称终止符） */
  static readonly NAME_FIELD_PAD_BYTE: number = 0x00;
  /** 扫描响应名称被截断时紧随其后的截断标记（\t）：仅截断时写入，不作为填充 */
  static readonly NAME_FIELD_TRUNCATION_MARK: number = 0x09;
  /** 扫描响应末字节标记 */
  static readonly SCAN_RSP_TAIL_FLAG: number = 0x01;
  // ── GATT 凭据通道 ──

  /** GATT 服务 UUID */
  static readonly GATT_SERVICE_UUID: string = '00009955-0000-1000-8000-00805f9b34fb';
  /** CHAR_STATUS 特征 UUID（读 → DeviceInfo JSON） */
  static readonly CHAR_STATUS_UUID: string = '00009954-0000-1000-8000-00805f9b34fb';
  /** CHAR_P2P 特征 UUID（写 → P2pInfo JSON） */
  static readonly CHAR_P2P_UUID: string = '00009953-0000-1000-8000-00805f9b34fb';
  /** prepared write 会话缓冲上限（字节） */
  static readonly MAX_WRITE_BUFFER: number = 4096;
  /** DeviceInfo 兜底蓝牙 MAC（三方应用无法获取可靠真实蓝牙 MAC） */
  static readonly FALLBACK_MAC: string = '02:00:00:00:00:00';
  /**
   * 发送伴随外设 DeviceInfo 的公钥兜底占位（合法的 P-256 SPKI DER Base64，可被对端解析导入）。
   * 正常路径始终使用发送会话公钥（与 P2pInfo.key 同源）；仅当公钥意外缺失时以此占位，
   * 保证外设对外设备信息为合法可解析内容（本外设仅记录对端行为，不参与任何凭据解密）。
   */
  static readonly COMPANION_DEVICE_INFO_PUBLIC_KEY: string =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9pU9LLwYqKCiRiudao5ZG7JRIbkrYuKIJlWreEn1lqCleOXMFWgr46rxWGWZaDw2dNOuysq95qrG3B5kj+V/qQ==';
  /** DeviceInfo.catShare 版本标识（参考实现 CatShare 所用版本号） */
  static readonly CATSHARE_VERSION: number = 7;
  /** DeviceInfo.state 就绪值（读回该值表示对端可接收；非该值视为对端忙） */
  static readonly DEVICE_INFO_STATE: number = 0;
  /** DeviceInfo.reason 对端忙原因码：镜像占用 */
  static readonly PEER_BUSY_REASON_MIRROR: number = 1;
  /** DeviceInfo.reason 对端忙原因码：热点占用 */
  static readonly PEER_BUSY_REASON_HOTSPOT: number = 2;
  /**
   * 对端忙复读次数与间隔（毫秒）：对端读到「未就绪」时，其自身已先等待最多 4000ms 才应答
   * （协议 §3.2），故复读间隔取 4000ms 与之对齐——间隔过短会落在同一次未就绪窗口内空读；
   * 总窗约 12s 覆盖上一会话收尾残留与对端自行清忙所需时间，窗口用尽仍忙才收束。
   */
  static readonly PEER_BUSY_RETRY_MAX_ATTEMPTS: number = 3;
  static readonly PEER_BUSY_RETRY_INTERVAL_MS: number = 4000;
  /** P2pInfo 引导网络：GATT（参考实现手机对手机的缺省取值） */
  static readonly P2P_BOOT_NETWORK_GATT: number = 1;
  /** P2pInfo 主网络：WiFi P2P（参考实现手机对手机的缺省取值） */
  static readonly P2P_MAIN_NETWORK_WIFI_P2P: number = 1;
  /** P2pInfo 协议类型：MIOV HTTP（参考实现手机对手机的缺省取值） */
  static readonly P2P_PROTOCOL_MIOV_HTTP: number = 2;
  // ── 加解密 ──

  /** ECDH 曲线算法名 */
  static readonly ECC_ALGORITHM: string = 'ECC256';
  /** AES 算法名（AES-256-CTR，无填充） */
  static readonly AES_ALGORITHM: string = 'AES256|CTR|NoPadding';
  /** AES 对称密钥生成器算法名 */
  static readonly AES_SYM_ALGORITHM: string = 'AES256';
  /** AES 固定 IV 文本（16 字节 ASCII，非 8 字节） */
  static readonly AES_IV_TEXT: string = '0102030405060708';
  /** 共享密钥期望长度（字节，ECDH P-256 X 坐标） */
  static readonly SHARED_KEY_LENGTH: number = 32;
  // ── 网络端点 ──

  /** WebSocket 路径 */
  static readonly WS_PATH: string = '/websocket';
  /** WiFi Direct 默认 GO 网关地址（获取失败时兜底） */
  static readonly DEFAULT_GO_IP: string = '192.168.49.1';
  /** P2pInfo 未提供端口时的兜底端口 */
  static readonly DEFAULT_TRANSFER_PORT: number = 43210;
  // ── WS 应用层协议 ──

  /** 协议版本 */
  static readonly PROTOCOL_VERSION: number = 1;
  /** catShareText 随 sendRequest 走 WS 单帧传输的字节上限（超大文本仍可经 ZIP 文件条目完整发送） */
  static readonly MAX_SHARE_TEXT_BYTES: number = 256 * 1024;
  /** 协商 ack 中声明的线程上限 */
  static readonly THREAD_LIMIT: number = 5;
  /** 接收端主动消息 ID 起始值（MTA 协议 status 消息固定 99） */
  static readonly STATUS_MESSAGE_ID: number = 99;
  /**
   * 接收端 status 回执帧号：对齐可用的第三方实现（捷传）取 100。
   * 注意与 vivo 口径（99）不同；小米端实测接受 100 并判成功。
   */
  static readonly STATUS_MESSAGE_ID_RECEIVER: number = 100;
  /** status 成功类型 */
  static readonly STATUS_TYPE_OK: number = 1;
  /** status 拒绝类型 */
  static readonly STATUS_TYPE_REFUSE: number = 3;
  /** status 成功原因文本 */
  static readonly STATUS_REASON_OK: string = 'ok';
  /** status 拒绝原因文本 */
  static readonly STATUS_REASON_REFUSE: string = 'user refuse';
  /** 回送成功状态后等待发送方收尾的时间（毫秒，对端 MTA 设备收到后约 1s 删组停服） */
  static readonly STATUS_SETTLE_DELAY_MS: number = 1500;
  // ── 超时与安全上限 ──

  /** P2P 连接等待超时（毫秒） */
  static readonly P2P_CONNECT_TIMEOUT_MS: number = 15000;
  /** P2P 连接确认轮询间隔（毫秒，p2pConnectionChange 事件未达时兜底查询 P2P 链路状态） */
  static readonly P2P_POLL_INTERVAL_MS: number = 200;
  /** WS 单次连接尝试超时上限（毫秒，早期探测超时由此封顶） */
  static readonly WS_CONNECT_TIMEOUT_MS: number = 3000;
  /** WS 首次尝试的短探测超时（毫秒）：路径未就绪时快速失败后重试 */
  static readonly WS_PROBE_TIMEOUT_MS: number = 1000;
  /** 每次尝试的超时递增步长（毫秒，封顶 WS_CONNECT_TIMEOUT_MS，容忍较慢握手） */
  static readonly WS_PROBE_TIMEOUT_STEP_MS: number = 500;
  /** WS 连接失败后的重试间隔（毫秒） */
  static readonly WS_RETRY_DELAY_MS: number = 200;
  /** WS 连接总窗口（毫秒）：窗口内持续重试，超时才判定失败（取代固定等待与固定尝试次数） */
  static readonly WS_CONNECT_DEADLINE_MS: number = 20000;
  /** 版本协商完成后等待接收请求的超时（毫秒，对端静默失联时避免无限期卡死） */
  static readonly REQUEST_WAIT_TIMEOUT_MS: number = 30000;
  /**
   * 接收端等待用户确认接收的超时（毫秒）：须短于发送端 PEER_ACCEPT_TIMEOUT_MS（35000），
   * 使本端先回送拒绝状态、让发送端得到明确结果，而不是被对方单方拆链后再失败。
   */
  static readonly PEER_DECISION_TIMEOUT_MS: number = 30000;
  /** 接收下载连接超时（毫秒，作为参数传入 Rust 下载入口） */
  static readonly DOWNLOAD_CONNECT_TIMEOUT_MS: number = 30000;
  /** 接收下载停滞判定阈值（毫秒，作为参数传入 Rust 下载入口）：持续无新数据视为对端失联 */
  static readonly DOWNLOAD_STALL_TIMEOUT_MS: number = 30000;
  /** 接收下载等待响应头超时（毫秒，作为参数传入 Rust 下载入口）：连接建立后对端不返回响应头即失败 */
  static readonly DOWNLOAD_HEADER_TIMEOUT_MS: number = 30000;
  /** 接收端拉取发送端缩略图的字节上限（防滥用；超出即放弃预览，不影响接收） */
  static readonly MAX_THUMBNAIL_BYTES: number = 1024 * 1024;
  /** 接收端进入待确认界面前预取缩略图的等待预算（毫秒）：超时即放行，避免拖延提示弹窗 */
  static readonly THUMBNAIL_PREFETCH_BUDGET_MS: number = 600;
  /** 接收解压后允许的总大小上限（字节，防 zip bomb；作为参数传入 Rust；对端官方口径无大小限制，本上限仅作炸弹防线，落地前另有存储预留检查） */
  static readonly MAX_UNZIP_TOTAL_BYTES: number = 1024 * 1024 * 1024 * 1024;
  /** 接收单条目解压后允许的大小上限（字节，防 zip bomb；作为参数传入 Rust；同上，仅作炸弹防线） */
  static readonly MAX_UNZIP_ENTRY_BYTES: number = 256 * 1024 * 1024 * 1024;
  /** 接收解压后允许的条目数上限（防 zip bomb；作为参数传入 Rust；对齐对端文件数上限） */
  static readonly MAX_UNZIP_ENTRY_COUNT: number = 10000;
  /** 解压总量容差下限（字节）：对端声明总大小不可全信，允许在此额度内偏差 */
  static readonly UNZIP_TOLERANCE_MIN_BYTES: number = 1024 * 1024;
  /** 解压总量容差比例：允许声明值 1% 的额外偏差 */
  static readonly UNZIP_TOLERANCE_RATIO: number = 0.01;
  /** 对端声明总大小缺失/非正时的解压总量兜底上限（字节） */
  static readonly UNZIP_FALLBACK_TOTAL_BYTES: number = 1024 * 1024 * 1024;
  /** 落盘前要求的额外可用空间（字节，覆盖解压与元数据开销） */
  static readonly STORAGE_RESERVE_BYTES: number = 256 * 1024 * 1024;
  // ── 发送端：GATT Client ──

  /** 发送端 GATT 连接等待超时（毫秒，含状态事件等待） */
  static readonly GATT_CONNECT_TIMEOUT_MS: number = 10000;
  /** 发送端读取对端 DeviceInfo 等待超时（毫秒） */
  static readonly GATT_READ_TIMEOUT_MS: number = 8000;
  /** 发送端等待 GATT 连接就绪的轮询间隔（毫秒） */
  static readonly GATT_CONNECT_POLL_MS: number = 200;
  /** 发送端连接判定超时后的边界补判宽限（毫秒）：连接事件常在超时附近到达，避免误拆刚建立的链路 */
  static readonly GATT_CONNECT_FINAL_GRACE_MS: number = 500;
  /** 发送端 GATT 连接最大尝试次数（对端广播地址高频轮换，重扫取新地址后重试） */
  static readonly GATT_CONNECT_MAX_ATTEMPTS: number = 3;
  /** 发送端连接前按 senderId 重扫当前地址的短扫超时（毫秒） */
  static readonly GATT_ADDRESS_RESCAN_TIMEOUT_MS: number = 2000;
  /** 发送端写入 P2pInfo 后等待回调/返回超时（毫秒） */
  static readonly GATT_WRITE_TIMEOUT_MS: number = 8000;
  /**
   * 写回 P2pInfo 后复读对端信息的非阻塞诊断窗口（毫秒）：
   * 复读属诊断动作，超出该窗口即放弃采集，不阻塞等待对端入组等关键路径。
   */
  static readonly PEER_INFO_RECHECK_WINDOW_MS: number = 3000;
  /** 发送端 GATT Client 请求协商的 MTU（字节；默认 23 单次仅可写 20 字节，不足以写入 P2pInfo） */
  static readonly GATT_MTU_SIZE: number = 512;
  /** BLE 未协商时的默认 MTU（字节） */
  static readonly BLE_DEFAULT_MTU: number = 23;
  /** 等待 MTU 协商完成的超时（毫秒） */
  static readonly GATT_MTU_TIMEOUT_MS: number = 3000;
  /** 等待 MTU 协商完成的轮询间隔（毫秒） */
  static readonly GATT_MTU_POLL_MS: number = 100;
  /** 发送端服务发现最大尝试次数（服务发现偶发失败时重试） */
  static readonly GATT_DISCOVERY_MAX_ATTEMPTS: number = 3;
  /** 发送端服务发现重试间隔（毫秒） */
  static readonly GATT_DISCOVERY_RETRY_DELAY_MS: number = 400;
  // ── 发送端：WiFi Direct 建组 ──

  /** 发送端建组后等待群组信息就绪超时（毫秒） */
  static readonly GROUP_READY_TIMEOUT_MS: number = 20000;
  /** 发送端 5GHz 候选就绪探测上限（毫秒，超时即快速回退 2.4GHz，避免固定长等待） */
  static readonly GROUP_READY_TIMEOUT_5GHZ_MS: number = 3000;
  /**
   * 发送端建组就绪的事件兜底轮询步长（毫秒）：以 P2P 连接/群组事件为主判据，
   * 事件缺失时仅以此短步长兜底，避免固定长步长给每次建组引入额外等待。
   */
  static readonly GROUP_READY_FALLBACK_POLL_MS: number = 100;
  /**
   * 发送端建组前等待上一会话残留群组消失的有界超时（毫秒）：确认旧组已拆除，
   * 避免平台因旧组仍在而忽略本次建组；超时未消失不阻断建组，改由建组身份校验兜底。
   */
  static readonly GROUP_RESIDUAL_CLEAR_TIMEOUT_MS: number = 3000;
  /**
   * 发送端建组身份在单个候选频段内的最大尝试次数（有界）：就绪组名与本次请求组名不匹配
   * （如上一会话残留组）时清理并重新建组；各次尝试共用该候选的就绪超时预算，不叠加成长等待。
   */
  static readonly GROUP_CREATE_IDENTITY_MAX_ATTEMPTS: number = 2;
  /** WiFi Direct 群组名前缀 */
  static readonly GROUP_NAME_PREFIX: string = 'DIRECT-';
  /** WiFi Direct 群组口令长度（字符） */
  static readonly GROUP_PASSPHRASE_LENGTH: number = 8;
  /** 群组信息查询"当前无群组"错误码 */
  static readonly GROUP_NOT_FOUND_CODE: number = 2801000;
  /** 群主频段：2.4GHz（对端不支持 5GHz 或为 Samsung 时使用，也是 5GHz 建组失败后的回退频段） */
  static readonly GROUP_OWNER_BAND_2GHZ: number = 1;
  /** 群主频段：5GHz（非 Samsung 且对端支持 5GHz 时显式优先请求，值对齐 GroupOwnerBand.GO_BAND_5GHZ） */
  static readonly GROUP_OWNER_BAND_5GHZ: number = 2;
  /** 5GHz 建组限定频点（MHz，取非 DFS 常用信道 36；成立时以频率为准） */
  static readonly GROUP_5GHZ_FREQUENCY_MHZ: number = 5180;
  /** 2.4GHz 频点区间下界（MHz） */
  static readonly FREQUENCY_2GHZ_MIN: number = 2400;
  /** 2.4GHz 频点区间上界（MHz） */
  static readonly FREQUENCY_2GHZ_MAX: number = 2500;
  /** 5GHz 频点区间下界（MHz） */
  static readonly FREQUENCY_5GHZ_MIN: number = 4900;
  /** 5GHz 频点区间上界（MHz） */
  static readonly FREQUENCY_5GHZ_MAX: number = 5900;
  // ── 发送端：TLS 服务器 ──

  /** 发送端默认端口（0 = 由系统随机分配） */
  static readonly DEFAULT_SEND_PORT: number = 0;
  /** bindIp 绑定失败时的兜底绑定地址 */
  static readonly DEFAULT_BIND_IP: string = '0.0.0.0';
  /** 启动 Rust 服务器等待超时（毫秒，仅覆盖端口绑定与 TLS 初始化；ZIP 由响应体流式生成） */
  static readonly SERVER_START_TIMEOUT_MS: number = 10000;
  /** P2pInfo 写回后等待对端 WS 连接的超时（毫秒，覆盖对端解密凭据、p2pConnect 入组与 WS 握手重试链路的最大时长） */
  static readonly WAITING_WS_TIMEOUT_MS: number = 60000;
  /** 传输阶段无进展看门狗阈值（毫秒，对端静默消失时兜底终止；不缩短 Rust 侧状态等待超时以免误伤慢速大文件） */
  static readonly TRANSFER_STALL_TIMEOUT_MS: number = 30000;
  /**
   * 发送端等待对端开始接收的窗口（毫秒）：已发出 sendRequest 且对端尚未发起下载时生效，
   * 覆盖对端用户确认窗口后判定对方未接收，避免干等到 Rust 侧 180s 状态等待超时。
   */
  static readonly PEER_ACCEPT_TIMEOUT_MS: number = 35000;
  /**
   * 取消后等待对端被通知的上限（毫秒）：对端尚未接入会话通道时保留链路并等待其接入，
   * 接入即回送取消状态并提前结束等待；到期仍未接入则按「未能通知对端」收尾，不无限期停留。
   */
  static readonly CANCEL_NOTIFY_WAIT_TIMEOUT_MS: number = 10000;
  // ── 发送端：WS 应用层消息 ID ──

  /** 发送端 sendRequest 消息 ID */
  static readonly WS_SEND_REQUEST_ID: number = 1;
  // ── 发送端：上限与进度 ──

  /** 发送端 ZIP 条目数上限（对齐对端文件数上限） */
  static readonly MAX_SEND_ENTRY_COUNT: number = 10000;
  /**
   * 大文件提示阈值（字节）：总大小或单文件达到该值时提示用户大文件传输可能失败，
   * 仅提示、不拦截（功能上限已取消；防 zip bomb 安全上限不受影响）。
   */
  static readonly LARGE_FILE_WARN_BYTES: number = 10 * 1024 * 1024 * 1024;
  /** 发送进度节流间隔（毫秒） */
  static readonly PROGRESS_THROTTLE_MS: number = 200;
  // ── 发送端：预览缩略图 ──

  /** 预览缩略图目标框宽度（像素；等比缩放不放大，与参考实现观测值一致） */
  static readonly SEND_THUMBNAIL_MAX_WIDTH: number = 240;
  /** 预览缩略图目标框高度（像素） */
  static readonly SEND_THUMBNAIL_MAX_HEIGHT: number = 320;
  // ── 发送端：品牌 / 会话 ──

  /** 第三方品牌 ID（P2pInfo/Broadcast 中的标识） */
  static readonly BRAND_ID_THIRD_PARTY: number = 0xff;
  /** Rust 侧日志轮询间隔（毫秒，用于在发送页展示服务器/TLS/WS 诊断日志） */
  static readonly RUST_LOG_POLL_MS: number = 500;
  /** 等待对端入组时的群组客户端数轮询间隔（毫秒） */
  static readonly GROUP_CLIENT_POLL_MS: number = 1000;
  /**
   * 等待确认阶段判定「对端已退出本次 P2P 组」所需的连续归零观测次数。
   * 取值 2：轮询间隔为 1s，连续 2 次（约 1~2s）均观测到客户端数归零或群组信息不可得才判放弃，
   * 用于吸收系统瞬时重连或单次读数抖动，避免把短暂波动误判为对端放弃。
   */
  static readonly GROUP_CLIENT_ZERO_STREAK_LIMIT: number = 2;

  /**
   * 按品牌标识生成主广播 serviceData UUID：品牌字节取 brandId 低 8 位的两位小写十六进制。
   * 默认第三方（0xff）时返回值等于 ADV_DATA_UUID，保证零回归。
   */
  static mainAdvDataUuidForBrand(brandId: number): string {
    let hex = (brandId & 0xff).toString(16);
    let brandHex = hex.length === 1 ? '0' + hex : hex;
    // 复用主广播 UUID 的固定后缀，仅替换品牌字节段（前 8 字符为 `000001xx`）
    return `000001${brandHex}${MtaConstants.ADV_DATA_UUID.substring(8)}`;
  }

  /** 构造 AES 固定 IV 的字节数组（每次返回独立实例，避免被外部修改） */
  static aesIvBytes(): Uint8Array {
    let bytes = new Uint8Array(MtaConstants.AES_IV_TEXT.length);
    for (let i = 0; i < MtaConstants.AES_IV_TEXT.length; i++) {
      bytes[i] = MtaConstants.AES_IV_TEXT.charCodeAt(i);
    }
    return bytes;
  }
}

# MacHello-0592WK AI Agent 指导规范 (AGENT.md)

> **目标受众**：面向所有接手本仓库的 AI Coding Agent。  
> **项目定位**：**原生 macOS 菜单栏应用 (Native Menu Bar App)**。  
> **设计哲学**：**拒绝臃肿的 Python 运行时与大库**。采用 **Swift (SwiftUI / AppKit) 原生开发**，极致轻量（体积仅数 MB、内存占用 < 20MB）、0 多余臃肿依赖、无缝调用 Apple Silicon Neural Engine (NPU) 与硬件级红外控制。

## 🖥️ 实测系统与运行环境规范 (Verified System Environments)

本项目经过全链路闭环联调，并已在以下真实生产环境中完成全功能验证：

| 节点维度 | 操作系统版本 | 硬件架构 / 宿主拓扑 | 关键环境参数与角色定位 |
| :--- | :--- | :--- | :--- |
| **🍎 Mac 客户端 (业务与大脑端)** | **macOS 27.0** (Build `26A428`) | Apple Silicon (ARM64e / M 系列芯片) | - **业务与识别大脑**：统一调用 Apple Vision 框架，算力 100% 运行于苹果 **16 核神经网络引擎 (Apple Neural Engine, ANE / NPU)**；<br>- 走局域网内存管道流转图像，**状态栏 0 绿色隐私圆点，0 MenuBarAgent 冲突**。 |
| **🐧 Linux 网关 (硬件数据源端)** | **Debian GNU/Linux 13** (`trixie` / 13.1) | Proxmox VE (PVE) 虚拟化环境<br>内核: `7.0.12-1-pve x86_64` | - **Samba 式纯硬件网关**：USB 直通共享 Dell 0592WK (`0bda:5767`)；<br>- 负责 UVC XU 控制序列与按需提供 MJPEG 画面，平时相机释放彻底灭灯，**整机 CPU 占用 0.0%**。 |

---

## 1. 软件形态与用户体验规范 (CRITICAL REQUIREMENTS)

1. **外观形态 (Menu Bar Only)**：
   - 必须配置 `LSUIElement = true`（即 Agent / 纯状态栏应用）。
   - **Dock 栏（Taskbar）禁止显示任何图标**。
   - 仅在屏幕右上角系统菜单栏（Menu Bar）驻留一个精致的图标（类似 macOS 原生 Face ID 轮廓小图标）。
   - 点击菜单栏图标弹出原生控制面板：
     - 当前设备连接状态（🟢 戴尔 0592WK 已就绪 / 🔴 未连接）
     - 人体感应总开关（走开息屏 / 来人亮屏）
     - 视频观影/在线会议免打扰（实时状态指示：🟢 运行中透传来源 App，如 `Google Chrome` / ⚪ 待命中）
     - 机主专属防窥鉴权模式（仅限机主本人才亮屏）
     - 离席等待时长（10秒/15秒/30秒/60秒）
     - 🌙 红外硬件测试（手动点亮/熄灭测试）
     - 📸 录入新面孔（Face Enrollment）
     - 🚪 退出应用
2. **后台常驻与开机启动**：
   - 使用现代 macOS 原生 `SMAppService.mainApp.register()` 管理开机无感自启。
3. **自动化打包与无缝热替换开发工作流 (HOT REPLACEMENT WORKFLOW - CRITICAL)**：
   - 每次代码改动并通过测试（`swift test`）后，打包生成 `.app`；
   - 必须通过 `./scripts/package-app.sh --install` 完成闭环：**自动平滑退出当前旧版 App 进程（`killall MacHello`） -> 将新 App 安装到 `/Applications/MacHello.app` -> 重新启动新 App (`open /Applications/MacHello.app`)**，确保用户无缝测试最新构建，严禁遗留未安装的构建或要求用户手动操作。
4. **双部署工作模式架构规范 (DUAL DEPLOYMENT MODES)**：
   - **🔌 本机 USB 直连模式 (Local BLEUnlock Mode)**：
     - 当摄像头直接插在 Mac 上时，遵循 [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) 的纯净规范：平时亮屏工作与静止阅读期间，摄像头 **100% 保持彻底断电关闭**，0% CPU，状态栏 0 绿色隐私指示灯；
     - 纯键鼠无操作超时（15秒/30秒/1分钟/5分钟/10分钟）自动锁屏/息屏；
     - 用户触动键鼠亮屏时，由 `AutoAuthManager` 毫秒级捕获唤醒通知，**瞬间启动摄像头 0.5 秒完成 Face ID 刷脸并自动输入密码进入桌面，随后立即关闭相机**；
     - 终端 `sudo` 与管理员弹窗同样单次 0.5 秒刷脸，彻底根绝 macOS 27 菜单栏的任何性能与隐私指示器冲突。
   - **🌐 局域网 Linux 智能服务模式 (Network Linux Mode)**：
     - 摄像头插在局域网 Linux 设备（软路由/树莓派/NAS/工控机等）上，运行 `linux-server/machello_server.py`；
     - Linux 端无 macOS 隐私指示器限制，全天候 24/7 运行人体存在感应（HPD）、Windows Hello 15Hz 物理交替频闪活体算法与 MJPEG 红外夜视监控流；
     - Mac 端通过 `LinuxPresenceClient`（WebSocket）实时监听在席广播：**人走开 Mac 自动息屏、人靠近 Mac 自动唤醒并秒级刷脸进桌面**；
     - **Mac 端 0 摄像头调用、0 状态栏绿点、0 视频解码负担，Mac CPU 占用绝对 0.00%**！局域网内任意终端还可拉取实时红外夜视监控流。

---

## 2. 核心技术栈与架构

| 模块 | 选用技术栈 | 选型优势 (为什么不用 Python) |
| :--- | :--- | :--- |
| **编程语言** | **Swift 5.9+ / Swift Package Manager (SPM)** | 编译为原生机器码，无 Python/Conda 解释器开销，双击即用 |
| **GUI 架构** | **SwiftUI + AppKit (`NSStatusItem` / `MenuBarExtra`)** | 原生 macOS 视觉规范，极低资源占用 |
| **视频采集** | **AVFoundation (`AVCaptureSession`)** | 苹果官方原生相机框架，硬解 720P 零 CPU 占用，免驱动 |
| **红外控制** | **IOKit (`IOUSBDeviceInterface`) 或轻量 `CIOKitHelper` C 绑定** | 直接向 USB `0bda:5767` 发送 5 步 UVC XU 控制传输 |
| **人脸特征与活体** | **Apple Vision Framework (`VNCreateFaceprintRequest`) + CoreML** | **系统原生内置，0 外部依赖**！直接调用 Apple Silicon 统一内存与 NPU (ANE) 加速，比对仅需 5ms |
| **电源与屏幕管理** | **`pmset displaysleepnow` + `IOPMAssertionDeclareUserActivity`** | 纯显示屏黑屏/亮屏，不影响主机 CPU 和后台进程 |
| **键鼠活跃感知** | **`CGEventSource.secondsSinceLastEventType`** | 零开销获取系统键鼠最后活动时间，打字期间关停摄像头熄灯 |
| **媒体观影探测** | **`IOPMCopyAssertionsStatus`** | 感知 YouTube/视频/会议电源断言，观影时相机静默、屏幕常亮 |
| **全场景免密授权** | **macOS Keychain + `cghidEventTap`** | 密码加密存入系统钥匙串，红外验证通过后秒级填入弹窗与锁屏 |

---

## 3. 继承自 Linux 的硬件协议真值 (严禁重头摸索)

我们在 Linux 环境下已对 **Dell CN-0592WK (0bda:5767)** 进行了 100% 协议逆向验证。Swift 驱动层直接复用这套已验证的状态机：

- **USB 硬件定位**：VendorID: `0x0bda`, ProductID: `0x5767`
- **模组架构与传感器特性 (CRITICAL)**：
  - 本模组为**硬件双目模组**（板载独立的 RGB 彩色镜头 + IR 红外镜头 + 红外补光灯珠）。
  - **RGB 模式**：支持 720P (1280x720 MJPEG) 等彩色格式。
  - **IR 模式**：**硬件传感器固定为 640x480 YUY2 (未压缩原始数据流)**。切换至 IR 模式时必须同步将视频流协商/裁剪至 640x480，严禁在 720P 流进行中直接切 IR（会导致固件忽略切换或死锁）。
  - **微软 Windows Hello 15Hz 频闪脉冲机制 (CRITICAL DISCOVERY)**：
    - 硬件主控遵循微软 `KSCAMERA_EXTENDEDPROP_FACEAUTH_MODE_ALTERNATIVE_FRAME_ILLUMINATION`；
    - **偶数帧 (2, 4, 6...)**：850nm 红外发射管点亮，产生约 55KB 高质图像（包含人体红外反射 + 环境光）；
    - **奇数帧 (3, 5, 7...)**：850nm 发射管熄灭，产生约 26KB 图像（仅环境光，暗室下全黑）；
    - **活体防伪判断**：人体皮肤反射调制深度显著 ($\Delta \ge 0.08$)，电子屏幕/纸张照片由于发光恒定 $\Delta \approx 0$，直接被活体拦截；
    - **环境光差分去噪**：调用 `CISubtractBlendMode` 执行 $I_{\text{clean}} = \max(0, I_{\text{lit}} - I_{\text{ambient}})$ 即可消除逆光和强眩光；
    - **单帧秒开**：软件识别层与 15Hz 频闪同步对齐，直接取第 2 帧偶数黄金帧（66ms），实现闪电解锁。
- **指示灯与硬件隐私 Interlock 说明**：
  - 模组上的白色/绿色微型指示灯是硬件直连 CMOS 供电电路的隐私指示灯，软件无法直接关断；
  - 最佳解决方案为：**键鼠活跃时 100% 停止摄像头（灯全灭），键盘鼠标停顿超时后才开启 0.5 秒探测一次，息屏后采用 2~3 秒脉冲巡检**。
- **UVC Extension Unit 属性**：
  - **Unit ID**: `0x04`
  - **XU Selector 0x0A**: 写入寻址/复位
  - **XU Selector 0x0B**: 读写模式数据
  - **模式寄存器**: `0x9f00`。其中 **`0x00` 代表开启红外 (IR ON)**，**`0x01` 代表开启可见光 (RGB ON)**。
- **5 步 USB 控制传输报文 (Control Transfer)**：
  - `bmRequestType = 0x21` (Host to Device, Class, Interface)
  - `bRequest = 0x01` (UVC_SET_CUR) / `0x81` (UVC_GET_CUR)
  - `wValue = (CS << 8)` (CS = 0x0A 或 0x0B)
  - `wIndex = (Unit 4 << 8) | InterfaceNum`
  - 步骤序列：
    1. CS `0x0a` -> `SET_CUR` -> `[0xff, 0, 0, 0, 0, 0, 0, 0]` (复位)
    2. CS `0x0a` -> `SET_CUR` -> `[0x00, 0xfb, 0, 0, 0x05, 0, 0, 0]` (选址 0xfb00)
    3. CS `0x0b` -> `GET_CUR` -> 读取握手状态
    4. CS `0x0a` -> `SET_CUR` -> `[0x00, 0x9f, 0, 0, 0x01, 0, 0, 0]` (选址 0x9f00)
    5. CS `0x0b` -> `SET_CUR` -> `[mode_byte, 0, 0, 0, 0, 0, 0, 0]` (写入模式)

---

## 4. 关键安全与硬件保护守则

1. **红外灯物理寿命保护 (Safe Guard)**：
   - 红外 LED 发射管功率较高，**绝对禁止无节制常开**；
   - 每次认证触发时点亮红外，完成抓拍比对后（或超时 3 秒后），**必须在 Swift 的 `defer` 块中无条件将硬件切回可见光 RGB 模式（`mode_byte = 0x01`）**。
2. **菜单栏防止高频重绘 (Menu Bar Throttle)**：
   - 禁止在相机每一帧回调中修改 `@Published` 属性，必须使用差分比对（仅当状态发生布尔反转或实际改变时才发射事件），防止 macOS `NSMenu` 子菜单发生高频销毁与闪烁。
3. **免密提权防死锁**：
   - PAM 模块若在 3 秒内未比对到人脸或发生摄像头异常，必须立即返回 `PAM_AUTH_ERR` 并退回到原生密码输入，严禁卡死系统终端。
4. **macOS 15 Sequoia 锁屏按键注入与安全时序规范 (Lock Screen Timing Guard)**：
   - **锁屏动效避让 (1.2s)**：macOS 锁屏（`Cmd + Ctrl + Q`）有约 800ms~1000ms 的动画转场。在此期间 `loginwindow` 不接受按键输入。必须等待 1.2 秒后才执行识别与按键注入，防止按键掉入动画黑洞；
   - **严禁使用 `Esc`**：Sonoma/Sequoia 锁屏下，按 `Esc` 会把密码框收起隐藏。唤醒密码框应使用安全的 `Shift` (0x38) 激活，配合 `Cmd+A` 与 `Delete` 清理旧输入；
   - **必须注入纳秒绝对时戳**：macOS 15 对 `CGEvent` 施加了严格校验，每个模拟按键必须附加 `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`，否则会被系统 WindowServer 静默丢弃；
   - **双键回车落地**：模拟发送主键盘 Return (`0x24`) 与 Enter (`0x34`) 确保各布局均能触发登录。
5. **规范化存储目录架构 (Zero Pollution Guard)**：
   - 严禁将调试抓图或历史数据写入源码目录或硬编码开发者个人路径；
   - 严格统一存储在用户主目录 `~/.machello/`：
     - 人脸模型库：`~/.machello/faces.json`
     - 通行审计日志与抓拍：`~/.machello/history/`（滚动最多 50 张）
     - 硬件自检与诊断输出：`~/.machello/diagnostics/`
6. **物理热拔断连容错 (Fail-Safe Disconnect Guard)**：
   - 当 `!irController.isConnected` 时，`checkAbsenceStatus` 必须无条件跳过熄屏逻辑，并不断刷新 `lastSeenOwnerTime`，严禁在无摄像头状态下锁死或息屏用户屏幕。系统平滑降级，交还 macOS 原生电源管理。
7. **macOS 27 MenuBarAgent / 系统隐私指示器防高频震荡规范 (Scene Churn & Spin-Lock Guard)**：
   - 在 macOS 27 及更高版本中，菜单栏被独立为 `/System/Library/CoreServices/MenuBarAgent.app`，当摄像头启闭时，系统 `ControlCenter` 会通过 XPC 通知 `MenuBarAgent` 挂载/卸载 FrontBoard 隐私横幅 Scene；
   - **严禁每隔数秒机械式高频 `start()` / `stop()` 摄像头**：频繁创建/销毁 Scene 会引发 SkyLight 结构树（`_XAddStructuralRegionOfType`）严重内存/对象泄漏与 `NSSceneFenceAction` 自旋死锁，导致 `MenuBarAgent` 与 `WindowServer` 双双飙至 100% CPU，造成全局掉帧卡死（参见开源项目 `jizhi0v0/macos27-beta-issues` Issue #12, #20, #22）；
   - **正确的在席监护策略**：
     - 用户打字/鼠标操作时彻底关停相机，0% CPU，指示灯全灭；
     - 用户停手静置（阅读/思考）期间，平稳开启相机常驻，绿点保持稳态无 Scene Churn；
     - 通过动态自适应帧率：机主在位巡航时降频至 1.0 FPS 抽帧，Vision 算力消耗 < 0.2%，离开超时后才熄屏灭灯；
     - 息屏休眠巡检采用 8 秒长周期轻柔脉冲，保护硬件同时降低系统合成管道冲击。
8. **锁屏与密码按键模拟绝对安全铁律 (Zero Password Leakage Guard - CRITICAL)**：
   - **真锁屏机制**：无操作超时必须调用 `SACLockScreenImmediate()`（调用 macOS `login.framework` 原生接口），确保系统真正且立刻切入 `loginwindow` 锁屏状态，严禁仅调用 `pmset displaysleepnow`（单纯息屏未锁屏会导致按键泄露至桌面应用）；
   - **模拟键入绝对双重核验**：
     - 若为锁屏解锁（`.lockScreen`），**必须在发送按键前严格多重校验 `isScreenLocked() == true`**。一旦检测到当前不在锁屏界面（已处于普通桌面窗口），必须立即熔断、绝对严禁发送任何按键，坚决防止密码被打入终端或聊天对话框；
     - 若为管理员弹窗提权（`.adminPrompt`），**必须严格核验前台应用确系 `com.apple.SecurityAgent`**。如果不是，坚决拒绝模拟按键。
9. **外设即插即用与热插拔自愈 (USB Hotplug & Device Discovery)**：
   - 监听 `AVCaptureDevice.wasConnectedNotification` 与 `wasDisconnectedNotification`，并配合每秒硬件状态心跳探测；
   - 保证用户在应用启动之后随时插入或拔出摄像头时，系统能在 300ms 内自动识别、重置硬件到 RGB 就绪状态并刷新菜单状态，严禁要求用户手动杀死进程重启。
10. **红外灯物理保护与按需闪烁铁律 (IR LED Power & Thermal Guard - CRITICAL)**：
   - **严禁 24 小时常开 850nm 红外发射管**：Dell 0592WK 为紧凑型笔记本拆机模组，红外发射管高功率常亮会导致严重发热、加速 LED 光衰，且在夜间刺眼；
   - **常态在位巡检必须运行在 RGB 模式**：通过调用 Realtek XU 模式 `0x01`（`set_mode(False)`），物理切断红外发射管供电，实现 0 发热、0 刺眼、纯被动监测；
   - **红外灯仅允许瞬时脉冲**：仅在黑夜弱光检测、刷脸识别核验或主动调试时，触发 0.5s 短促脉冲 (`pulse_ir`)，核验完成后立即物理切回 RGB 熄灭红外灯。
11. **局域网数据源 Samba 式抽象准则 (Samba-Style Data Source Abstraction - CRITICAL)**：
   - **Linux 端定位于纯硬件数据源**：严禁在 Linux 端编写业务判定逻辑（如粗暴人脸识别或是否开门的决策）；闲时按需释放摄像头灭灯，0% CPU；
   - **Mac 端统一接管大脑算力**：局域网流转的画面帧在 Mac内存中无缝转为标准 `CVPixelBuffer` / `CMSampleBuffer`，全部喂入 Mac 端的 **Apple Vision 框架与 Apple Neural Engine (NPU)** 进行 512 维特征比对；
   - **100% 复用所有核心业务**：本机直连与局域网模式仅在“数据源获取方式”上不同，下游的面容库比对（`~/.machello/faces.json`）、录入向导、双目自检向导与审计日志 100% 完全复用，确保极致的安全与优雅解耦。
12. **Dell 0592WK 硬件双目分辨率与 FOURCC 规范 (Dual-Lens Resolution & Pixel Format Standards - CRITICAL)**：
   - **RGB 模式**：传感器物理输出 `1280x720`，FOURCC 为 `MJPG`。在 Linux V4L2 环境下若错误配置为 640x480，驱动层会直接降级返回灰度红外传感器画面；
   - **IR 模式**：红外物理传感器原生输出 `640x480`，FOURCC 为 `YUYV`；
   - Linux 网关服务端（`machello_server.py`）必须支持在切换模式时动态平滑重置相机分辨率与 FOURCC 格式，并丢弃头 3 帧曝光建立期的坏帧，保证 RGB 全彩与红外高反差无缝切换。
13. **摄像头安装朝向与刚体旋转规范 (Camera Inversion & Rigid 180° Rotation Standards - CRITICAL)**：
   - **适配多场景安装**：默认为标准显示器上方正向安装；针对倒贴在显示器下方的场景，提供“摄像头倒置安装模式”开关（持久化于 `UserDefaults`：`com.machello.isCameraInverted`）；
   - **严禁单纯垂直镜像 (Single Axis Flip)**：单纯 Y 轴镜像会导致左右手性反转，面容录入向导时“向左微转头”和“向右微转头”会彻底颠倒；
   - **必须执行严格 2D 刚体 180° 旋转 (Rigid 180° Euclidean Rotation)**：同时翻转 X 轴与 Y 轴（`translateBy(w, h)` + `scaleBy(-1.0, -1.0)` 或原生硬件 `conn.videoRotationAngle = 180.0`），保证画面手性不变、左右/上下完全符合真实物理空间，确保 Apple Vision 的人脸姿态（`yaw` 偏航角与 `pitch` 俯仰角）100% 精准匹配；
   - **局域网快照自动适配**：在席感应静态快照解析管道自动传入 `CGImagePropertyOrientation.down`，实现锁屏全天候全自动识别。

---

## 5. 项目工程组织结构

```text
MacHello-0592WK/
├── AGENT.md                 # 本文件：AI Agent 规范与硬件真值协议
├── README.md                # 面向用户的开源文档
├── Package.swift            # 纯 Swift 现代工程配置 (SPM)
└── Sources/
    ├── MacHello/            # App 入口与菜单栏界面 (SwiftUI / AppKit)
    │   ├── MacHelloApp.swift
    │   ├── Controllers/     # 窗口控制器 (向导/录入/自检/审计历史)
    │   └── Views/           # SwiftUI 界面 (录入环形向导/双目自检/通行审计历史)
    ├── MacHelloCore/        # 核心逻辑
    │   ├── Hardware/        # IOKit USB 5步握手
    │   ├── Capture/         # AVFoundation 摄像头采集 (RGB 720P / IR 640x480)
    │   ├── Power/           # 屏幕电源控制 (pmset / IOPM) 与媒体播放断言探测
    │   ├── Input/           # 键鼠空闲时间感知 (CGEventSource)
    │   ├── Presence/        # 人体存在感应 (HPD 走开息屏/机主亮屏/即达即关)
    │   ├── Recognition/     # Apple Vision 人脸特征向量、环境光差分与15Hz频闪活体防伪
    │   └── Security/        # 全场景 Face ID (钥匙串/辅助功能按键/提示音/通行审计中心)
    └── MacHelloPAM/         # PAM 动态链接库模块 (C / Swift)
```

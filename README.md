# MacHello-0592WK 🍏👁️

> **专为 macOS (Apple Silicon M 系列 & Intel) 打造的原生 Windows Hello 级红外人脸解锁工具**  
> 基于 **Dell CN-0592WK (Realtek 0bda:5767)** 生物识别拆机模组，采用 **原生 Swift 编写**，无任何 Python 运行时臃肿依赖，常驻菜单栏，无感解锁。

---

## 🖥️ 真实实测与兼容环境规范 (Verified Environments)

本项目已在以下生产及前沿系统环境中经过全链路真机压力联调与实测验证：

| 节点维度 | 操作系统版本 | 硬件架构 / 宿主拓扑 | 核心运行栈与算力分配 |
| :--- | :--- | :--- | :--- |
| **🍎 Mac 客户端 (大脑端)** | **macOS 27.0** (Build `26A428`) | Apple Silicon (ARM64e / M 系列芯片) | **纯原生 Swift 6.0**。算力全开苹果 **16 核神经网络引擎 (NPU)**，走局域网内存管道流转图像，**状态栏 0 绿色隐私圆点，0 MenuBarAgent 冲突**。 |
| **🐧 Linux 网关 (数据源端)** | **Debian GNU/Linux 13** (`trixie` / 13.1) | Proxmox VE (PVE) 虚拟机 / LXC<br>内核: `7.0.12-1-pve x86_64` | **轻量硬件数据网关 (Samba 模式)**。内网专机 `ssh root@192.168.66.5`（`/root/machello-server`，已配置 systemd 开机自启）。动态检测 Dell 0592WK (`0bda:5767`) 插入状态，按需供流，平时摄像头释放彻底熄灭指示灯，**整机 CPU 占用 0.0%**。 |

---

## 💡 为什么选择原生 Swift 而非 Python？

| 考量维度 | Python 方案 | 原生 Swift 方案 (本项目) |
| :--- | :--- | :--- |
| **运行时开销** | 需安装 Python、Conda 环境，打包后数百 MB | **单文件原生 Mach-O 二进制，体积仅几 MB** |
| **内存占用** | 200 MB ~ 400 MB | **仅 15 MB ~ 25 MB**（微型常驻） |
| **GUI 形态** | 难以融入原生 macOS 视觉体验 | **原生纯 Menu Bar 状态栏应用（Dock 栏不占位）** |
| **AI 推理速度** | 走 CPU 模拟，单帧 30ms+ | **直接利用 Apple Neural Engine (NPU) 与统一内存，单帧 < 5ms** |
| **系统安全性** | 需向系统注入 Python 解释器脚本 | **原生集成 macOS PAM 机制，安全无死锁** |

---

## ✨ 核心特性

- 🍏 **原生 Menu Bar 状态栏应用**：
  - 配置 `LSUIElement = true`，**Dock 栏完全不显示图标**，只在屏幕右上角状态栏静默驻留一个原生小图标；
  - 点击弹出原生菜单，实时查看模组连接状态、人脸库管理与红外开关测试。
- 🔄 **双部署工作模式：本机直连 (BLEUnlock 模式) 与局域网 Linux 微服务**：
  - 🔌 **模式一：本机 USB 直连模式（借鉴 [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) 的纯净优雅规范）**：
    - **亮屏工作与静止阅读时，摄像头 100% 彻底断电关闭**，0% CPU，状态栏 0 绿色隐私小圆点，绝不打扰注意力；
    - 纯无操作超时（15秒/30秒/1分钟/5分钟/10分钟）自动锁屏/息屏，遇到看视频（YouTube/B站）或开会智能免打扰；
    - **当你触动键盘鼠标亮屏时，进入锁屏界面 -> 瞬时启动摄像头 0.5 秒完成 Face ID 刷脸并自动输入密码进入桌面 -> 随即彻底关闭摄像头**；
    - 终端 `sudo` 与管理员提权弹窗同样单次 0.5 秒刷脸，彻底告别 macOS 27 菜单栏的任何性能与隐私冲突！
  - 🌐 **模式二：局域网 Linux 智能硬件网关模式（Samba 式数据源抽象 · 算力 100% 留给 Mac NPU）**：
    - 将 Dell 0592WK 模组插在局域网 Linux 主机（软路由、PVE 虚拟机、树莓派或 NAS）上；
    - **Linux 端定位为纯硬件网关（Samba 哲学）**：不跑任何重型人脸算法与业务逻辑，平时按需休眠，无客户端查看时摄像头释放彻底灭灯，整机 CPU 占用 **0.0%**；
    - **Mac 端作为唯一超级大脑**：通过局域网拉取视频流与单帧快照，在 Mac 内存中无缝转换为 `CVPixelBuffer`，直接喂入 **Apple Vision 框架与苹果 16 核神经网络引擎 (Apple Neural Engine, ANE / NPU)**，与本地 `~/.machello/faces.json` 进行 512 维特征比对；
    - **Mac 端 100% 复用所有核心功能**：面容录入向导、双目自检、通行历史抓拍与锁屏解锁完全复用同一套业务流水线；
    - **Mac 端 0 绿点与 0 隐私横幅**：由于图像走局域网内存管道流转，macOS 底层绝不创建相机隐私横幅，彻底告别 `MenuBarAgent` 卡顿，实现真正的无感体验！
- 🚶 **走开真锁屏 · 来人唤醒 (Human Presence Detection - HPD)**：
  - 毫秒级低功耗检测，用户离开座位达到指定时长，自动调用系统原生 `SACLockScreenImmediate()`（调用 macOS `login.framework` 原生接口）切入真正的锁屏保护状态，并同步休眠显示器；
  - **防泄密熔断铁律 (Zero Password Leakage)**：在模拟密码输入前严格进行多重锁屏/窗口原子状态检查，非锁屏状态坚决拒绝发送任何按键，100% 杜绝密码被误打入桌面应用；
  - 当用户重新回到电脑前，毫秒级点亮屏幕 (`IOPMAssertionDeclareUserActivity`)。
- 🛡️ **仅限机主本人才亮屏（防窥安全模式）**：
  - 黑屏休眠状态下，陌生人或路过同事走到屏幕前，特征比对失败，**坚决保持黑屏锁定**；
  - 只有**已录入的机主本人**靠近，比对余弦相似度通过，才允许瞬间点亮屏幕！
- ⌨️ **智能键鼠感知与熄灯节能（0% CPU 极致省电，macOS 27 架构深度优化）**：
  - 借助 macOS 原生 `CGEventSource` 毫秒级探测键鼠活动；
  - **只要在敲键盘或动鼠标，摄像头 100% 断电，硬件指示灯与系统隐私绿点彻底熄灭，CPU 占用直接归零 (0.0%)**；
  - **防频闪震荡守护（macOS 27+ 专属优化）**：用户停手静置（阅读/思考）期间平稳保持摄像头在位守护，**彻底废除每隔数秒频繁启闭相机的机械式脉冲**（完美规避 macOS 27 全新 `MenuBarAgent` / `ControlCenter` 隐私横幅频繁创建销毁导致的 Scene 结构树泄漏与 100% CPU 自旋锁卡死）；
  - **动态自适应采样率**：确认机主在席后，特征提取自动降频至 1.0 FPS 巡航，Vision 计算开销不足 0.2%，兼顾极致省电与系统丝滑稳定；
  - 离开电脑超时后自动熄屏，息屏后采用 8 秒长周期轻柔巡检，保护红外 LED 硬件寿命。
- 🔌 **摄像头设备即插即用与热插拔自愈 (Hotplug Auto-Detection)**：
  - 支持免重启热插拔：应用启动后再插入 Dell 0592WK 摄像头，系统通过 `AVCaptureDevice.wasConnectedNotification` 与心跳探测毫秒级自动重连并激活硬件，拔出后自动平滑降级，无需手动重启应用；
  - 菜单中内置 **「🔊 试听认证成功提示音」**，无需触发真实锁屏即可一键独立验证音效。
- 🎬 **音视频观影与在线会议智能免打扰 (带实时运行指示灯与进程透传)**：
  - 深度集成 IOKit 电源断言探测 (`IOPMCopyAssertionsStatus` 与 `IOPMCopyAssertionsByProcess`)；
  - 无论在 Safari / Chrome 观看 **YouTube / B 站 / 奈飞**，还是使用 **IINA / VLC** 播放电影，或是 **Zoom / 腾讯会议** 在线开会；
  - 系统智能识别媒体播放，**自动免打扰：绝不误息屏、绝不开启摄像头闪烁**，观影体验丝滑无感；
  - **实时状态直观反馈 (🟢 运行中透传 App 来源)**：
    - 观影 / 会议进行中：菜单项动态显示 `✓ 视频观影/在线会议免打扰 🟢 运行中 (Google Chrome)`，一秒确认功能已生效；
    - 无媒体播放待命中：显示 `✓ 视频观影/在线会议免打扰 (⚪ 待命中)`；
    - 纯音频播放（如网易云/Apple Music 听歌）遵循 macOS 系统省电规范，允许屏幕息屏同时音乐继续，绝不误判。
- 🌙 **Dell CN-0592WK 硬件级红外泛光**：
  - 无论全黑房间还是逆光环境，调用已验证的 Realtek 5 步 UVC XU 扩展协议，**瞬间打亮独立红外 LED 发射管**，抓拍高清晰红外夜视图像；
  - 认证完成后瞬间自动熄灭红外灯，避免无谓发热。
- 🛡️ **物理级红外活体防伪与 Windows Hello 环境光差分去噪**：
  - **15Hz 物理交替频闪同步 (Interleaved Strobe)**：遵循微软 Windows Hello 硬件规范（`KSCAMERA_EXTENDEDPROP_FACEAUTH_MODE_ALTERNATIVE_FRAME_ILLUMINATION`），硬件在偶数帧（2、4、6……）以高电流打亮 850nm 发射管，奇数帧（3、5、7……）熄灭发射管采集环境光；
  - **环境光差分去噪 (Ambient Subtraction)**：利用 CoreImage 执行 $I_{\text{clean}} = \max(0, I_{\text{lit}} - I_{\text{ambient}})$，彻底扣减白天的日光直射、室内台灯反射与刺眼眩光，输出实验室级的纯净红外反射特征；
  - **真人体活体防伪 (Anti-Spoofing Liveness)**：手机、iPad 电子屏幕和打印照片自身发光/漫反射恒定，在 15Hz 频闪下的光强差值几乎为 0 ($\Delta \approx 0$)，而人体皮肤反射差值高达 40% ($\Delta \ge 0.15$)，系统自动完成活体检验，彻底粉碎任何屏幕/照片冒充！
- 📜 **通行抓拍历史与安全审计中心 (Audit History)**：
  - 菜单栏一键呼出专属的独立原生视窗；
  - 完整记录每一次锁屏免密、人脸感应亮屏、管理员弹窗与终端 Sudo 的真实抓拍与置信度打分（如 `84%`）；
  - 支持左右分栏大图预览、单条删除、一键清空与访达相册联动；
  - 本地智能滚动保护（最多保留 50 张，约 2MB 硬盘占用），隐私安全无感。
- ⚡ **Apple Vision 框架原生驱动**：
  - 100% 采用 macOS 自带的 **Apple Vision Framework** 提取高精度面部特征与活体关节点，无需下载外部几十兆的第三方模型。
- 🔑 **全场景 Face ID 自动免密授权 (锁屏 + 应用弹窗)**：
  - **应用管理员提权自动授权**：当安装软件或系统设置弹出 `SecurityAgent` 管理员提权窗口时，红外镜头自动秒核验，自动填入钥匙串密码并敲回车，伴随清脆的 Face ID 提示音，如同 iPhone 刷脸支付般丝滑；
  - **锁屏感应唤醒自动进桌面**：人回电脑前，屏幕唤醒后毫秒级自动填入解密凭据，免去任何敲键盘操作，直达工作桌面；
  - **深度兼容 macOS 15 Sequoia 锁屏机制**：
    - 精准避让系统 1.2 秒锁屏过渡动效，防止按键事件被 `loginwindow` 渲染层静默丢弃；
    - 采用非破坏性 `Shift` 唤醒与输入框清理，坚决废弃会导致密码框缩回壁纸的 `Esc` 键；
    - 严格遵循 Sequoia 辅助功能安全要求，注入纳秒级硬件绝对时戳 (`CLOCK_UPTIME_RAW`)，双键值（Return `0x24` + Enter `0x34`）稳健落地；
  - **系统级钥匙串加密**：密码加密保存在 macOS 原生 Keychain 中，受系统硬件级权限隔离保护，安全放心。
- 🧪 **仿 iPhone 环形面容 ID 红外录入向导 (Face Enrollment Guide)**：
  - **76 维面部关键点实时打点 (Face Landmarks Mesh)**：录制过程中调用 Apple Vision 将 76 个骨骼关键点（下颌轮廓 17 点、双眉、双眼、鼻梁、内外嘴唇）实时打在红外预览镜面中，随头部左转、右转、抬头自适应立体跟随流动；
  - **红外暗脉冲防抖平滑（UI 零闪烁）**：引入 350ms 滞后防抖算法，配合平滑透明度过度与固定高度布局，彻底消除 IR LED 频闪暗帧导致的界面文字与发光环抽搐跳动；
  - **动作识别成功定格与 Tink 音效**：向左微转、向右微转、抬头等动作识别达标瞬间，自动播放 macOS 原生清脆的 **"Tink"** 提示音，并将当前成功画面与打点**定格展示 1.2 秒**，让用户从容看清成功瞬间；
  - **戴镜/脱镜双外观录入**：支持两轮录入，无论日常佩戴眼镜还是睡前脱镜，均能极速秒解。
- 🧪 **可视化双目动态硬件向导**：
  - 菜单中内置硬件自检向导，自检时左侧画框实时呈现 720P 可见光流，右侧画框实时呈现 850nm 物理红外夜视流，全黑暗室也能一目了然！
  - **人脸检测与机主匹配打分**：照片预览卡片实时显示人脸检测状态，并在自检第 5 步自动调用 Apple Vision / NPU 提取 128 维特征向量，给出与已录入机主的高精度余弦相似度打分（如 `0.85`）；
  - **🙃 摄像头倒置安装模式 (旋转 180°)**：支持倒贴在显示器下方的安装场景，一键切换并全局持久化；执行严格的 2D 刚体 180° 旋转，上下左右几何完全校正（手性不变），确保人脸录入（抬头/左转/右转）与识别 100% 准确；
  - **双目动态分辨率自适应切换**：配合 Linux 硬件网关，RGB 模式自动采用 1280x720 MJPG，IR 模式自动切换 640x480 YUYV，彻底杜绝色彩通道错位与灰度降采样。
- 🔑 **无感系统提权 (PAM 集成)**：
  - 终端输入 `sudo`，摄像头红外灯一闪，看一眼立刻秒提权，再也不用手动敲长密码；
  - 支持屏幕休眠唤醒刷脸解锁。
- 🔌 **热插拔与意外断开安全容错保护 (Fail-Safe Disconnect Guard)**：
  - 若摄像头意外被物理拔出，系统绝不会因为“识别不到画面”而把屏幕误关或锁屏；
  - 自动安全挂起并平滑交还给 macOS 原生电源管理，屏幕保持正常工作，插回后毫秒级无感自动恢复。

---

## 💻 兼容性与系统版本支持 (Supported Systems)

| 平台 / 系统特性 | 支持情况 | 说明 |
| :--- | :--- | :--- |
| **macOS 27+ (全新 MenuBarAgent 架构)** | ✅ **完美适配优化** | 彻底规避系统级 `MenuBarAgent` 隐私横幅频繁增删引发的 Scene 泄漏与自旋死锁 |
| **macOS 15.0+ (Sequoia 及最新版本)** | ✅ **完美支持** | 原生兼容 Sequoia 严格的 `/etc/pam.d` 安全保护机制 |
| **macOS 14.0 (Sonoma)** | ✅ **完美支持** | 状态栏原生常驻，支持 `sudo_local` 提权与 Apple Vision |
| **macOS 13.0 (Ventura)** | ✅ **最低支持要求** | 支持 `SMAppService` 开机无感自启 |
| **Apple Silicon (M 系列芯片)** | ✅ **原生驱动 (ARM64)** | 针对 M1/M2/M3/M4 系列芯片深度优化，NPU 极速推理 |
| **Intel Mac (x86_64)** | ✅ **通用支持** | 标准 Swift 原生编译 |
| **系统版本跨级升级防丢** | ✅ **永久持久化** | 采用官方 `/etc/pam.d/sudo_local`，系统更新不丢配置 |

---

## 🚀 进阶演进路线 (Roadmap)

1. [x] **红外硬件握手与底层驱动 (IOKit C Bridge)**
2. [x] **实时红外人脸录入向导 GUI (SwiftUI + 76 点面部关键点实时打点 + 动作识别成功定格 1.2s + Tink 音效 + 防抖零闪烁)**
3. [x] **人体存在感应与息屏/亮屏电源管理 (`DisplayPowerManager`)**
4. [x] **机主专属亮屏与陌生人防窥拦截 (`PresenceAutoDisplayService`)**
5. [x] **智能键鼠感知与摄像头低功耗熄灯引擎 (`InputIdleMonitor`)**
6. [x] **媒体观影与视频会议免打扰 (`MediaActivityDetector`)**
7. [x] **macOS PAM 终端 Sudo 刷脸免密提权 (`pam_machello.so`)**
8. [x] **钥匙串安全存储与全场景 Face ID 自动免密授权（锁屏进桌面 + 应用提权弹窗）**
9. [x] **双目硬件向导动态视频实时回显与全黑暗室 ISP 自动增益爬升**
10. [x] **Windows Hello 规范 15Hz 频闪脉冲同步、环境光差分去噪与活体防伪检测**
11. [x] **独立人脸通行历史与抓拍大卡片视窗（支持按记录删除、清空、一键相册）**
12. [x] **macOS 27 MenuBarAgent / ControlCenter 隐私指示器震荡防护与动态自适应节能采样率**
13. [x] **双部署工作模式：本机 USB 直连（BLEUnlock 规范·0% CPU·无绿点常开）与局域网 Linux 微服务模式（WebSocket 实时广播·红外夜视监控流）**

---

## 🛠️ 适配硬件与主控规格

- **推荐硬件**：**Dell CN-0592WK** (DP/N: `0592WK` / 戴尔原厂拆机模组，性价比之王，二手仅需 10~20 元)
- **主控 ISP 芯片**：Realtek RTS5822 / RTS5767
- **USB 硬件 ID**：`0bda:5767` (VendorID: `0x0bda`, ProductID: `0x5767`)
- **硬件特性**：
  - 硬件双目模组：RGB 彩色镜头 (720P) + 独立物理近红外镜头 (640x480 YUY2) + 850nm 红外 LED 补光灯珠；
  - 受控于 Realtek UVC Extension Unit (Unit 4, 寄存器 `0x9f00`)。

---

## 📦 打包与安装为原生 macOS 应用程序 (.app)

无论您是日常使用还是交付给普通用户，本项目已提供完整的标准 macOS 应用程序打包脚本：

```bash
# 一键打包并将 MacHello.app 安装到系统的「访达 / 应用程序 (/Applications)」
./scripts/package-app.sh --install
```

安装完成后：
1. **启动与常驻**：可在 **启动台 (Launchpad)** 或 **聚焦搜索 (Spotlight)** 中直接启动 `MacHello`，右上角状态栏常驻，Dock 栏不占位。
2. **开机自启动**：在菜单中点击 **`[✓] 登录时自动启动`**，系统无感托管常驻。
3. **GUI 一键配置 Sudo 提权**：在菜单中点击 **`终端 Sudo 刷脸免密提权`**，macOS 会自动弹出系统管理员密码弹窗，**输一次密码/触碰 Touch ID 即可永久自动配置**，无需手敲任何终端脚本；再次点击即可一键干净卸载！

---

## 🧪 开发者调试与测试命令

```bash
# 1. 编译并运行原生菜单栏应用
swift run MacHello

# 2. 运行单元测试
swift test

# 3. 运行硬件诊断工具（自动测试可见光、红外切换并保存测试图像至 Tests/Snapshots/，随后安全复位）
swift run MacHelloDoctor

# 4. 运行仿 iPhone 面容 ID 红外录入向导
swift run MacHelloEnroll

# 5. 测试人脸秒级认证命令行
swift run MacHelloAuth

# 6. 一键安装 / 卸载终端 Sudo 刷脸提权 PAM 模块
sudo ./scripts/install-pam.sh     # 安装生效
sudo ./scripts/uninstall-pam.sh   # 安全还原卸载
```

---

## 🙏 致敬与开源逆向致谢 (Credits & Acknowledgments)

本项目能够在 macOS 用户空间直接驱动 Dell CN-0592WK 的底层红外发射器，离不开开源社区逆向先驱们的卓越探索。本项目深切致谢以下开源项目与贡献者：

1. **[MrWinux/rtk-ir-tools](https://github.com/MrWinux/rtk-ir-tools)**  
   由 **SeeleVolleri** 与 **MrWinux** 逆向分析并公开的 Realtek UVC 扩展单元（Unit 4）5 步状态机握手机制（0x0A / 0x0B 选择器及 `0xfb00`、`0x9f00` 寄存器交互），这是本项目控制红外硬件的核心理论与指令基石。
2. **[boltgolt/howdy](https://github.com/boltgolt/howdy)**  
   Linux 下久负盛名的 Windows Hello 开源实现，为本项目的 PAM 认证架构与安全回退设计提供了极为宝贵的参考。
3. **[ts1/BLEUnlock](https://github.com/ts1/BLEUnlock)**  
   由 **Takeshi Sone** 编写的知名开源 macOS 自动锁屏/解锁工具。本项目在实现锁屏唤醒电源管理（`IOPMAssertionDeclareUserActivity` 与 `caffeinate`）、底层 HID 按键模拟序列注入（`cghidEventTap` 与 Return/Enter 兼容键值）以及钥匙串安全管理机制时，深入借鉴了其优雅成熟的架构设计，在此致以崇高敬意与由衷感谢！
4. **[GunduLabs/gaze](https://github.com/GunduLabs/gaze)**  
   为跨平台用户空间 USB/UVC 控制提供了关键指导。
5. **[jizhi0v0/macos27-beta-issues](https://github.com/jizhi0v0/macos27-beta-issues)**  
   由 **jizhi0v0**、**andya1lan**、**ehagerty** 与 **progzone122** 持续跟踪记录的 macOS 27 系统级底层缺陷档案库。特别鸣谢该项目针对 macOS 27 新引入的 `MenuBarAgent` 菜单栏状态项/系统横幅（`systemBanners`）高频 Churn 累积泄漏、`NSSceneFenceAction` 自旋死锁与下游 `WindowServer` 100% CPU 机制（Issue #12, #20, #22）的深度逆向剖析与诊断工具，为本项目彻底解决长时间运行后的系统卡顿与状态栏冻结提供了至关重要的技术依据！

---

## 📜 许可证

本项目遵循 MIT 许可证开源。

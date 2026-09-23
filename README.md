# MacHello-0592WK 🍏👁️

> **专为 macOS (Apple Silicon M 系列 & Intel) 打造的原生 Windows Hello 级红外人脸解锁工具**  
> 基于 **Dell CN-0592WK (Realtek 0bda:5767)** 生物识别拆机模组，采用 **原生 Swift 编写**，无任何 Python 运行时臃肿依赖，常驻菜单栏，无感解锁。

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
- 🚶 **走开息屏 · 来人亮屏 (Human Presence Detection - HPD)**：
  - 毫秒级低功耗检测，用户离开座位达到指定时长（10秒/15秒/30秒/1分钟可选），自动触发 `pmset displaysleepnow` 熄灭屏幕（保持系统与后台运行）；
  - 当用户重新回到电脑前，毫秒级点亮屏幕 (`IOPMAssertionDeclareUserActivity`)。
- 🛡️ **仅限机主本人才亮屏（防窥安全模式）**：
  - 黑屏休眠状态下，陌生人或路过同事走到屏幕前，特征比对失败，**坚决保持黑屏锁定**；
  - 只有**已录入的机主本人**靠近，比对余弦相似度通过，才允许瞬间点亮屏幕！
- 🌙 **Dell CN-0592WK 硬件级红外泛光**：
  - 无论全黑房间还是逆光环境，调用已验证的 Realtek 5 步 UVC XU 扩展协议，**瞬间打亮独立红外 LED 发射管**，抓拍高清晰红外夜视图像；
  - 认证完成后瞬间自动熄灭红外灯，避免无谓发热。
- 🛡️ **物理级红外活体防伪**：
  - 手机屏幕、平板屏幕、打印纸张在 850nm 红外光下无法模拟人脸皮肤的独特吸光与反射特征，彻底杜绝照片欺骗。
- ⚡ **Apple Vision 框架原生驱动**：
  - 100% 采用 macOS 自带的 **Apple Vision Framework** 提取高精度面部特征与活体关节点，无需下载外部几十兆的第三方模型。
- 🔑 **无感系统提权 (PAM 集成)**：
  - 终端输入 `sudo`，摄像头红外灯一闪，看一眼立刻秒提权，再也不用手动敲长密码；
  - 支持屏幕休眠唤醒刷脸解锁。

---

## 🚀 进阶演进路线 (Roadmap)

1. [x] **红外硬件握手与底层驱动 (IOKit C Bridge)**
2. [x] **实时红外人脸录入向导 GUI (SwiftUI + 4姿态环形进度引导)**
3. [x] **人体存在感应与息屏/亮屏电源管理 (`DisplayPowerManager`)**
4. [x] **机主专属亮屏与陌生人防窥拦截 (`PresenceAutoDisplayService`)**
5. [x] **键鼠活跃感知防误触 (`InputIdleMonitor`)**（打字与使用鼠标期间自动挂起手势识别，0% CPU 占用且杜绝工作误触）
6. [x] **隔空手势识别交互 (Air Gestures)**（Apple Vision 21 点手部骨骼算法：支持静态姿态、动态横扫/画圈轨迹、捏指比心 🫰）
7. [x] **自定义手势与快捷按键配置面板 (SwiftUI GUI)**（支持自由绑定多媒体播控、音量微调、锁屏、息屏、调度中心、指定应用启动）
8. [ ] **macOS PAM 终端与锁屏刷脸秒解锁集成**

---

## 🛠️ 适配硬件与主控规格

- **推荐硬件**：**Dell CN-0592WK** (DP/N: `0592WK` / 戴尔原厂拆机模组，性价比之王，二手仅需 10~20 元)
- **主控 ISP 芯片**：Realtek RTS5822 / RTS5767
- **USB 硬件 ID**：`0bda:5767` (VendorID: `0x0bda`, ProductID: `0x5767`)
- **硬件特性**：
  - 硬件双目模组：RGB 彩色镜头 (720P) + 独立物理近红外镜头 (640x480 YUY2) + 850nm 红外 LED 补光灯珠；
  - 受控于 Realtek UVC Extension Unit (Unit 4, 寄存器 `0x9f00`)。

---

## 🧪 硬件测试与运行方式

```bash
# 1. 编译并运行原生菜单栏应用
swift run MacHello

# 2. 运行单元测试
swift test

# 3. 运行硬件诊断工具（自动测试可见光、红外切换并保存测试图像至 Tests/Snapshots/，随后安全复位）
swift run MacHelloDoctor

# 4. 运行仿 iPhone 面容 ID 红外录入向导
swift run MacHelloEnroll
```

---

## 🙏 致敬与开源逆向致谢 (Credits & Acknowledgments)

本项目能够在 macOS 用户空间直接驱动 Dell CN-0592WK 的底层红外发射器，离不开开源社区逆向先驱们的卓越探索。本项目深切致谢以下开源项目与贡献者：

1. **[MrWinux/rtk-ir-tools](https://github.com/MrWinux/rtk-ir-tools)**  
   由 **SeeleVolleri** 与 **MrWinux** 逆向分析并公开的 Realtek UVC 扩展单元（Unit 4）5 步状态机握手机制（0x0A / 0x0B 选择器及 `0xfb00`、`0x9f00` 寄存器交互），这是本项目控制红外硬件的核心理论与指令基石。
2. **[boltgolt/howdy](https://github.com/boltgolt/howdy)**  
   Linux 下久负盛名的 Windows Hello 开源实现，为本项目的 PAM 认证架构与安全回退设计提供了极为宝贵的参考。
3. **[GunduLabs/gaze](https://github.com/GunduLabs/gaze)**  
   为跨平台用户空间 USB/UVC 控制提供了关键指导。

---

## 📜 许可证

本项目遵循 MIT 许可证开源。

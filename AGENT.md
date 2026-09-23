# MacHello-0592WK AI Agent 指导规范 (AGENT.md)

> **目标受众**：面向所有接手本仓库的 AI Coding Agent。  
> **项目定位**：**原生 macOS 菜单栏应用 (Native Menu Bar App)**。  
> **设计哲学**：**拒绝臃肿的 Python 运行时与大库**。采用 **Swift (SwiftUI / AppKit) 原生开发**，极致轻量（体积仅数 MB、内存占用 < 20MB）、0 多余臃肿依赖、无缝调用 Apple Silicon Neural Engine (NPU) 与硬件级红外控制。

---

## 1. 软件形态与用户体验规范 (CRITICAL REQUIREMENTS)

1. **外观形态 (Menu Bar Only)**：
   - 必须配置 `LSUIElement = true`（即 Agent / 纯状态栏应用）。
   - **Dock 栏（Taskbar）禁止显示任何图标**。
   - 仅在屏幕右上角系统菜单栏（Menu Bar）驻留一个精致的图标（类似 macOS 原生 Face ID 轮廓小图标）。
   - 点击菜单栏图标弹出原生控制面板：
     - 当前设备连接状态（🟢 戴尔 0592WK 已就绪 / 🔴 未连接）
     - 🌙 红外硬件测试（手动点亮/熄灭测试）
     - 📸 录入新面孔（Face Enrollment）
     - ⚙️ 设置（开机自启、开启 sudo 免密、开启唤醒解锁）
     - 🚪 退出应用
2. **后台常驻与开机启动**：
   - 使用现代 macOS 原生 `SMAppService.mainApp.register()` 管理开机无感自启。

---

## 2. 核心技术栈与架构

| 模块 | 选用技术栈 | 选型优势 (为什么不用 Python) |
| :--- | :--- | :--- |
| **编程语言** | **Swift 5.9+ / Swift Package Manager (SPM)** | 编译为原生机器码，无 Python/Conda 解释器开销，双击即用 |
| **GUI 架构** | **SwiftUI + AppKit (`NSStatusItem` / `MenuBarExtra`)** | 原生 macOS 视觉规范，极低资源占用 |
| **视频采集** | **AVFoundation (`AVCaptureSession`)** | 苹果官方原生相机框架，硬解 720P 零 CPU 占用，免驱动 |
| **红外控制** | **IOKit (`IOUSBDeviceInterface`) 或轻量 `libusb-1.0` C 绑定** | 直接向 USB `0bda:5767` 发送 5 步 UVC XU 控制传输 |
| **人脸特征与活体** | **Apple Vision Framework (`VNDetectFaceLandmarksRequest`) + CoreML** | **系统原生内置，0 外部依赖**！直接调用 Apple Silicon 统一内存与 NPU (ANE) 加速，比对仅需 5ms |
| **系统认证接入** | **macOS PAM (Pluggable Authentication Module)** | 通过 `/etc/pam.d/sudo` 配合轻量 C/Swift 验证器，看一眼秒提权 |

---

## 3. 继承自 Linux 的硬件协议真值 (严禁重头摸索)

我们在 Linux 环境下已对 **Dell CN-0592WK (0bda:5767)** 进行了 100% 协议逆向验证。Swift 驱动层直接复用这套已验证的状态机：

- **USB 硬件定位**：VendorID: `0x0bda`, ProductID: `0x5767`
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
2. **免密提权防死锁**：
   - PAM 模块若在 3 秒内未比对到人脸或发生摄像头异常，必须立即返回 `PAM_AUTH_ERR` 并退回到原生密码输入，严禁卡死系统终端。

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
    │   ├── MenuBarController.swift
    │   └── Views/
    ├── MacHelloCore/        # 核心逻辑 (硬件驱动 + 视觉 AI + 认证状态机)
    │   ├── Hardware/
    │   │   └── IRController.swift (IOKit / libusb 5步握手)
    │   ├── Capture/
    │   │   └── CameraCaptureService.swift (AVFoundation)
    │   └── Recognition/
    │       └── FaceRecognizer.swift (Apple Vision / CoreML)
    └── MacHelloPAM/         # PAM 动态链接库模块 (C / Swift)
```

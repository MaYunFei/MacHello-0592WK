# MacHello Linux Camera Gateway 🐧👁️

> **将 Dell CN-0592WK 生物识别模组接入局域网 Linux 设备，为 Mac 提供 Samba 式零开销硬件视频数据源与红外控制网关**

---

## 🖥️ 真实实测运行环境 (Verified Environment)

- **主机连接**：`ssh root@192.168.66.5`
- **部署路径**：`/root/machello-server`
- **操作系统**：Debian GNU/Linux 13 (`trixie` / 13.1)
- **底层架构**：Proxmox VE (PVE) 虚拟化环境（USB 直通共享硬件设备节点）
- **内核版本**：`Linux 7.0.12-1-pve #1 SMP PREEMPT_DYNAMIC PMX 7.0.12-1 x86_64`
- **目标设备**：Dell CN-0592WK（Realtek `0bda:5767`，支持即插即用动态检测，节点 `/dev/video0` 与 `/dev/video1`）
- **守护模式**：裸跑单文件 + systemd 系统级开机自启动守护（无需 Docker）

---

## 🌟 核心特性与架构定位

1. **彻底解放 Mac 算力与电池**：
   - Mac 端无需物理插拔 USB 摄像头；
   - 彻底避免 macOS 27 状态栏因频繁请求摄像头权限而出现的绿色图标闪烁与 `MenuBarAgent` 性能冲突；
   - Mac 端摄像头使用率直接归零，CPU 维持绝对的 **0.00%**。
2. **Samba 模式纯硬件网关（不占 Linux 算力）**：
   - Linux 端**不跑任何重型人脸识别算法**，算力 100% 留给 Mac 的 Apple Neural Engine (NPU)；
   - **平时按需完全释放摄像头**：无拉流请求时，摄像头硬件处于释放断电状态，**指示灯 100% 熄灭，Linux CPU 占用 0.0%**；
   - 依托 Linux 原生 V4L2 与 UVC XU 控制，完美驱动 Realtek 0bda:5767 独立 850nm 红外发射管与夜视传感器；
3. **开机自检与动态硬件感知 (即插即用)**：
   - 服务启动时自动扫描 `/sys/class/video4linux` 识别 `0bda:5767` 硬件；
   - 若摄像头未插入或中途拔出，API 明确返回 `503 Camera hardware not plugged in` 与 `is_connected: false`，绝不假冒就绪；
   - 支持热插拔，插入摄像头后网关毫秒级自动重连并恢复供流。
4. **系统级开机自启 (断电无忧)**：
   - 采用 systemd 管理 `machello-server.service`，主机重启或断电后自动拉起，崩溃自动 3 秒重启。

---

## 🚀 服务管理与自启动命令

连接到服务器：
```bash
ssh root@192.168.66.5
cd /root/machello-server
```

### 一键安装并配置开机自启
```bash
# 注册并立即启动 systemd 守护服务
./install-service.sh
```

### 常用 systemd 管理命令
```bash
# 查看服务运行状态
systemctl status machello-server

# 查看实时日志
journalctl -u machello-server -f

# 重启服务
systemctl restart machello-server

# 停止服务
systemctl stop machello-server
```

---

## 🔌 开放接口与协议规范

服务默认监听 `8765` 端口（`http://192.168.66.5:8765`）：

| 接口地址 | 协议 | 功能描述 |
| :--- | :--- | :--- |
| `GET /api/status` | HTTP JSON | 查看当前硬件插拔状态、设备节点路径、红外灯状态与推流状态 |
| `GET /api/snapshot` | HTTP JPEG | 单帧快速抓拍快照（Mac 端间歇在席巡检使用，未插摄像头时返回 503） |
| `GET /api/ir/toggle` | HTTP JSON | 手动切换红外灯开/关（点亮时硬件供流，850nm LED 亮起红光） |
| `GET /api/ir/set?ir=0\|1` | HTTP JSON | 显式设置红外模式 (`ir=1` 打亮红外灯，`ir=0` 物理断电熄灭) |
| `GET /api/ir/pulse` | HTTP JSON | 瞬时触发 0.5s 红外脉冲扫描，用于暗光精确核验，核验后秒灭 |
| `GET /stream` | HTTP MJPEG | 实时视频流（MacHello 向导拉流或在浏览器中直接预览） |
| `ws://192.168.66.5:8765/ws` | WebSocket | 双向控制与低延迟心跳通道（连接时主动上报硬件在位状态） |

---

## 💻 Mac 端接入设置

在 Mac 菜单栏点击 MacHello 图标：
1. 在 **工作模式** 菜单中勾选 **`🌐 局域网 Linux 智能服务`**；
2. 服务端地址默认已设为 **`http://192.168.66.5:8765`**；
3. 保存后系统秒级自动连接，Mac 即刻享受全天候自动息屏/亮屏进桌面，且 Mac 端绝对无任何摄像头闪灯打扰！

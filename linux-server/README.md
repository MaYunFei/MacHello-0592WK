# MacHello Linux Camera Gateway 🐧👁️

> **将 Dell CN-0592WK 生物识别模组接入局域网 Linux 设备，为 Mac 提供 Samba 式零开销硬件视频数据源与红外控制网关**

---

## 🖥️ 真实实测运行环境 (Verified Environment)

- **操作系统**：Debian GNU/Linux 13 (`trixie` / 13.1)
- **底层架构**：Proxmox VE (PVE) 虚拟化环境（USB 直通共享硬件设备节点）
- **内核版本**：`Linux 7.0.12-1-pve #1 SMP PREEMPT_DYNAMIC PMX 7.0.12-1 x86_64`
- **目标设备**：Dell CN-0592WK（Realtek `0bda:5767`，节点 `/dev/video0` 与 `/dev/video1`）
- **运行模式**：免 Docker 轻量直接驻留（依赖仅 `python3-opencv` + `python3-aiohttp`）

---

## 🌟 为什么将摄像头部署在 Linux 上？

1. **彻底解放 Mac 算力与电池**：
   - Mac 端无需物理插拔 USB 摄像头；
   - 彻底避免 macOS 27 状态栏因频繁请求摄像头权限而出现的绿色图标闪烁与 `MenuBarAgent` 性能冲突；
   - Mac 端摄像头使用率直接归零，CPU 维持绝对的 **0.00%**。
2. **Samba 模式纯硬件网关（不占 Linux 算力）**：
   - Linux 端**不跑任何重型人脸识别算法**，算力 100% 留给 Mac 的 Apple Neural Engine (NPU)；
   - **平时按需完全释放摄像头**：无拉流请求时，摄像头硬件处于释放断电状态，**指示灯 100% 熄灭，Linux CPU 占用 0.0%**；
   - 依托 Linux 原生 V4L2 与 UVC XU 控制，完美驱动 Realtek 0bda:5767 独立 850nm 红外发射管与夜视传感器；
3. **能力无限扩展 (智能家居联动)**：
   - 暴露标准 HTTP RESTful、WebSocket 与 MJPEG 监控流；
   - 不仅为 MacHello 提供高清数据源，还可直接作为智能猫眼/红外监控接入 **Home Assistant**！

---

## 🚀 便捷管理命令

进入服务器部署目录 `/root/machello-server`：

```bash
# 启动网关服务 (后台运行)
./start.sh

# 停止网关服务
./stop.sh

# 查看实时运行日志
tail -f server.log
```

---

## 🔌 开放接口与协议规范

服务默认监听 `8765` 端口：

| 接口地址 | 协议 | 功能描述 |
| :--- | :--- | :--- |
| `GET /api/status` | HTTP JSON | 查看当前硬件在线状态、红外灯状态、观看人数与推流状态 |
| `GET /api/snapshot` | HTTP JPEG | 单帧快速抓拍快照（Mac 端间歇在席巡检使用，指示灯闪烁 0.08s 即灭） |
| `GET /api/ir/toggle` | HTTP JSON | 手动切换红外灯开/关（点亮时硬件供流，850nm LED 亮起红光） |
| `GET /api/ir/set?ir=0\|1` | HTTP JSON | 显式设置红外模式 (`ir=1` 打亮红外灯，`ir=0` 物理断电熄灭) |
| `GET /api/ir/pulse` | HTTP JSON | 瞬时触发 0.5s 红外脉冲扫描，用于暗光精确核验，核验后秒灭 |
| `GET /stream` | HTTP MJPEG | 实时视频流（MacHello 向导拉流或在浏览器中直接预览） |
| `ws://<IP>:8765/ws` | WebSocket | 双向控制与低延迟心跳通道 |

---

## 💻 Mac 端接入设置

在 Mac 菜单栏点击 MacHello 图标：
1. 在 **工作模式** 菜单中勾选 **`🌐 局域网 Linux 智能服务`**；
2. 点击 **`配置 Linux 服务端地址...`**，填入 Linux 主机 IP（例如 `http://192.168.1.100:8765`）；
3. 保存后系统秒级自动连接，Mac 即刻享受全天候自动息屏/亮屏进桌面，且 Mac 端绝对无任何摄像头闪灯打扰！

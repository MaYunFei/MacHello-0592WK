#!/usr/bin/env python3
"""
MacHello-0592WK Linux Camera Gateway 🐧👁️
专为 Dell CN-0592WK (Realtek 0bda:5767) 打造的局域网硬件数据源服务（Samba 式网络相机网关）

定位：
- 纯硬件数据提供者（不跑任何业务逻辑与人脸比对，算力 100% 留给 Mac NPU）
- 驱动 Realtek 0bda:5767 硬件与 UVC XU 控制序列（RGB 模式 / 850nm 红外夜视模式）
- 按需供流：当 Mac 或浏览器请求画面时极速开启；无客户端时彻底释放相机灭灯，0% CPU
- 极速暴露 HTTP MJPEG 流、单帧快照 API 与 WebSocket 双向控制通道
"""

import os
import sys
import time
import json
import fcntl
import struct
import ctypes
import asyncio
import threading
import logging
from typing import Set, Dict, Any, Optional

from aiohttp import web

try:
    import cv2
    HAVE_CV = True
except ImportError:
    HAVE_CV = False

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("machello-gateway")

# ==============================================================================
# 1. Realtek UVC Extension Unit (Unit 4) 5步握手协议
# ==============================================================================

UVC_CONTROL_SET_CUR = 0x01
UVC_CONTROL_GET_CUR = 0x81
UVCIOC_CTRL_QUERY = 0xC0107521  # Linux _IOWR('U', 0x21, struct uvc_xu_control_query)

class UVCIOCControlQuery(ctypes.Structure):
    _fields_ = [
        ("unit", ctypes.c_uint8),
        ("selector", ctypes.c_uint8),
        ("query", ctypes.c_uint8),
        ("size", ctypes.c_uint16),
        ("data", ctypes.c_void_p),
    ]

class RealtekIRController:
    """Linux V4L2 底层驱动 Dell 0592WK 红外 LED 与模式切换"""
    def __init__(self, device_path: str = "/dev/video0"):
        self.device_path = device_path
        self.unit_id = 4
        self.fd: Optional[int] = None
        self.is_connected = False
        self.current_is_ir = False
        self._init_device()

    def _init_device(self):
        try:
            if os.path.exists(self.device_path):
                self.fd = os.open(self.device_path, os.O_RDWR | os.O_NONBLOCK)
                self.is_connected = True
                logger.info(f"已连接相机硬件设备节点: {self.device_path}")
            else:
                self.is_connected = False
        except Exception as e:
            logger.warning(f"打开设备节点失败 ({self.device_path}): {e}")
            self.is_connected = False

    def _xu_query(self, selector: int, query: int, data: bytes) -> bytes:
        if self.fd is None:
            self._init_device()
            if self.fd is None:
                return b""
        data_buf = (ctypes.c_uint8 * len(data))(*data)
        query_struct = UVCIOCControlQuery(
            self.unit_id,
            selector,
            query,
            len(data),
            ctypes.cast(data_buf, ctypes.c_void_p)
        )
        try:
            fcntl.ioctl(self.fd, UVCIOC_CTRL_QUERY, query_struct)
            return bytes(data_buf)
        except Exception as e:
            logger.debug(f"XU Query ioctl: {e}")
            return b""

    def set_mode(self, is_ir: bool) -> bool:
        """执行经逆向验证的 Realtek 5 步 UVC XU 控制序列"""
        if not self.is_connected:
            self._init_device()
            if not self.is_connected:
                return False
        mode_byte = 0x00 if is_ir else 0x01
        try:
            # 1. 复位
            self._xu_query(0x0A, UVC_CONTROL_SET_CUR, bytes([0xFF] + [0] * 7))
            # 2. 选址 0xfb00
            self._xu_query(0x0A, UVC_CONTROL_SET_CUR, bytes([0x00, 0xFB, 0, 0, 0x05, 0, 0, 0]))
            # 3. 握手读取
            self._xu_query(0x0B, UVC_CONTROL_GET_CUR, bytes([0] * 8))
            # 4. 选址 0x9f00
            self._xu_query(0x0A, UVC_CONTROL_SET_CUR, bytes([0x00, 0x9F, 0, 0, 0x01, 0, 0, 0]))
            # 5. 写入模式
            self._xu_query(0x0B, UVC_CONTROL_SET_CUR, bytes([mode_byte] + [0] * 7))
            self.current_is_ir = is_ir
            logger.info(f"0592WK 硬件模式 -> {'红外夜视 (IR 850nm 发射管打亮)' if is_ir else '可见光 (RGB 物理断电熄灭红外灯)'}")
            return True
        except Exception as e:
            logger.error(f"硬件控制握手异常: {e}")
            return False

# ==============================================================================
# 2. 按需供流视频捕获网关 (0 负载 / 自动灭灯)
# ==============================================================================

class VideoGateway:
    """按需视频捕获网关：仅在 Mac 或客户端订阅时启动视频流，闲时彻底释放相机灭灯"""
    def __init__(self, device_id: int = 0):
        self.device_id = device_id
        self.ir_controller = RealtekIRController(f"/dev/video{device_id}")
        self.lock = threading.Lock()
        self.active_viewers = 0
        self.ir_test_active = False
        self.current_mode_is_ir = False
        self.latest_jpeg: Optional[bytes] = None
        self.subscribers: Set[asyncio.Queue] = set()
        self.cap: Optional[Any] = None
        self.is_running = True
        self.worker_thread = threading.Thread(target=self._capture_worker, daemon=True)
        self.worker_thread.start()

    def _open_camera(self, is_ir: bool = False) -> bool:
        if not HAVE_CV:
            return False
        if self.cap is not None:
            if self.cap.isOpened() and self.current_mode_is_ir == is_ir:
                return True
            self.cap.release()
            self.cap = None

        cap = cv2.VideoCapture(self.device_id)
        if is_ir:
            # 近红外物理镜头：固定 640x480 YUYV
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'YUYV'))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        else:
            # 可见光物理镜头：固定 1280x720 MJPG 格式
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

        if cap.isOpened():
            self.cap = cap
            self.current_mode_is_ir = is_ir
            self.latest_jpeg = None
            # 预读稳定曝光
            for _ in range(2):
                cap.read()
            mode_desc = "🌙 近红外 640x480 YUYV" if is_ir else "📷 可见光 720P MJPG"
            logger.info(f"摄像头硬件已激活供流 [{mode_desc}]")
            return True
        else:
            logger.warning(f"无法打开摄像头设备 (/dev/video{self.device_id})")
            return False

    def _close_camera(self):
        if self.cap is not None:
            self.cap.release()
            self.cap = None
            logger.info("💤 所有客户端已断开：摄像头硬件已释放，指示灯彻底熄灭，CPU 归零 (0%)")

    def set_ir_test(self, enable: bool):
        """开启或关闭红外测试模式（切换硬件镜头与模式）"""
        with self.lock:
            self.ir_test_active = enable
            self.latest_jpeg = None
            self.ir_controller.set_mode(enable)
            # 切换底层硬件镜头模式，释放当前流以重新协商分辨率与编码
            if self.cap is not None:
                self.cap.release()
                self.cap = None
            if enable or self.active_viewers > 0:
                self._open_camera(is_ir=enable)
            if not enable and self.active_viewers <= 0:
                self._close_camera()
            mode_str = "IR 850nm 发射管打亮 (近红外夜视)" if enable else "IR 850nm 物理断电熄灭 (RGB 可见光)"
            logger.info(f"💡 硬件模式切换完成: {mode_str}")

    def _capture_worker(self):
        # 启动时确保红外灯物理断电
        self.ir_controller.set_mode(False)

        while self.is_running:
            with self.lock:
                viewers = self.active_viewers
                ir_test = self.ir_test_active

            if viewers <= 0 and not ir_test:
                with self.lock:
                    if self.cap is not None:
                        self._close_camera()
                time.sleep(0.2)
                continue

            # 有客户端拉流，确保相机打开且工作在目标模式
            with self.lock:
                target_ir = self.ir_test_active
                if self.cap is None or self.current_mode_is_ir != target_ir:
                    if not self._open_camera(is_ir=target_ir):
                        time.sleep(0.5)
                        continue

            ret, frame = self.cap.read()
            if ret and frame is not None:
                _, jpeg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
                jpeg_bytes = jpeg.tobytes()
                with self.lock:
                    self.latest_jpeg = jpeg_bytes

            time.sleep(0.033)  # 约 30 FPS 高清推流

    def get_snapshot(self) -> Optional[bytes]:
        """按需单帧抓拍：用于单次快速核验或间歇在席巡检 (指示灯眨眼 0.08s 随即熄灭)"""
        with self.lock:
            if self.cap is not None and self.cap.isOpened():
                ret, frame = self.cap.read()
                if ret and frame is not None:
                    _, jpeg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
                    return jpeg.tobytes()

            # 相机未开启时，原子化极速抓拍单帧后立刻关闭设备灭灯
            target_ir = self.ir_test_active
            cap = cv2.VideoCapture(self.device_id)
            if target_ir:
                cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'YUYV'))
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            else:
                cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

            jpeg_bytes = None
            try:
                for _ in range(2):
                    cap.read()
                ret, frame = cap.read()
                if ret and frame is not None:
                    _, jpeg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
                    jpeg_bytes = jpeg.tobytes()
            finally:
                cap.release()
            return jpeg_bytes

    def pulse_ir(self, duration: float = 0.5):
        """瞬时脉冲点亮红外 LED 进行高精度暗光抓拍，核验后立刻物理熄灭"""
        def _pulse():
            logger.info(f"⚡ 执行红外 LED 瞬时脉冲 ({duration}s)...")
            self.ir_controller.set_mode(True)
            time.sleep(duration)
            self.ir_controller.set_mode(False)
            logger.info("✓ 红外脉冲结束，红外 LED 已熄灭恢复 RGB 模式")

        threading.Thread(target=_pulse, daemon=True).start()

gateway = VideoGateway()

# ==============================================================================
# 3. HTTP / WebSocket 极速服务路由
# ==============================================================================

async def handle_status(request):
    return web.json_response({
        "status": "ok",
        "device": "Dell CN-0592WK (Realtek 0bda:5767)",
        "is_connected": gateway.ir_controller.is_connected,
        "ir_active": gateway.ir_test_active,
        "viewers": gateway.active_viewers,
        "camera_streaming": (gateway.cap is not None and gateway.cap.isOpened())
    })

async def handle_ir_toggle(request):
    new_mode = not gateway.ir_test_active
    gateway.set_ir_test(new_mode)
    return web.json_response({
        "status": "ok",
        "ir_active": new_mode,
        "description": "红外夜视灯已打亮" if new_mode else "红外夜视灯已物理断电熄灭 (RGB 模式)"
    })

async def handle_ir_pulse(request):
    duration = float(request.query.get("duration", 0.5))
    gateway.pulse_ir(duration)
    return web.json_response({
        "status": "ok",
        "action": "pulse",
        "duration": duration
    })

async def handle_ir_set(request):
    mode = request.query.get("ir", "0")
    is_ir = (mode == "1" or mode.lower() == "true")
    gateway.set_ir_test(is_ir)
    return web.json_response({
        "status": "ok",
        "ir_active": is_ir
    })

async def handle_snapshot(request):
    """获取单帧 JPEG 快照"""
    loop = asyncio.get_event_loop()
    jpeg_bytes = await loop.run_in_executor(None, gateway.get_snapshot)
    if jpeg_bytes:
        return web.Response(body=jpeg_bytes, content_type="image/jpeg")
    return web.Response(status=503, text="Camera unavailable")

async def handle_stream(request):
    """实时 MJPEG 视频流传输通道 (MacHello 客户端直连数据源)"""
    with gateway.lock:
        gateway.active_viewers += 1

    response = web.StreamResponse(
        status=200,
        reason='OK',
        headers={
            'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
            'Cache-Control': 'no-cache',
            'Connection': 'close'
        }
    )
    await response.prepare(request)

    try:
        while True:
            frame_bytes = None
            with gateway.lock:
                frame_bytes = gateway.latest_jpeg

            if frame_bytes:
                header = f"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {len(frame_bytes)}\r\n\r\n".encode('utf-8')
                try:
                    await response.write(header + frame_bytes + b"\r\n")
                except Exception:
                    break
            await asyncio.sleep(0.04)
    finally:
        with gateway.lock:
            gateway.active_viewers = max(0, gateway.active_viewers - 1)

    return response

async def handle_websocket(request):
    """双向控制与低延迟心跳通道"""
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    logger.info(f"Mac 客户端已建立 WebSocket 控制长连接: {request.remote}")

    # 发送当前硬件就绪状态
    await ws.send_json({
        "type": "status",
        "device": "Dell CN-0592WK",
        "ir_active": gateway.ir_controller.current_is_ir
    })

    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                    cmd = data.get("action")
                    if cmd == "ir_pulse":
                        gateway.pulse_ir(float(data.get("duration", 0.5)))
                    elif cmd == "ir_toggle":
                        new_mode = not gateway.ir_controller.current_is_ir
                        gateway.ir_controller.set_mode(new_mode)
                        await ws.send_json({"type": "ir_status", "ir_active": new_mode})
                except Exception:
                    pass
            elif msg.type == web.WSMsgType.ERROR:
                break
    finally:
        logger.info(f"Mac 客户端已断开控制连接: {request.remote}")

    return ws

def main():
    port = int(os.environ.get("PORT", "8765"))

    app = web.Application()
    app.router.add_get("/", handle_status)
    app.router.add_get("/api/status", handle_status)
    app.router.add_get("/api/snapshot", handle_snapshot)
    app.router.add_get("/api/ir/set", handle_ir_set)
    app.router.add_post("/api/ir/set", handle_ir_set)
    app.router.add_get("/api/ir/toggle", handle_ir_toggle)
    app.router.add_post("/api/ir/toggle", handle_ir_toggle)
    app.router.add_get("/api/ir/pulse", handle_ir_pulse)
    app.router.add_post("/api/ir/pulse", handle_ir_pulse)
    app.router.add_get("/stream", handle_stream)
    app.router.add_get("/ws", handle_websocket)

    import atexit
    atexit.register(lambda: gateway.ir_controller.set_mode(False))

    logger.info("======================================================")
    logger.info("  🍏 MacHello Linux Camera Gateway 已就绪 (纯硬件网关模式)")
    logger.info(f"  👉 API 状态: http://0.0.0.0:{port}/api/status")
    logger.info(f"  👉 视频流源 (Samba 式数据源): http://0.0.0.0:{port}/stream")
    logger.info(f"  👉 单帧快照: http://0.0.0.0:{port}/api/snapshot")
    logger.info(f"  👉 控制通道: ws://0.0.0.0:{port}/ws")
    logger.info("======================================================")

    web.run_app(app, host="0.0.0.0", port=port)

if __name__ == "__main__":
    main()

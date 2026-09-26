import Foundation
import Combine

public final class LinuxPresenceClient: NSObject, ObservableObject {
    public static let shared = LinuxPresenceClient()

    private let defaultsKeyServerURL = "com.machello.linuxServerURL"
    private let defaultServerURL = "http://192.168.66.5:8765"

    @Published public var isConnected: Bool = false
    @Published public var isServerReachable: Bool = false
    @Published public var isHardwareConnected: Bool = false
    @Published public var serverURLString: String = ""
    @Published public var isPersonPresent: Bool = false
    @Published public var isOwnerPresent: Bool = false
    @Published public var lastConfidence: Float = 0.0
    @Published public var serverLatencyMs: Int = 0

    public var onOwnerArrived: (() -> Void)?
    public var onOwnerDeparted: (() -> Void)?
    public var onStrangerDetected: (() -> Void)?
    public var onStatusChanged: ((_ isConnected: Bool, _ isPresent: Bool, _ isOwner: Bool) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var isRunning: Bool = false

    private override init() {
        let saved = UserDefaults.standard.string(forKey: defaultsKeyServerURL)
        self.serverURLString = (saved?.isEmpty == false) ? saved! : defaultServerURL
        super.init()
    }

    public func setServerURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.serverURLString = trimmed
        UserDefaults.standard.set(trimmed, forKey: defaultsKeyServerURL)

        if isRunning {
            reconnect()
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
    }

    public func stop() {
        isRunning = false
        disconnect()
    }

    private func connect() {
        guard isRunning else { return }
        stopTimers()

        // 规范化 WebSocket URL (将 http(s) 映射为 ws(s))
        guard var components = URLComponents(string: serverURLString) else {
            print("[LinuxClient] 无效的服务端地址: \(serverURLString)")
            scheduleReconnect()
            return
        }

        if components.scheme == "https" {
            components.scheme = "wss"
        } else {
            components.scheme = "ws"
        }
        components.path = "/ws"

        guard let wsURL = components.url else {
            scheduleReconnect()
            return
        }

        print("[LinuxClient] 正在连接局域网 Linux 人体感应服务: \(wsURL)...")
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: OperationQueue())
        let task = session.webSocketTask(with: wsURL)
        self.webSocketTask = task
        task.resume()

        listenForMessages()
        startPingTimer()

        // 发送一次 HTTP 探测测试网络往返延迟
        measureLatency()
    }

    private func disconnect() {
        stopTimers()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isServerReachable = false
            self.isHardwareConnected = false
            self.isConnected = false
            self.onStatusChanged?(false, self.isPersonPresent, self.isOwnerPresent)
        }
    }

    private func reconnect() {
        disconnect()
        connect()
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    private func stopTimers() {
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func sendPing() {
        webSocketTask?.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    print("[LinuxClient] WebSocket Ping 失败: \(error.localizedDescription)")
                    self.isServerReachable = false
                    self.isConnected = false
                    self.scheduleReconnect()
                } else {
                    self.isServerReachable = true
                    if !self.isConnected && self.isHardwareConnected {
                        self.isConnected = true
                        print("[LinuxClient] 已成功建立与 Linux 人体感应服务的实时长连接 ✓")
                    }
                }
            }
        }
    }

    public func measureLatency(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURLString)/api/status") else {
            completion?(false)
            return
        }
        let start = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let isHw = json["is_connected"] as? Bool ?? true
                DispatchQueue.main.async {
                    self.serverLatencyMs = ms
                    self.isServerReachable = true
                    self.isHardwareConnected = isHw
                    let overall = isHw
                    if self.isConnected != overall {
                        self.isConnected = overall
                        self.onStatusChanged?(overall, self.isPersonPresent, self.isOwnerPresent)
                    }
                    completion?(true)
                }
            } else {
                DispatchQueue.main.async {
                    self.isServerReachable = false
                    self.isHardwareConnected = false
                    if self.isConnected {
                        self.isConnected = false
                        self.onStatusChanged?(false, self.isPersonPresent, self.isOwnerPresent)
                    }
                    completion?(false)
                }
            }
        }.resume()
    }

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isRunning else { return }

            switch result {
            case .failure(let error):
                print("[LinuxClient] 接收消息中断: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isServerReachable = false
                    self.isHardwareConnected = false
                    self.isConnected = false
                    self.onStatusChanged?(false, self.isPersonPresent, self.isOwnerPresent)
                }
                self.scheduleReconnect()

            case .success(let message):
                DispatchQueue.main.async {
                    self.isServerReachable = true
                }
                switch message {
                case .string(let text):
                    self.handleJsonMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleJsonMessage(text)
                    }
                @unknown default:
                    break
                }
                // 递归继续监听下一条消息
                self.listenForMessages()
            }
        }
    }

    private func handleJsonMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let eventType = json["event"] as? String ?? json["type"] as? String ?? ""
        if let isHw = json["is_connected"] as? Bool {
            self.isHardwareConnected = isHw
            self.isConnected = self.isServerReachable && isHw
        }
        let isPresent = json["is_present"] as? Bool ?? json["isPresent"] as? Bool ?? false
        let isOwner = json["is_owner"] as? Bool ?? json["isOwner"] as? Bool ?? false
        let confidence = (json["confidence"] as? NSNumber)?.floatValue ?? 0.0

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPersonPresent = isPresent
            self.isOwnerPresent = isOwner
            self.lastConfidence = confidence

            switch eventType {
            case "owner_arrived":
                self.onOwnerArrived?()
            case "owner_departed":
                self.onOwnerDeparted?()
            case "stranger_present":
                self.onStrangerDetected?()
            default:
                break
            }

            self.onStatusChanged?(true, isPresent, isOwner)
        }
    }

    /// 向 Linux 服务端上报 Mac 用户按键/鼠标活动心跳（让远端立即释放摄像头熄灭指示灯）
    public func sendUserActivity() {
        guard isConnected else { return }
        let msg = URLSessionWebSocketTask.Message.string("{\"type\":\"user_active\"}")
        webSocketTask?.send(msg) { _ in }
    }

    /// 向 Linux 服务端上报系统锁屏状态
    public func sendScreenLockedState(isLocked: Bool) {
        guard isConnected else { return }
        let msg = URLSessionWebSocketTask.Message.string("{\"type\":\"screen_locked\",\"is_locked\":\(isLocked)}")
        webSocketTask?.send(msg) { _ in }
    }

    /// 远程显式设置 Linux 摄像头的红外模式 (RGB / IR)
    public func setIRMode(isIR: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURLString)/api/ir/set?ir=\(isIR ? 1 : 0)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let irActive = json["ir_active"] as? Bool {
                DispatchQueue.main.async {
                    MacHelloService.shared.isIRActive = irActive
                    completion?(irActive)
                }
            }
        }.resume()
    }

    /// 远程切换 Linux 摄像头的红外灯
    public func toggleIR(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURLString)/api/ir/toggle") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let irActive = json["ir_active"] as? Bool {
                DispatchQueue.main.async {
                    completion?(irActive)
                }
            }
        }.resume()
    }
}

import Foundation
import AppKit

public final class AudioFeedbackHelper {
    public static let shared = AudioFeedbackHelper()

    private let successSound: NSSound?

    private init() {
        // 使用 macOS 原生高质感短促提示音 Tink
        self.successSound = NSSound(named: "Tink")
    }

    /// 播放 Face ID 认证成功提示音
    public func playSuccess() {
        DispatchQueue.main.async { [weak self] in
            self?.successSound?.stop()
            self?.successSound?.play()
        }
    }
}

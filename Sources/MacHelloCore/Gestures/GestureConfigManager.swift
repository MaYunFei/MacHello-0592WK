import Foundation

public final class GestureConfigManager: ObservableObject {
    public static let shared = GestureConfigManager()

    @Published public var rules: [HandGestureType: GestureRule] = [:]
    @Published public var isTypingProtectionEnabled: Bool = true

    private let fileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".machello", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gestures.json")
    }()

    private let defaultsKeyTypingProtection = "com.machello.gestureTypingProtection"

    private init() {
        self.isTypingProtectionEnabled = UserDefaults.standard.object(forKey: defaultsKeyTypingProtection) == nil ? true : UserDefaults.standard.bool(forKey: defaultsKeyTypingProtection)
        load()
    }

    public func setTypingProtection(_ enabled: Bool) {
        self.isTypingProtectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKeyTypingProtection)
    }

    public func rule(for gesture: HandGestureType) -> GestureRule {
        return rules[gesture] ?? defaultRule(for: gesture)
    }

    public func updateRule(for gesture: HandGestureType, action: GestureActionType, appName: String = "Music") {
        rules[gesture] = GestureRule(action: action, appName: appName)
        save()
    }

    public func resetToDefaults() {
        rules = defaultRules
        save()
    }

    private var defaultRules: [HandGestureType: GestureRule] {
        return [
            .openPalm:      GestureRule(action: .sleepDisplay),
            .indexFingerUp: GestureRule(action: .toggleMute),
            .fist:          GestureRule(action: .mediaPlayPause),
            .swipeLeft:     GestureRule(action: .mediaNext),
            .swipeRight:    GestureRule(action: .mediaPrevious),
            .swipeUp:       GestureRule(action: .missionControl),
            .circle:        GestureRule(action: .volumeUp),
            .fingerHeart:   GestureRule(action: .launchApp, appName: "Music"),
            .victory:       GestureRule(action: .screenshot),
            .thumbsUp:      GestureRule(action: .none)
        ]
    }

    private func defaultRule(for gesture: HandGestureType) -> GestureRule {
        return defaultRules[gesture] ?? GestureRule(action: .none)
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HandGestureType: GestureRule].self, from: data) else {
            self.rules = defaultRules
            save()
            return
        }
        var merged = defaultRules
        for (k, v) in decoded {
            merged[k] = v
        }
        self.rules = merged
    }

    public func save() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: fileURL)
        }
    }
}

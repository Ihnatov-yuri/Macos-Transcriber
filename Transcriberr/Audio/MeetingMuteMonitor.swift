import AppKit
import ApplicationServices

/// Watches the meeting app's own mute control while a meeting is recorded.
///
/// macOS has no API for another app's mute, and muting in a call does not
/// close the microphone, so the only place the state exists is the app's
/// interface: the button says "Unmute" while muted. Read through the
/// Accessibility permission dictation already holds.
///
/// Fails open: no app, no button or no permission reads as nil, and nil means
/// the mic is left in. A missed mute costs some room noise, handled later;
/// a false one would cost the user's words.
nonisolated final class MeetingMuteMonitor: @unchecked Sendable {
    struct Reading: Equatable, Sendable {
        var app: String
        var muted: Bool
    }

    static let enabledKey = "ui.followMeetingMute"
    static var isEnabled: Bool {
        // Never under the test host: the suite must not read a real call.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// `window`: look only inside windows whose title has this in it. A
    /// browser's other pages are none of this code's business, and walking
    /// them every few seconds would be slow. A browser exposes only the tab
    /// in front, so Meet in a background tab reads as nil: mic left in.
    static let apps: [(id: String, name: String, window: String?)] = [
        ("com.microsoft.teams2", "Teams", nil),
        ("com.microsoft.teams", "Teams", nil),
        ("us.zoom.xos", "Zoom", nil),
        ("com.google.Chrome", "Google Meet", "Meet"),
        ("com.microsoft.edgemac", "Google Meet", "Meet"),
        ("com.brave.Browser", "Google Meet", "Meet"),
        ("company.thebrowser.Browser", "Google Meet", "Meet"),
        ("com.apple.Safari", "Google Meet", "Meet"),
    ]

    private static let labelPattern = try! NSRegularExpression(
        pattern: #"^(un)?mute(\s+(mic|microphone|audio|my\s+microphone))?(\s*[(,:].*)?$"#,
        options: [.caseInsensitive])

    /// Google Meet says "Turn on microphone" while muted. Anchored too: a
    /// host also has "Turn off microphone for everyone".
    private static let meetPattern = try! NSRegularExpression(
        pattern: #"^turn (on|off) (the )?microphone(\s*[(,:].*)?$"#,
        options: [.caseInsensitive])

    /// True for a control offering to unmute (so: muted), false for one
    /// offering to mute, nil for anything else. Anchored, because the same
    /// window has "Mute all" and "Mute <someone's name>".
    static func parseLabel(_ label: String) -> Bool? {
        let s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(s.startIndex..., in: s)
        if let m = meetPattern.firstMatch(in: s, range: range), let on = Range(m.range(at: 1), in: s) {
            return s[on].lowercased() == "on"
        }
        guard let m = labelPattern.firstMatch(in: s, range: range) else { return nil }
        return m.range(at: 1).location != NSNotFound
    }

    private let queue = DispatchQueue(label: "meeting.mute.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var control: AXUIElement?
    private var controlApp = ""
    private var lastScan = Date.distantPast
    private var last: Reading?
    private var loggedMisses = false
    private var loggedFound = false
    private var enabledPIDs = Set<pid_t>()
    private var onChange: (@Sendable (Reading?) -> Void)?

    private static let pollSeconds = 1.0
    private static let rescanSeconds = 3.0
    private static let scanBudgetSeconds = 2.0
    private static let maxNodes = 6000
    private static let maxDepth = 60
    private static let axTimeout: Float = 0.25

    func start(onChange: @escaping @Sendable (Reading?) -> Void) {
        queue.async { [self] in
            guard timer == nil else { return }
            guard AXIsProcessTrusted() else {
                AppLog.warn("mute", "no Accessibility permission: cannot follow the meeting's mute")
                return
            }
            self.onChange = onChange
            last = nil; control = nil; lastScan = .distantPast
            loggedMisses = false; loggedFound = false
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.pollSeconds, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            control = nil
            onChange = nil
        }
    }

    private func poll() {
        var reading = readControl()
        if reading == nil, Date().timeIntervalSince(lastScan) >= Self.rescanSeconds {
            lastScan = Date()
            reading = scan()
        }
        guard reading != last else { return }
        last = reading
        AppLog.info("mute", reading.map { "\($0.app): \($0.muted ? "muted" : "unmuted")" } ?? "no mute control in view")
        onChange?(reading)
    }

    private func readControl() -> Reading? {
        guard let control else { return nil }
        if let muted = Self.state(of: control) { return Reading(app: controlApp, muted: muted) }
        self.control = nil
        return nil
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func labels(_ e: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attr(e, $0) as? String }.filter { !$0.isEmpty }
    }

    private static func state(of e: AXUIElement) -> Bool? {
        labels(e).lazy.compactMap(parseLabel).first
    }

    private func scan() -> Reading? {
        for app in Self.apps {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first else { continue }
            let root = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(root, Self.axTimeout)
            // Teams draws its call in a web view, whose tree exists only
            // once something asks for it.
            if enabledPIDs.insert(running.processIdentifier).inserted {
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if app.window != nil {
                    AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                }
            }
            var roots = [root]
            if let wanted = app.window {
                roots = ((Self.attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter {
                    (Self.attr($0, kAXTitleAttribute) as? String)?.contains(wanted) == true
                }
            }
            var nodes = 0
            var near: [String] = []
            let deadline = Date().addingTimeInterval(Self.scanBudgetSeconds)
            for window in roots {
                guard let found = find(window, depth: 0, nodes: &nodes, near: &near, deadline: deadline),
                      let muted = Self.state(of: found) else { continue }
                control = found
                controlApp = app.name
                if !loggedFound { loggedFound = true; AppLog.info("mute", "following the mute control in \(app.name)") }
                return Reading(app: app.name, muted: muted)
            }
            if !loggedMisses, !near.isEmpty {
                // Interface wording changes: what to match next, for the log.
                loggedMisses = true
                AppLog.info("mute", "\(app.name): \(nodes) elements, no mute control; nearest labels: \(near.prefix(8).joined(separator: " / "))")
            }
        }
        return nil
    }

    private func find(_ e: AXUIElement, depth: Int, nodes: inout Int, near: inout [String], deadline: Date) -> AXUIElement? {
        nodes += 1
        guard nodes <= Self.maxNodes, depth <= Self.maxDepth, Date() < deadline else { return nil }
        let role = Self.attr(e, kAXRoleAttribute) as? String ?? ""
        if ["AXButton", "AXCheckBox", "AXMenuItem", "AXToggle", "AXSwitch"].contains(role) {
            if Self.state(of: e) != nil { return e }
            if near.count < 8, let l = Self.labels(e).first(where: {
                $0.range(of: #"\b(mic|microphone)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            }) { near.append(String(l.prefix(40))) }
        }
        for child in (Self.attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let hit = find(child, depth: depth + 1, nodes: &nodes, near: &near, deadline: deadline) { return hit }
        }
        return nil
    }
}

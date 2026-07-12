import AppKit
import UserNotifications
import CoreGraphics
import ServiceManagement

/// Menu bar controller that measures continuous screen-watching time and reminds
/// you to rest your eyes following the 20-20-20 rule.
final class AppController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Configuration (seconds)

    /// How long you may watch the screen before a break becomes due.
    private var workInterval: TimeInterval = 20 * 60
    /// Idle time that counts as a completed eye break (the "20 seconds" of 20-20-20).
    private let breakDuration: TimeInterval = 20
    /// Idle time that means you stepped away, so the watch timer resets to zero.
    private let awayThreshold: TimeInterval = 3 * 60
    /// If a due break is ignored, remind again after this long.
    private let reNotifyInterval: TimeInterval = 5 * 60

    private let intervalChoices = [15, 20, 25, 30, 45, 60]

    // MARK: - State

    private enum Mode { case watching, breakDue }
    private var mode: Mode = .watching
    private var watched: TimeInterval = 0
    private var paused = false
    private var lastTick = Date()
    private var lastNotify = Date(timeIntervalSince1970: 0)
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: - UI

    private var statusItem: NSStatusItem!
    private var headerItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var launchItem: NSMenuItem!
    private var intervalItems: [NSMenuItem] = []
    private var timer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedMinutes = UserDefaults.standard.integer(forKey: "workIntervalMinutes")
        if savedMinutes > 0 { workInterval = TimeInterval(savedMinutes * 60) }

        setupStatusItem()
        setupNotifications()

        lastTick = Date()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateUI()
    }

    // MARK: - Timer tick

    @objc private func tick() {
        defer { updateUI() }

        let now = Date()
        var delta = now.timeIntervalSince(lastTick)
        lastTick = now
        if paused { return }
        delta = min(delta, 5) // guard against sleep/wake jumps

        let idle = systemIdleSeconds()

        switch mode {
        case .watching:
            if idle >= awayThreshold {
                watched = 0 // stepped away; start fresh on return
            } else {
                watched += delta
                if watched >= workInterval {
                    mode = .breakDue
                    sendBreakNotification()
                }
            }
        case .breakDue:
            if idle >= breakDuration {
                mode = .watching // you rested your eyes
                watched = 0
            } else if now.timeIntervalSince(lastNotify) >= reNotifyInterval {
                sendBreakNotification()
            }
        }
    }

    /// Seconds since the last keyboard/mouse input, system-wide. Requires no permissions.
    private func systemIdleSeconds() -> TimeInterval {
        // ~0 (0xFFFFFFFF) is kCGAnyInputEventType: idle time across every input event.
        let anyInput = CGEventType(rawValue: ~UInt32(0))!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: - Notifications

    private func setupNotifications() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error = error { NSLog("Notification authorization error: \(error)") }
        }
    }

    private func sendBreakNotification() {
        lastNotify = Date()
        NSSound(named: "Glass")?.play()
        NSApp.requestUserAttention(.criticalRequest)

        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to rest your eyes"
        content.body = "You've watched the screen for \(Int(workInterval / 60)) minutes. "
            + "Look about 20 feet (6 m) away for 20 seconds."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let menu = NSMenu()

        headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(headerItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Reset Timer", action: #selector(resetTimer), keyEquivalent: "r"))

        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(pauseItem)

        let intervalParent = NSMenuItem(title: "Break Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for minutes in intervalChoices {
            let item = NSMenuItem(title: "\(minutes) minutes", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.representedObject = minutes
            item.target = self
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        intervalParent.submenu = intervalMenu
        menu.addItem(intervalParent)

        menu.addItem(.separator())

        launchItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem(title: "Quit EyeHealth", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }

        statusItem.menu = menu
    }

    private func updateUI() {
        guard let button = statusItem?.button else { return }

        let symbol: String
        let title: String
        let header: String

        if paused {
            symbol = "pause.circle"
            title = "Paused"
            header = "Timer paused"
        } else if mode == .breakDue {
            symbol = "exclamationmark.triangle.fill"
            title = "Rest"
            header = "Break due — look away for 20 seconds"
        } else {
            symbol = "eye"
            let remaining = max(0, workInterval - watched)
            title = fmt(remaining)
            header = "Next break in \(fmt(remaining))"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image?.isTemplate = true
        button.image = image
        button.title = " " + title

        headerItem.title = header
        pauseItem.title = paused ? "Resume" : "Pause"
        for item in intervalItems {
            if let minutes = item.representedObject as? Int {
                item.state = (Int(workInterval / 60) == minutes) ? .on : .off
            }
        }
        launchItem.state = launchAtLoginEnabled ? .on : .off
    }

    private func fmt(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Actions

    @objc private func resetTimer() {
        watched = 0
        mode = .watching
        lastTick = Date()
        updateUI()
    }

    @objc private func togglePause() {
        paused.toggle()
        lastTick = Date()
        updateUI()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        workInterval = TimeInterval(minutes * 60)
        UserDefaults.standard.set(minutes, forKey: "workIntervalMinutes")
        watched = 0
        mode = .watching
        updateUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Open at login

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("Open at Login toggle failed: \(error)")
            }
        }
        updateUI()
    }
}

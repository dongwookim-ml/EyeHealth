import AppKit
import UserNotifications
import CoreGraphics
import ServiceManagement
import IOKit.ps

/// Menu bar controller that measures continuous screen-watching time and reminds
/// you to rest your eyes following the 20-20-20 rule.
///
/// "Watching" is derived from two signals: recent keyboard/mouse input, and, when
/// input is idle, the webcam (via `CameraMonitor`) detecting a face facing the
/// screen. This keeps the timer running while you read a static page without
/// touching the computer. Camera use follows the power source: continuous while
/// plugged in, idle-triggered only on battery.
final class AppController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {

    // MARK: - Configuration (seconds)

    /// How long you may watch the screen before a break becomes due.
    private var workInterval: TimeInterval = 20 * 60
    /// Looking away this long counts as a completed eye break and resets the clock.
    private let breakDuration: TimeInterval = 20
    /// Idle below this means recent input, so you are clearly at the screen.
    private let inputActiveThreshold: TimeInterval = 15
    /// If a due break is ignored, remind again after this long.
    private let reNotifyInterval: TimeInterval = 5 * 60
    /// Grace right after the camera starts, before it has produced a frame.
    private let cameraWarmup: TimeInterval = 3
    /// A face detection stays valid for this long after it was last seen.
    private let faceStale: TimeInterval = 5
    /// On battery, keep the camera on this long after input resumes (anti-flicker).
    private let cameraOffDelay: TimeInterval = 3
    /// Without a camera, treat idle up to this as still watching.
    private let fallbackAwayThreshold: TimeInterval = 3 * 60

    private let intervalChoices = [15, 20, 25, 30, 45, 60]

    // MARK: - State

    private enum Mode { case watching, breakDue }
    private var mode: Mode = .watching
    private var watched: TimeInterval = 0
    private var notLooking: TimeInterval = 0
    private var paused = false
    private var lastTick = Date()
    private var lastNotify = Date(timeIntervalSince1970: 0)
    private var onAC = true

    private var useCamera = true
    private let camera = CameraMonitor()
    private var preferredCameraID: String?
    private var lastFrameAt = Date(timeIntervalSince1970: 0)
    private var lastDetection = CameraMonitor.Detection(facePresent: false, frontal: false)
    private var cameraStartedAt = Date(timeIntervalSince1970: 0)
    private var cameraStopPendingSince: Date?

    /// With one display the camera sits in the screen you watch, so head
    /// orientation is meaningful. With several displays it is not: looking at
    /// the main external monitor turns your head away from the built-in camera.
    private var multiDisplay: Bool { NSScreen.screens.count > 1 }

    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: - UI

    private var statusItem: NSStatusItem!
    private var headerItem: NSMenuItem!
    private var cameraInfoItem: NSMenuItem!
    private var detectionInfoItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var cameraToggleItem: NSMenuItem!
    private var cameraDeviceMenu: NSMenu!
    private var launchItem: NSMenuItem!
    private var intervalItems: [NSMenuItem] = []
    private var timer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedMinutes = UserDefaults.standard.integer(forKey: "workIntervalMinutes")
        if savedMinutes > 0 { workInterval = TimeInterval(savedMinutes * 60) }
        if UserDefaults.standard.object(forKey: "useCamera") != nil {
            useCamera = UserDefaults.standard.bool(forKey: "useCamera")
        }

        if let savedCamera = UserDefaults.standard.string(forKey: "cameraDeviceID") {
            preferredCameraID = savedCamera
            camera.setPreferredDevice(savedCamera)
        }

        camera.onResult = { [weak self] detection in
            guard let self = self else { return }
            self.lastFrameAt = Date()
            self.lastDetection = detection
        }

        setupStatusItem()
        setupNotifications()
        if useCamera { camera.requestAccess { [weak self] _ in self?.updateUI() } }

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

        onAC = powerIsAC()
        let idle = systemIdleSeconds()
        let recentInput = idle < inputActiveThreshold

        reconcileCamera(recentInput: recentInput, now: now)
        let looking = isLookingAtScreen(recentInput: recentInput, idle: idle, now: now)

        if looking {
            notLooking = 0
            switch mode {
            case .watching:
                watched += delta
                if watched >= workInterval {
                    mode = .breakDue
                    sendBreakNotification()
                }
            case .breakDue:
                if now.timeIntervalSince(lastNotify) >= reNotifyInterval { sendBreakNotification() }
            }
        } else {
            notLooking += delta
            if notLooking >= breakDuration {
                watched = 0
                mode = .watching // you rested your eyes
            }
        }
    }

    /// True when you are watching the screen: recent input, or the webcam sees
    /// you while input is idle. With one display "sees you" means a face facing
    /// the screen; with several displays any visible face counts, because
    /// watching the main external monitor turns your head away from the camera.
    private func isLookingAtScreen(recentInput: Bool, idle: TimeInterval, now: Date) -> Bool {
        if recentInput { return true }
        if useCamera && camera.isAuthorized && camera.isRunning {
            if now.timeIntervalSince(cameraStartedAt) < cameraWarmup { return true } // still warming up
            if now.timeIntervalSince(lastFrameAt) < faceStale {
                return multiDisplay ? lastDetection.facePresent : lastDetection.frontal
            }
            return false // no fresh frame with a face
        }
        return idle < fallbackAwayThreshold // no camera: fall back to idle time
    }

    /// Starts/stops the camera to match the power-based policy: always on while
    /// plugged in, only after input goes idle while on battery.
    private func reconcileCamera(recentInput: Bool, now: Date) {
        let shouldRun = useCamera && camera.isAuthorized && (onAC || !recentInput)
        if shouldRun {
            cameraStopPendingSince = nil
            if !camera.isRunning {
                camera.start()
                cameraStartedAt = now
            }
        } else if camera.isRunning {
            if let since = cameraStopPendingSince {
                if now.timeIntervalSince(since) >= cameraOffDelay { camera.stop(); cameraStopPendingSince = nil }
            } else {
                cameraStopPendingSince = now
            }
        }
    }

    /// Seconds since the last keyboard/mouse input, system-wide. Needs no permission.
    private func systemIdleSeconds() -> TimeInterval {
        // ~0 (0xFFFFFFFF) is kCGAnyInputEventType: idle across every input event.
        let anyInput = CGEventType(rawValue: ~UInt32(0))!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func powerIsAC() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String? else { return true }
        return type == (kIOPSACPowerValue as String)
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
        cameraInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(cameraInfoItem)
        detectionInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(detectionInfoItem)
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

        cameraToggleItem = NSMenuItem(title: "Use Camera", action: #selector(toggleUseCamera), keyEquivalent: "")
        menu.addItem(cameraToggleItem)

        let deviceParent = NSMenuItem(title: "Camera Device", action: nil, keyEquivalent: "")
        cameraDeviceMenu = NSMenu()
        cameraDeviceMenu.delegate = self // repopulated on open
        deviceParent.submenu = cameraDeviceMenu
        menu.addItem(deviceParent)

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
        cameraInfoItem.title = cameraStatusText()
        detectionInfoItem.title = detectionModeText()
        pauseItem.title = paused ? "Resume" : "Pause"
        cameraToggleItem.state = useCamera ? .on : .off
        for item in intervalItems {
            if let minutes = item.representedObject as? Int {
                item.state = (Int(workInterval / 60) == minutes) ? .on : .off
            }
        }
        launchItem.state = launchAtLoginEnabled ? .on : .off
    }

    private func cameraStatusText() -> String {
        if !useCamera { return "Camera: off (input only)" }
        if camera.permissionDenied { return "Camera: permission denied" }
        if !camera.isAuthorized { return "Camera: awaiting permission" }
        if onAC { return "Camera: always on (plugged in)" }
        return camera.isRunning ? "Camera: checking (idle)" : "Camera: idle-only (battery)"
    }

    private func detectionModeText() -> String {
        guard useCamera && camera.isAuthorized else { return "Detection: input only" }
        return multiDisplay ? "Detection: any visible face (multi-display)"
                            : "Detection: face facing screen"
    }

    // MARK: - Camera device picker

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == cameraDeviceMenu else { return }
        menu.removeAllItems()

        let auto = NSMenuItem(title: "Automatic", action: #selector(selectCameraDevice(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = (preferredCameraID == nil) ? .on : .off
        menu.addItem(auto)

        for cam in CameraMonitor.availableCameras() {
            let item = NSMenuItem(title: cam.name, action: #selector(selectCameraDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cam.id
            item.state = (preferredCameraID == cam.id) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectCameraDevice(_ sender: NSMenuItem) {
        preferredCameraID = sender.representedObject as? String
        if let id = preferredCameraID {
            UserDefaults.standard.set(id, forKey: "cameraDeviceID")
        } else {
            UserDefaults.standard.removeObject(forKey: "cameraDeviceID")
        }
        camera.setPreferredDevice(preferredCameraID)
    }

    private func fmt(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Actions

    @objc private func resetTimer() {
        watched = 0
        notLooking = 0
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

    @objc private func toggleUseCamera() {
        useCamera.toggle()
        UserDefaults.standard.set(useCamera, forKey: "useCamera")
        if useCamera {
            camera.requestAccess { [weak self] _ in self?.updateUI() }
        } else {
            camera.stop()
        }
        updateUI()
    }

    @objc private func quit() {
        camera.stop()
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

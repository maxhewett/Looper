import AppKit
import Darwin
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSMenuDelegate, NSApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var isInstalling = false
    private var messageWindows: [NSWindow] = []
    private var normalStatusImage: NSImage?
    private var busyStatusFrames: [NSImage] = []
    private var busyFrameIndex = 0
    private var busyTimer: Timer?
    private var menuTimer: Timer?
    private var reportedActivity: String?
    private var hasQueuedRequest = false
    private var windowController: StatusWindowController?
    private var statusWindowController: StatusWindowController {
        if let windowController { return windowController }
        let controller = StatusWindowController()
        windowController = controller
        return controller
    }
    private var stateModificationDate: Date?
    private var failureDetail: String?
    private lazy var warningImage: NSImage? = {
        guard let icon = normalStatusImage else { return nil }
        let image = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            NSColor.systemRed.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Template rendering lets macOS tint the glyph correctly in light mode,
        // dark mode, high contrast, and menu bar highlight states.
        UNUserNotificationCenter.current().delegate = self
        try? MusicAppsContentStore.connectSharedLibrary()
        // Notification Center resolves the sender artwork through Launch Services.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, UserDefaults.standard.string(forKey: "RegisteredIconBuild") != build,
           LSRegisterURL(Bundle.main.bundleURL as CFURL, true) == noErr {
            UserDefaults.standard.set(build, forKey: "RegisteredIconBuild")
        }
        loadStatusImages()
        setProcessing(false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(processingStateChanged(_:)),
            name: .looperProcessingStateDidChange,
            object: nil
        )
        observeHelperState()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.observeHelperState()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        rebuildMenu()

        if CommandLine.arguments.contains("--open-window") ||
            (!UserDefaults.standard.bool(forKey: "SetupAssistantCompleted") && !LooperSettingsStore.skipSetupAssistant) {
            openLooper()
        }
    }

    private func observeHelperState() {
        let url = LooperPaths().stateFile
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard modified != stateModificationDate else { return }
        stateModificationDate = modified
        if let windowController {
            windowController.refreshHelperProgress()
        } else {
            let state = try? StateStore(url: url).load()
            let run = state?.currentRun
            let active = run?.isRunning == true && run?.isStale == false
            hasQueuedRequest = PendingRequestStore.loadAll(in: LooperPaths().requestDirectory).runRequestedAt != nil
            failureDetail = state?.attentionDetail
            setProcessing(active, percent: run?.overallPercent)
            if menuTimer == nil { rebuildMenu() }
        }
    }

    @objc private func showFailureLog() { statusWindowController.showLogging() }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let activitySummary = reportedActivity ?? Self.menuActivitySummary()
        let helperIsActive = !Self.canStartRun(activitySummary)
        let activityItem = NSMenuItem(title: activitySummary, action: nil, keyEquivalent: "")
        activityItem.isEnabled = false
        menu.addItem(activityItem)
        let logItem = NSMenuItem(title: "Show failure in Logging…", action: #selector(showFailureLog), keyEquivalent: "")
        logItem.isHidden = failureDetail == nil
        logItem.toolTip = failureDetail
        menu.addItem(logItem)
        menu.addItem(NSMenuItem.separator())

        let runItem = NSMenuItem(title: hasQueuedRequest ? activitySummary : ((isInstalling || helperIsActive) ? "Running..." : "Run Now"), action: #selector(runNow), keyEquivalent: "r")
        runItem.isEnabled = !isInstalling && !helperIsActive
        menu.addItem(runItem)

        menu.addItem(NSMenuItem(title: "Open Looper...", action: #selector(openLooper), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Run at Login", action: #selector(toggleRunAtLogin), keyEquivalent: "")
        updateLoginItem(loginItem)
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Looper", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func runNow() {
        if geteuid() != 0 {
            statusWindowController.runFromMenu()
            return
        }
        isInstalling = true
        setProcessing(true)
        rebuildMenu()

        Task { [weak self] in
            let title: String
            let message: String
            do {
                let summary = try await LoopInstaller().reconcile()
                let prompter = UserPrompter()
                await prompter.notifyInstalledPackages(summary.installed)
                await prompter.notifyRelaunchRecommended(appNames: Self.runningSupportedAudioApps())
                title = "Looper Finished"
                message = Self.installMessage(for: summary)
            } catch {
                title = "Looper Could Not Run"
                message = String(describing: error)
            }

            DispatchQueue.main.async {
                self?.isInstalling = false
                self?.setProcessing(false)
                self?.rebuildMenu()
                self?.showMessage(title, message)
            }
        }
    }

    @objc private func openLooper() {
        DispatchQueue.main.async { [weak self] in
            self?.statusWindowController.show()
        }
    }

    private var loginIsManaged: Bool {
        if LooperApp.packagedLoginAgent && UserDefaults.standard.objectIsForced(forKey: "RunAtLogin") { return true }
        let key = "AutoLaunchedApplicationDictionary-managed" as CFString
        let domain = "com.apple.loginitems.managed" as CFString
        guard CFPreferencesAppValueIsForced(key, domain),
              let items = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else {
            return false
        }
        let appURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        return items.contains { item in
            guard let path = item["Path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == appURL.path
        }
    }

    private func updateLoginItem(_ item: NSMenuItem) {
        let managed = loginIsManaged
        item.title = managed ? "Run at Login (managed)" : "Run at Login"
        item.isEnabled = !managed
        item.state = (LooperApp.packagedLoginAgent ? LooperApp.runAtLogin : (managed || SMAppService.mainApp.status == .enabled)) ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateActivity(in: menu)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak menu] _ in
            MainActor.assumeIsolated {
                if let menu { self?.updateActivity(in: menu) }
            }
        }
        menuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func updateActivity(in menu: NSMenu) {
        let activity = Self.menuActivitySummary(idle: reportedActivity ?? "Idle")
        menu.items.first?.title = activity
        if let item = menu.items.first(where: { $0.action == #selector(showFailureLog) }) {
            item.isHidden = failureDetail == nil
            item.toolTip = failureDetail
        }
        if let item = menu.items.first(where: { $0.action == #selector(runNow) }) {
            item.isEnabled = !isInstalling && Self.canStartRun(activity)
            item.title = "Run Now"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = menu.items.first(where: { $0.action == #selector(toggleRunAtLogin) }) {
            updateLoginItem(item)
        }
    }

    @objc private func toggleRunAtLogin() {
        guard !loginIsManaged else { return }
        do {
            if LooperApp.packagedLoginAgent {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                UserDefaults.standard.set(!LooperApp.runAtLogin, forKey: "RunAtLogin")
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            rebuildMenu()
        } catch {
            showMessage("Run at Login", String(describing: error))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showMessage(_ title: String, _ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showMessage(title, message)
            }
            return
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        let messageView = NSTextView()
        messageView.string = message
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.drawsBackground = false
        messageView.textContainerInset = NSSize(width: 0, height: 0)
        messageView.font = .systemFont(ofSize: 13)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = messageView

        let okButton = NSButton(title: "OK", target: self, action: #selector(closeMessageWindow))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [okButton])
        buttonRow.alignment = .trailing
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 240))
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            okButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = contentView
        window.isReleasedWhenClosed = false

        messageWindows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func closeMessageWindow(_ sender: NSButton) {
        guard let window = sender.window else {
            return
        }

        window.close()
        messageWindows.removeAll { $0 === window }
    }

    private static func installMessage(for summary: InstallSummary) -> String {
        var lines = [
            "Installed: \(summary.installed.count)",
            "Skipped: \(summary.skipped.count)",
            "Failed: \(summary.failed.count)"
        ]

        for (package, error) in summary.failed {
            lines.append("\(package.displayName): \(error)")
        }

        return lines.joined(separator: "\n")
    }

    private static func runningSupportedAudioApps() -> [String] {
        let supportedApps: [String: String] = [
            "com.apple.garageband10": "GarageBand",
            "com.apple.logic10": "Logic Pro",
        ]
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard let identifier = application.bundleIdentifier else { return nil }
            return supportedApps[identifier]
        }
    }

    private func loadStatusImages() {
        normalStatusImage = NSImage(named: "LooperMenu")
        busyStatusFrames = (0..<16).compactMap { index in
            NSImage(named: String(format: "LooperMenuDownload%02d", index))
        }
    }

    private func setProcessing(_ isProcessing: Bool, percent: Int? = nil) {
        let percentageText = percent.map { "\($0)%" } ?? ""
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            button.imagePosition = percentageText.isEmpty ? .imageOnly : .imageLeading
            button.title = percentageText
            button.setAccessibilityLabel(percent.map { "Looper, \($0) percent of run complete" } ?? failureDetail ?? "Looper")
        }
        statusItem.button?.toolTip = failureDetail ?? "Looper"
        if !isProcessing, (!hasQueuedRequest || reportedActivity == "Helper unavailable"), failureDetail != nil, let warningImage {
            stopBusyAnimation()
            statusItem.button?.image = warningImage
            return
        }
        if isProcessing, !busyStatusFrames.isEmpty {
            startBusyAnimation()
            return
        }

        stopBusyAnimation()
        if let normalStatusImage {
            statusItem.button?.image = normalStatusImage
        } else {
            statusItem.button?.image = nil
            statusItem.button?.imagePosition = .noImage
            statusItem.button?.title = percentageText.isEmpty ? "Looper" : percentageText
        }
    }

    private func startBusyAnimation() {
        guard busyTimer == nil else {
            return
        }

        busyFrameIndex = 0
        statusItem.button?.image = busyStatusFrames.first

        busyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            guard let self, !self.busyStatusFrames.isEmpty else {
                return
            }
            self.busyFrameIndex = (self.busyFrameIndex + 1) % self.busyStatusFrames.count
            self.statusItem.button?.image = self.busyStatusFrames[self.busyFrameIndex]
        }
        RunLoop.main.add(busyTimer!, forMode: .common)
    }

    private func stopBusyAnimation() {
        busyTimer?.invalidate()
        busyTimer = nil
        busyFrameIndex = 0
    }

    @objc private func processingStateChanged(_ notification: Notification) {
        let active = notification.userInfo?["isProcessing"] as? Bool ?? false
        let title = notification.userInfo?["activityTitle"] as? String
        hasQueuedRequest = notification.userInfo?["queued"] as? Bool ?? false
        let activity = title == "Idle" ? nil : title
        let previousFailure = failureDetail
        failureDetail = notification.userInfo?["failureDetail"] as? String
        let changed = reportedActivity != activity || previousFailure != failureDetail
        reportedActivity = activity
        setProcessing(active || isInstalling, percent: notification.userInfo?["overallPercent"] as? Int)
        if changed, menuTimer == nil { rebuildMenu() }
    }

    private static func canStartRun(_ activity: String) -> Bool {
        activity.hasPrefix("Idle") || activity == "Needs attention"
    }

    private static func menuActivitySummary(idle: String? = nil) -> String {
        let state = (try? StateStore(url: LooperPaths().stateFile).load()) ?? InstallState()
        guard let run = state.currentRun, run.isRunning, !Self.runIsStale(run) else {
            let requests = PendingRequestStore.loadAll(in: LooperPaths().requestDirectory)
            if requests.runRequestedAt != nil {
                return "Queued"
            }
            if state.attentionDetail != nil { return "Needs attention" }
            return idle ?? "Idle - \(installedAvailabilitySummary())"
        }

        let total = max(run.totalPackages, 0)
        let percent = run.overallPercent ?? 0
        let phase: String
        let requests = PendingRequestStore.loadAll(in: LooperPaths().requestDirectory)
        let message = run.message.lowercased()
        if requests.stopRequestedAt != nil {
            phase = "Stopping"
        } else if message.contains("planning") || message.contains("preparing") {
            phase = "Planning"
        } else if message.contains("download") {
            phase = "Downloading"
        } else if message.contains("install") {
            phase = "Installing"
        } else {
            phase = "Running"
        }

        if total > 0 {
            var detail = phase
            if let name = run.currentPackageName { detail += " " + name }
            if phase == "Downloading", let received = run.receivedBytes, let expected = run.expectedBytes, expected > 0 {
                detail += " (\(Int((min(1, max(0, Double(received) / Double(expected))) * 100).rounded()))%)"
            }
            return "\(detail) · \(run.completedPackages)/\(total) complete (\(percent)%)"
        }
        return "\(phase)..."
    }

    private static func installedAvailabilitySummary() -> String {
        let paths = LooperPaths()
        let receipts = PackageInstaller().installedAppleAudioContent()
        let receiptIDs = Set(receipts.map(\.identifier))
        let receiptVersions = Dictionary(uniqueKeysWithValues: receipts.compactMap { receipt -> (String, String)? in
            guard let version = receipt.packageVersion else { return nil }
            return (receipt.identifier, version)
        })
        let state = (try? StateStore(url: paths.stateFile).load()) ?? InstallState()
        let stateIDs = Set(state.installedPackages.keys)
        let stateReceipts = Set(state.installedPackages.values.compactMap(\.pkgIdentifier))
        let musicAppsInstalledIDs = MusicAppsContentStore().installedPackageIDs()

        let manifest = (try? ManifestLoader.load(from: windowCatalogueCacheURL(paths: paths)))
            ?? (try? ManifestLoader.load(from: LooperPaths.defaultManifestURL))
            ?? AppleContentDiscovery.discoveredReceiptManifest(receipts: receipts)
        let installed = manifest.packages.reduce(into: Set<String>()) { identifiers, package in
            if package.installFormat == .musicAppsArchive {
                guard musicAppsInstalledIDs.contains(package.id) else { return }
                identifiers.insert(package.id)
                return
            }

            let receiptIsInstalled = package.pkgIdentifier.map { receiptIDs.contains($0) || stateReceipts.contains($0) } == true
            if let fileCheck = package.normalisedFileCheckPath {
                guard FileManager.default.fileExists(atPath: fileCheck) else { return }
            } else {
                guard stateIDs.contains(package.id) || receiptIsInstalled else { return }
            }
            if let receipt = package.pkgIdentifier,
               receiptIDs.contains(receipt),
               !ApplePackageVersion.installedVersion(receiptVersions[receipt], satisfiesCatalogueVersion: package.packageVersion) {
                return
            }
            identifiers.insert(package.pkgIdentifier ?? package.id)
        }.count
        let available = max(manifest.packages.count, installed)
        return "\(installed)/\(available) installed"
    }

    private static func windowCatalogueCacheURL(paths: LooperPaths) -> URL {
        guard let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return paths.applicationSupport.appendingPathComponent("catalogue-cache.json")
        }
        return supportRoot.appendingPathComponent("Looper", isDirectory: true).appendingPathComponent("catalogue-cache.json")
    }

    private static func runIsStale(_ run: InstallRunState) -> Bool {
        run.isStale
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension Notification.Name {
    static let looperProcessingStateDidChange = Notification.Name("LooperProcessingStateDidChange")
}

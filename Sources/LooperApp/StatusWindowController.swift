import AppKit
import Darwin
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Hosts the Looper control window.
///
/// The window is SwiftUI-backed because the app is now a dashboard rather than
/// a simple status popover. The core installer remains framework-style Swift so
/// the CLI, daemon, and UI all use the same behaviour.
final class StatusWindowController: NSWindowController {
    private let model: LooperWindowModel

    init() {
        let model = LooperWindowModel()
        self.model = model
        let rootView = LooperWindowView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1180, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        super.init(window: window)

        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLights()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusWindowController is built in code.")
    }

    func showLogging() {
        model.selectedSection = .output
        model.refreshProgress()
        show()
    }

    func refreshHelperProgress() { model.refreshProgress() }

    func runFromMenu() {
        model.runNow()
        show()
    }

    func show() {
        if window?.isVisible == false {
            window?.center()
        }
        positionTrafficLights()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionTrafficLights() {
        guard let closeButton = window?.standardWindowButton(.closeButton),
              let miniaturiseButton = window?.standardWindowButton(.miniaturizeButton),
              let zoomButton = window?.standardWindowButton(.zoomButton),
              let container = closeButton.superview else {
            return
        }

        let buttons = [closeButton, miniaturiseButton, zoomButton]
        let desiredLeftInset: CGFloat = 20
        let desiredTopInset: CGFloat = 16
        let deltaX = desiredLeftInset - closeButton.frame.minX
        let desiredY = max(0, container.bounds.height - desiredTopInset - closeButton.frame.height)
        let deltaY = desiredY - closeButton.frame.origin.y

        for button in buttons {
            button.setFrameOrigin(NSPoint(
                x: button.frame.origin.x + deltaX,
                y: button.frame.origin.y + deltaY
            ))
        }
    }

}

@MainActor
private final class LooperWindowModel: ObservableObject {
    enum Section: String, CaseIterable, Hashable, Identifiable {
        case library = "Library"
        case settings = "Settings"
        case output = "Logging"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .library: return "music.note.list"
            case .settings: return "slider.horizontal.3"
            case .output: return "terminal"
            }
        }
    }

    struct PackageRow: Identifiable, Hashable {
        var id: String
        var displayName: String
        var pkgIdentifier: String?
        var targetApps: [String]
        var isMusicAppsArchive: Bool
        var state: String
        var packageSet: String
        var essentialApps: [String]
        var downloadSize: Int64?
        var kind: String

        func matchesCatalogue(_ catalogue: String, app: String) -> Bool {
            if !app.isEmpty && !targetApps.contains(app) { return false }
            if catalogue == "Essential" {
                return app.isEmpty ? packageSet == "Essential" : essentialApps.contains(app)
            }
            return catalogue.isEmpty || catalogue == "All" || packageSet == catalogue
        }
        var source: String
        var url: URL?
    }

    struct ContentCacheStatus: Sendable {
        enum State: String, Sendable {
            case unknown = "Unknown"
            case checking = "Checking"
            case available = "Available"
            case unavailable = "Not detected"
            case warning = "Warning"
        }

        var state: State
        var summary: String
        var detail: String
        var checkedAt: Date?
        var rawOutput: String
        var servers: [ContentCacheServer] = []

        static var checking: ContentCacheStatus {
            ContentCacheStatus(
                state: .checking,
                summary: "Checking content cache discovery.",
                detail: "Looper is asking macOS which Apple Content Caching servers are available.",
                checkedAt: nil,
                rawOutput: ""
            )
        }

        static var unknown: ContentCacheStatus {
            ContentCacheStatus(
                state: .unknown,
                summary: "Content cache status has not been checked yet.",
                detail: "Open this pane or refresh to query macOS content-cache discovery.",
                checkedAt: nil,
                rawOutput: ""
            )
        }
    }

    @Published var selectedSection: Section = .library
    enum LibraryColumn: String {
        case package = "Package"
        case size = "Download size"
        case status = "Status"
    }

    @Published private(set) var libraryColumn: LibraryColumn = .package
    @Published private(set) var libraryAscending = true
    @Published var rows: [PackageRow] = []

    func sortLibrary(by column: LibraryColumn) {
        libraryAscending = column == libraryColumn ? !libraryAscending : true
        libraryColumn = column
        rows = sortedLibraryRows(rows)
    }

    private func sortedLibraryRows(_ input: [PackageRow]) -> [PackageRow] {
        let activeID = currentPackageID
        let phase = activityTitle
        func status(_ row: PackageRow) -> String {
            if let activeID, row.id == activeID || row.pkgIdentifier == activeID { return phase }
            return row.state
        }
        return input.sorted { lhs, rhs in
            let order: ComparisonResult
            switch libraryColumn {
            case .package:
                order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .status:
                order = status(lhs).localizedStandardCompare(status(rhs))
            case .size:
                let left = lhs.downloadSize ?? 0, right = rhs.downloadSize ?? 0
                if (left > 0) != (right > 0) { return left > 0 }
                order = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
            if order != .orderedSame { return order == (libraryAscending ? .orderedAscending : .orderedDescending) }
            let names = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return names == .orderedSame ? lhs.id < rhs.id : names == .orderedAscending
        }
    }
    var libraryApps: [String] { Set(rows.flatMap(\.targetApps)).sorted() }
    @Published var selectedPackageID: String?
    @Published var installState = InstallState()
    @Published var manifest: LoopManifest?
    @Published var isDiscoveredManifest = false
    @Published var catalogueSource = "Unknown"
    private var submittedRun: (id: String, at: Date)?
    @Published var pendingRunAt: Date?
    @Published var pendingDeleteIdentifiers: Set<String> = []
    @Published var helperResults: [HelperResult] = []
    private var latestSoundcheckDate = Date()
    @Published private(set) var soundcheckRunID: String?
    @Published var events: [LooperEvent] = [] {
        didSet {
            // Ignore historical runs on launch and repeated reads of the same event.
            if let finish = events.first(where: {
                $0.timestamp > latestSoundcheckDate && $0.category == "Run" &&
                $0.level == .success && $0.message == "Run completed."
            }) {
                latestSoundcheckDate = finish.timestamp
                soundcheckRunID = finish.requestID ?? finish.id
            }
        }
    }
    @Published var liveOutput = "No helper output has been read yet."
    @Published var receiptCount = 0
    @Published var statusMessage = "Ready."
    @Published var scheduleStatus = LaunchAgentScheduler().status()
    @Published var managedScheduleEnabled = false
    @Published var managedScheduleQuietHours: String?
    @Published var isRefreshing = false
    @Published private(set) var installationPulse = 0
    @Published var hasLoadedSnapshot = false
    @Published var helperLaunchFailure: String?
    @Published var helperStatusText = "Checking..."
    @Published var appPackageOverrides: [String: AppPackageOverrides] = [:]
    @Published var runScopeByApp: [String: String] = [
        "GarageBand": "All",
        "Logic Pro": "All",
    ]
    @Published var notificationStatusText = "Checking..."
    @Published var notifyNewLoopsAvailable = true
    @Published var notifyRelaunchPrompts = true
    @Published var notifyRunFailures = true
    @Published var notifyRunSummaries = false
    @Published var logRetentionDays = 30
    @Published var helperRunMode: LooperHelperRunMode = .sequential
    @Published var excludedPackageIDs: Set<String> = []
    @Published var packagePriorities: [String: Int] = [:]
    @Published var contentCacheStatus = ContentCacheStatus.unknown
    @Published var pendingStopAt: Date?
    @Published var settingsAreDirty = false
    @Published var managedSettingKeys: Set<String> = []

    private let paths = LooperPaths()
    private let scheduler = LaunchAgentScheduler()
    private let settingsStore: LooperSettingsStore
    private var pollTimer: Timer?
    @Published private var catalogueRefreshIsRunning = false
    private var lastNewLoopsNotificationDate: Date?
    private var lastRelaunchPromptedRunID: String?
    private var lastRunNotificationID: String?

    init() {
        self.settingsStore = LooperSettingsStore(url: Self.userSettingsURL())
        applyStoredSettings(settingsStore.load())
        refresh(mode: .localCache)
        refreshAppleCatalogue()
        refreshContentCacheStatus()
        refreshNotificationStatus()
    }

    var selectedPackage: PackageRow? {
        rows.first { $0.id == selectedPackageID }
    }

    var installedCount: Int {
        rows.filter { $0.state == "Installed" }.count
    }

    var availableCount: Int {
        let catalogueIdentifiers = cataloguePackageIdentifiers
        if !catalogueIdentifiers.isEmpty {
            return catalogueIdentifiers.count
        }
        return Set(rows.map(packageIdentity)).count
    }

    var downloadedCount: Int {
        installedCount
    }

    var installedDisplayCount: Int {
        let catalogueIdentifiers = cataloguePackageIdentifiers
        return rows.reduce(into: Set<String>()) { identifiers, row in
            guard row.state == "Installed" else { return }
            let identifier = packageIdentity(row)
            guard catalogueIdentifiers.isEmpty || catalogueIdentifiers.contains(identifier) else { return }
            identifiers.insert(identifier)
        }.count
    }

    var missingCount: Int {
        let catalogueIdentifiers = cataloguePackageIdentifiers
        return rows.filter { row in
            guard row.state == "Missing" || row.state == "Update Available" else { return false }
            return catalogueIdentifiers.isEmpty || catalogueIdentifiers.contains(packageIdentity(row))
        }.count
    }

    private var cataloguePackageIdentifiers: Set<String> {
        Set((manifest?.packages ?? []).map { $0.pkgIdentifier ?? $0.id })
    }

    private func packageIdentity(_ row: PackageRow) -> String {
        row.pkgIdentifier ?? row.id
    }

    var failedCount: Int {
        rows.filter { $0.state == "Failed" }.count
    }

    var queuedDeleteCount: Int {
        pendingDeleteIdentifiers.count
    }

    var currentRun: InstallRunState? {
        installState.currentRun
    }

    var hasStaleRun: Bool {
        guard let run = installState.currentRun, run.isRunning else { return false }
        return Self.runIsStale(run)
    }

    var isRunning: Bool {
        guard let run = installState.currentRun, run.isRunning else { return false }
        return !Self.runIsStale(run)
    }

    var isCheckingCatalogue: Bool {
        (catalogueRefreshIsRunning || (isRefreshing && !hasLoadedSnapshot))
            && !isRunning && pendingRunAt == nil && !helperActionIsRunning
    }

    var stopRequested: Bool {
        pendingStopAt != nil
    }

    var currentPackageID: String? {
        guard isRunning else { return nil }
        return currentRun?.currentPackageID
    }

    var currentPackage: PackageRow? {
        guard let currentPackageID else { return nil }
        return rows.first { $0.id == currentPackageID || $0.pkgIdentifier == currentPackageID }
    }

    var activityTitle: String {
        if stopRequested && isRunning {
            return "Stopping"
        }
        guard let run = currentRun, run.isRunning, !Self.runIsStale(run) else {
            if isCheckingCatalogue {
                return "Checking catalogue"
            }
            if pendingRunAt != nil {
                return helperLaunchFailure == nil ? "Queued" : "Helper unavailable"
            }
            if let result = activeHelperResult {
                return result.kind == .deletePackage ? "Deleting" : "Checking packages"
            }
            if actionableFailures.attentionDetail != nil { return "Needs attention" }
            return "Idle"
        }

        let message = run.message.lowercased()
        if message.contains("planning") || message.contains("preparing") { return "Planning" }
        if message.contains("download") { return "Downloading" }
        if message.contains("install") { return "Installing" }
        return "Running"
    }

    var activityNeedsAttention: Bool { ["Needs attention", "Helper unavailable"].contains(activityTitle) }

    var activityDetail: String {
        guard let run = currentRun, run.isRunning, !Self.runIsStale(run) else {
            if isCheckingCatalogue {
                return catalogueRefreshIsRunning ? "Looking for new Apple sound packages" : "Reading cached packages and receipts"
            }
            if pendingRunAt != nil {
                if let helperLaunchFailure { return helperLaunchFailure }
                if let queued = pendingRunAt, Date().timeIntervalSince(queued) > 30 {
                    return "Waiting for the device helper to process this run."
                }
                return "Waiting for the helper to start"
            }
            return activeHelperResult?.message ?? actionableFailures.attentionDetail ?? currentRun?.message ?? "No active run"
        }

        let progress = activityProgressText
        if activityTitle == "Planning" {
            return run.message.replacingOccurrences(of: "...", with: "")
        }
        if activityTitle == "Stopping" {
            return "Finishing the current package step"
        }
        if let name = run.currentPackageName, !name.isEmpty {
            if currentPackagePhase == "Downloading", let fraction = currentPackageByteProgress {
                return "\(name) · \(Int((fraction * 100).rounded()))%"
            }
            return name
        }
        return ringProgress == nil ? progress : ""
    }

    var activityProgress: Double {
        currentRun?.overallFraction ?? 0
    }

    var activityProgressText: String {
        guard let run = currentRun, run.totalPackages > 0, !Self.runIsStale(run) else {
            return isCheckingCatalogue ? "Checking catalogue" : (isRunning ? "Preparing" : "Ready")
        }
        let percent = run.overallPercent ?? 0
        return "\(percent)% • \(run.completedPackages)/\(run.totalPackages) loops"
    }

    var currentPackageByteProgress: Double? {
        guard let run = currentRun,
              isRunning,
              let received = run.receivedBytes,
              let expected = run.expectedBytes,
              expected > 0 else {
            return nil
        }
        return min(1, max(0, Double(received) / Double(expected)))
    }

    var currentPackageRowProgress: Double {
        currentPackageByteProgress ?? activityProgress
    }

    var activitySymbol: String {
        if isCheckingCatalogue {
            return "magnifyingglass"
        }
        if stopRequested && isRunning {
            return "stop.fill"
        }
        switch activityTitle {
        case "Planning": return "list.bullet.clipboard"
        case "Downloading": return "arrow.down.circle.fill"
        case "Installing": return "shippingbox.circle.fill"
        case "Queued": return "clock.fill"
        case "Checking packages": return "magnifyingglass"
        case "Deleting": return "trash"
        case "Needs attention", "Helper unavailable": return "exclamationmark.triangle.fill"
        default: return isRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
        }
    }

    var ringProgress: Double? {
        guard isRunning, let run = currentRun, run.totalPackages > 0 else { return nil }
        return activityProgress
    }

    var currentPackagePhase: String? {
        guard isRunning, let run = currentRun, run.currentPackageID != nil else { return nil }
        if run.message.hasPrefix("Downloading ") { return "Downloading" }
        if run.message.hasPrefix("Installing ") { return "Installing" }
        return nil
    }

    var runStatusMessage: String {
        guard let run = currentRun, run.isRunning, !Self.runIsStale(run) else {
            if isCheckingCatalogue {
                return "Checking Apple catalogue."
            }
            if hasStaleRun {
                return "Last helper run stopped before finishing."
            }
            if pendingRunAt != nil {
                return "Queued \(runScopeDescription)."
            }
            return statusMessage
        }
        return "\(activityTitle) \(activityProgressText.lowercased())"
    }

    var lastRunText: String {
        installState.lastCheck.map(Self.dateFormatter.string(from:)) ?? "Never"
    }

    var catalogueUpdatedText: String {
        manifest?.updated.map(Self.dateFormatter.string(from:)) ?? "Unknown"
    }

    var runTargetApps: [String] {
        runAppContentSets.keys.sorted()
    }

    var runPackageSets: [String] {
        []
    }

    var runAppContentSets: [String: [String]] {
        Self.contentSets(for: runScopeByApp)
    }

    private static func contentSets(for scopes: [String: String]) -> [String: [String]] {
        scopes.mapValues { scope in
            switch scope {
            case "None": return ["None"]
            case "Essential": return ["Essential"]
            default: return []
            }
        }
    }

    func pendingPackages(for scopes: [String: String]) -> [LoopPackage]? {
        guard let manifest, !isDiscoveredManifest, !manifest.packages.isEmpty else { return nil }
        let policy = LooperPolicy(appContentSets: Self.contentSets(for: scopes), excludedPackageIDs: excludedPackageIDs,
                                  appPackageOverrides: appPackageOverrides)
        let installed = Set(rows.lazy.filter { $0.state == "Installed" }.map(\.id))
        let updates = Set(rows.lazy.filter { $0.state == "Update Available" }.map(\.id))
        var seen = Set<String>()
        return manifest.packages.filter { package in
            policy.includes(package, needsUpdate: updates.contains(package.id) && installState.removedPackages[package.id] == nil) && !installed.contains(package.id) && seen.insert(package.pkgIdentifier ?? package.id).inserted
        }
    }

    var activePackagePreferenceCount: Int {
        excludedPackageIDs.count + packagePriorities.filter { $0.value != 0 }.count
            + appPackageOverrides.values.filter { !$0.skip.isEmpty || !$0.only.isEmpty }.count
    }

    var helperRequiresAttention: Bool {
        helperStatusText != "Enabled" && !LooperPaths.usesDeviceHelper
    }

    private var activeHelperResult: HelperResult? {
        helperResults.first { $0.status == .running && !Self.helperResultIsStale($0) }
    }

    var helperActionIsRunning: Bool {
        activeHelperResult != nil
    }

    private var showReadyAfterRefresh: Bool {
        statusMessage == "Ready." || statusMessage == "Reading receipts and Looper state..."
    }

    var statusLevel: StatusLevel {
        if isRunning || isCheckingCatalogue {
            return .running
        }
        let lowercased = statusMessage.lowercased()
        if lowercased.contains("could not") || lowercased.contains("error") {
            return .error
        }
        if lowercased.contains("failed") && !lowercased.contains("0 failed") {
            return .error
        }
        if pendingRunAt != nil || lowercased.contains("queued") || lowercased.contains("requires approval") || lowercased.contains("not updated") {
            return .warning
        }
        if hasStaleRun {
            return .warning
        }
        return .normal
    }

    enum StatusLevel {
        case running
        case normal
        case warning
        case error
    }

    enum SnapshotMode {
        case localCache
        case appleCatalogue
    }

    func refresh(showStatus: Bool = false, mode: SnapshotMode = .localCache) {
        isRefreshing = true
        if !hasLoadedSnapshot {
            statusMessage = "Loading cached catalogue..."
        }

        Task.detached(priority: .userInitiated) { [paths, scheduler] in
            let snapshot = Self.loadSnapshot(paths: paths, scheduler: scheduler, mode: mode)
            await MainActor.run {
                self.apply(snapshot)
            }
        }
    }

    func refreshAppleCatalogue() {
        guard !catalogueRefreshIsRunning else { return }
        catalogueRefreshIsRunning = true
        if hasLoadedSnapshot {
            statusMessage = "Checking Apple catalogue..."
        }
        startPolling()
        notifyProcessing(true)

        Task.detached(priority: .userInitiated) { [paths, scheduler] in
            let snapshot = Self.loadSnapshot(paths: paths, scheduler: scheduler, mode: .appleCatalogue)
            await MainActor.run {
                self.catalogueRefreshIsRunning = false
                self.apply(snapshot)
            }
        }
    }

    private var progressReadInFlight = false

    func refreshProgress() {
        guard !progressReadInFlight else { return }
        progressReadInFlight = true
        Task.detached(priority: .utility) { [paths, scheduler] in
            let snapshot = Self.loadProgressSnapshot(paths: paths, scheduler: scheduler)
            await MainActor.run {
                self.progressReadInFlight = false
                self.applyProgress(snapshot)
            }
        }
    }

    func runNow() { queueRun(package: nil) }

    func installPackage(_ package: PackageRow) { queueRun(package: package) }

    private func queueRun(package: PackageRow?) {
        do { try enqueueRun(package: package) }
        catch {
            statusMessage = "Could not queue run: \(error.localizedDescription)"
            notifyProcessing(false)
        }
    }

    var helperBusy: Bool { isRunning || pendingRunAt != nil || helperActionIsRunning }

    private func enqueueRun(package: PackageRow?) throws {
        guard !helperBusy else { throw LooperError.scheduleFailed("The helper already has work queued or in progress.") }
        if package == nil, settingsAreDirty {
            try settingsStore.save(currentSettings())
            settingsAreDirty = false
        }
        try requestHelperRun(packageID: package?.id)
        statusMessage = "Queued \(package?.displayName ?? runScopeDescription)."
        pendingRunAt = Date()
        startPolling()
        notifyProcessing(false)
        refreshProgress()
    }

    private func skipApps(for row: PackageRow) -> [String] {
        row.targetApps.isEmpty ? ["GarageBand", "Logic Pro"] : row.targetApps
    }

    func isSkipped(_ row: PackageRow) -> Bool {
        let aliases = Set([row.id, packagePreferenceKey(for: row)])
        return packageIsExcluded(row) || skipApps(for: row).allSatisfy { app in
            !(appPackageOverrides[app]?.skippedIDs ?? []).isDisjoint(with: aliases)
        }
    }

    func skipFailedPackage(_ row: PackageRow) {
        guard installState.failedPackages[row.id] != nil, !isSkipped(row),
              !settingIsManaged("AppPackageOverrides"), !settingIsManaged("RunAppContentSets") else { return }
        let key = packagePreferenceKey(for: row)
        func addingSkip(to overrides: [String: AppPackageOverrides]) -> [String: AppPackageOverrides] {
            var updated = overrides
            for app in skipApps(for: row) {
                var value = updated[app] ?? AppPackageOverrides()
                if value.skippedIDs.isDisjoint(with: [key, row.id]) {
                    value.skip = [value.skip, key].filter { !$0.isEmpty }.joined(separator: ", ")
                    updated[app] = value
                }
            }
            return updated
        }
        do {
            var saved = settingsStore.load()
            saved.appPackageOverrides = addingSkip(to: saved.appPackageOverrides ?? [:])
            try settingsStore.save(saved)
            appPackageOverrides = addingSkip(to: appPackageOverrides)
            statusMessage = "Skipped " + row.displayName + "."
            notifyProcessing(isRunning)
        } catch {
            statusMessage = "Could not save skip: " + error.localizedDescription
        }
    }

    var actionableFailures: InstallState {
        var state = installState
        guard !state.failedPackages.isEmpty else { return state }
        for row in rows where state.failedPackages[row.id] != nil && isSkipped(row) {
            state.failedPackages.removeValue(forKey: row.id)
        }
        return state
    }

    func retryFailedPackages() {
        guard !helperBusy else { return }
        let failedIDs = actionableFailures.failedPackages.keys.sorted()
        guard !failedIDs.isEmpty else { return }
        var queued = 0
        do {
            for id in failedIDs {
                try requestHelperRun(packageID: id)
                queued += 1
            }
            statusMessage = "Queued retries for \(queued) failed package\(queued == 1 ? "" : "s")."
        } catch {
            statusMessage = "Queued \(queued) of \(failedIDs.count) retries. \(error.localizedDescription)"
        }
        if queued > 0 {
            pendingRunAt = Date()
            startPolling()
            notifyProcessing(false)
            refreshProgress()
        }
    }

    func stopRun() {
        do {
            _ = try PendingRequestStore(url: paths.requestFile).requestStop()
            pendingStopAt = Date()
            statusMessage = "Stop requested; helper will finish the current package step."
            startPolling()
            refreshProgress()
        } catch {
            statusMessage = "Could not request stop: \(error)"
        }
    }

    func setRunScope(_ scope: String, for app: String) {
        guard !settingIsManaged("RunAppContentSets") else { return }
        runScopeByApp[app] = scope
        markSettingsDirty()
    }

    func setHelperRunMode(_ mode: LooperHelperRunMode) {
        guard !settingIsManaged("HelperRunMode") else {
            statusMessage = "Helper behaviour is managed by a configuration profile."
            return
        }
        helperRunMode = mode
        markSettingsDirty()
    }

    func setNotification(_ keyPath: ReferenceWritableKeyPath<LooperWindowModel, Bool>, enabled: Bool) {
        let key = notificationManagedKey(for: keyPath)
        guard !settingIsManaged(key) else {
            statusMessage = "This notification setting is managed by a configuration profile."
            return
        }
        self[keyPath: keyPath] = enabled
        markSettingsDirty()
    }

    func packagePreferenceKey(for package: PackageRow) -> String {
        package.pkgIdentifier ?? package.id
    }

    func packageIsExcluded(_ package: PackageRow) -> Bool {
        excludedPackageIDs.contains(package.id)
            || package.pkgIdentifier.map { excludedPackageIDs.contains($0) } == true
    }

    func packagePriority(_ package: PackageRow) -> Int {
        if let priority = packagePriorities[package.id] {
            return priority
        }
        if let identifier = package.pkgIdentifier,
           let priority = packagePriorities[identifier] {
            return priority
        }
        return 0
    }

    func setPackageExcluded(_ package: PackageRow, excluded: Bool) {
        guard !settingIsManaged("ExcludedPackageIDs") else {
            statusMessage = "Package exclusions are managed by a configuration profile."
            return
        }
        let key = packagePreferenceKey(for: package)
        if excluded {
            excludedPackageIDs.insert(key)
        } else {
            excludedPackageIDs.remove(key)
        }
        markSettingsDirty()
    }

    func setPackagePriority(_ package: PackageRow, priority: Int) {
        guard !settingIsManaged("PackagePriorities") else {
            statusMessage = "Package priorities are managed by a configuration profile."
            return
        }
        let key = packagePreferenceKey(for: package)
        let clampedPriority = min(10, max(-10, priority))
        if clampedPriority == 0 {
            packagePriorities.removeValue(forKey: key)
        } else {
            packagePriorities[key] = clampedPriority
        }
        markSettingsDirty()
    }

    func bumpPackagePriority(_ package: PackageRow, by delta: Int) {
        setPackagePriority(package, priority: packagePriority(package) + delta)
    }

    func setPackagePreferences(
        excludedPackageIDs: Set<String>,
        packagePriorities: [String: Int],
        appPackageOverrides: [String: AppPackageOverrides]
    ) {
        if !settingIsManaged("ExcludedPackageIDs") {
            self.excludedPackageIDs = excludedPackageIDs
        }
        if !settingIsManaged("PackagePriorities") {
            self.packagePriorities = packagePriorities.filter { $0.value != 0 }
        }
        if !settingIsManaged("AppPackageOverrides") && !settingIsManaged("RunAppContentSets") {
            self.appPackageOverrides = appPackageOverrides
        }
        markSettingsDirty()
    }

    func refreshNotificationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                self.notificationStatusText = Self.notificationStatusText(settings.authorizationStatus)
            }
        }
    }

    func requestNotificationAuthorisation() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await MainActor.run {
                self.refreshNotificationStatus()
            }
        }
    }

    func sendTestNotification() {
        Task {
            let delivered = await UserPrompter().notifyTest()
            await MainActor.run {
                self.statusMessage = delivered
                    ? "Sent a test notification."
                    : "Could not send a test notification. Check notification permissions for Looper."
                self.refreshNotificationStatus()
            }
        }
    }

    func saveCatalogue() {
        guard let manifest else { return }

        Task.detached(priority: .userInitiated) { [paths] in
            let result: Result<Void, Error> = Result {
                try paths.prepare()
                try ManifestLoader.save(manifest, to: LooperPaths.defaultManifestURL)
            }
            await MainActor.run {
                switch result {
                case .success:
                    self.statusMessage = "Saved catalogue."
                    self.isDiscoveredManifest = false
                case let .failure(error):
                    self.statusMessage = "Could not save catalogue: \(error)"
                }
                self.refresh()
            }
        }
    }

    func deleteSelectedPackage() {
        guard let package = selectedPackage else {
            statusMessage = "Select a package with an Apple receipt identifier."
            return
        }
        deletePackage(package)
    }

    func deletePackage(_ package: PackageRow) {
        guard let identifier = package.pkgIdentifier else {
            statusMessage = "Select a package with an Apple receipt identifier."
            return
        }

        do {
            guard LooperPaths.usesDeviceHelper else {
                throw LooperError.scheduleFailed("Install Looper.pkg to enable device-wide package operations.")
            }

            let requestID = try PendingRequestStore(url: paths.requestFile).appendDelete(identifier: identifier)
            statusMessage = "Deleting \(package.displayName)..."
            pendingDeleteIdentifiers.insert(identifier)
            events.insert(LooperEvent(
                level: .info,
                category: "Delete",
                message: "Delete started.",
                detail: package.displayName,
                packageIdentifier: identifier,
                requestID: requestID
            ), at: 0)
            helperResults.insert(HelperResult(
                id: requestID,
                kind: .deletePackage,
                status: .running,
                message: "Deleting \(package.displayName).",
                identifier: identifier,
                displayName: package.displayName
            ), at: 0)
            startPolling()
            notifyProcessing(true)
            refresh()
        } catch {
            statusMessage = "Could not request deletion: \(error)"
            notifyProcessing(false)
        }
    }

    func revealSelectedPackageInFinder() {
        guard let package = selectedPackage else {
            statusMessage = "Select a package with an Apple receipt identifier."
            return
        }
        revealPackageInFinder(package)
    }

    func revealPackageInFinder(_ package: PackageRow) {
        guard let identifier = package.pkgIdentifier else {
            statusMessage = "Select a package with an Apple receipt identifier."
            return
        }

        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error> = Result {
                let payloadPaths = try PackageInstaller().existingPayloadPaths(identifier: identifier)
                guard let url = Self.preferredRevealURL(from: payloadPaths) else {
                    throw LooperError.deleteFailed(identifier: identifier, message: "No installed payload files were found for this receipt.")
                }
                return url
            }

            await MainActor.run {
                switch result {
                case let .success(url):
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.statusMessage = "Revealed \(package.displayName) in Finder."
                case let .failure(error):
                    self.statusMessage = "Could not reveal \(package.displayName): \(error)"
                }
            }
        }
    }

    nonisolated private static func preferredRevealURL(from urls: [URL]) -> URL? {
        let audioRoots = [
            "/Library/Audio/",
            "/Library/Application Support/GarageBand/",
            "/Library/Application Support/Logic/",
            "/Library/Apple Loops/",
        ]

        return urls
            .filter { url in
                let path = url.standardizedFileURL.path
                return audioRoots.contains { path.hasPrefix($0) }
            }
            .sorted { lhs, rhs in
                let lhsIsDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rhsIsDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if lhsIsDirectory != rhsIsDirectory {
                    return !lhsIsDirectory
                }
                return lhs.pathComponents.count > rhs.pathComponents.count
            }
            .first
    }

    func openLogInConsole() {
        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            statusMessage = "Could not open log in Console: Console.app was not found."
            return
        }

        let logURL = FileManager.default.fileExists(atPath: paths.eventLogFile.path)
            ? paths.eventLogFile
            : paths.legacyEventLogFile
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([logURL], withApplicationAt: consoleURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.statusMessage = "Could not open log in Console: \(error)"
            }
        }
    }

    func updateLogRetention(days: Int) {
        guard !settingIsManaged("LogRetentionDays") else {
            statusMessage = "Log retention is managed by a configuration profile."
            return
        }
        logRetentionDays = days
        markSettingsDirty()
    }

    func saveSettings() {
        do {
            try settingsStore.save(currentSettings())
            LooperEventStore(url: paths.eventLogFile).prune(olderThan: logRetentionDays)
            LooperEventStore(url: paths.legacyEventLogFile).prune(olderThan: logRetentionDays)
            Self.pruneSidecarLogs(in: paths.logDirectory, olderThan: logRetentionDays)
            settingsAreDirty = false
            statusMessage = "Saved settings."
            refresh()
        } catch {
            statusMessage = "Could not save settings: \(error)"
        }
    }

    func revertSettings() {
        applyStoredSettings(settingsStore.load(), force: true)
        settingsAreDirty = false
        statusMessage = "Reverted unsaved settings."
    }

    func installSchedule(interval: TimeInterval, quietHours: String? = nil, exclusionPreset: String? = nil) {
        guard !settingIsManaged("ScheduledInstallEnabled") else { return }
        let helper = helperExecutableURL()
        let appContentSets = runAppContentSets
        Task.detached(priority: .userInitiated) { [scheduler] in
            let result: Result<Void, Error> = Result {
                try scheduler.install(
                    executableURL: helper,
                    interval: interval,
                    appContentSets: appContentSets,
                    quietHours: quietHours,
                    exclusionPreset: exclusionPreset
                )
            }
            await MainActor.run {
                switch result {
                case .success:
                    self.statusMessage = "Scheduled Looper."
                case let .failure(error):
                    self.statusMessage = "Schedule failed: \(error)"
                }
                self.refresh(showStatus: true)
            }
        }
    }

    func applySetup(scopes: [String: String], schedule: String, interval: TimeInterval, runNow: Bool) async throws {
        if !settingIsManaged("RunAppContentSets") {
            for (app, scope) in scopes { setRunScope(scope, for: app) }
            try settingsStore.save(currentSettings())
            settingsAreDirty = false
        }
        let executable = helperExecutableURL()
        let sets = runAppContentSets
        let prior = scheduler.status()
        if !settingIsManaged("ScheduledInstallEnabled") {
            // A local schedule captures its scope in launchd arguments. Refresh it
            // when retaining a schedule so it follows the newly selected apps.
            let effectiveInterval = schedule == "Repeat" ? interval : prior.interval
            try await Task.detached(priority: .userInitiated) { [scheduler] in
                if schedule == "Manual" {
                    if prior.isInstalled { try scheduler.uninstall() }
                } else if let effectiveInterval {
                    func argument(_ name: String) -> String? {
                        guard let index = prior.arguments.firstIndex(of: name),
                              index + 1 < prior.arguments.count else { return nil }
                        return prior.arguments[index + 1]
                    }
                    try scheduler.install(executableURL: executable, interval: effectiveInterval,
                                          appContentSets: sets, quietHours: argument("--quiet-hours"),
                                          exclusionPreset: argument("--exclude"))
                }
            }.value
        }
        if runNow {
            do { try enqueueRun(package: nil) }
            catch {
                throw NSError(domain: "Looper.Setup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Setup was saved. Looper could not start the run. \(error.localizedDescription)"
                ])
            }
        } else {
            refresh(mode: .localCache)
        }
    }

    func removeSchedule() {
        Task.detached(priority: .userInitiated) { [scheduler] in
            let result: Result<Void, Error> = Result {
                try scheduler.uninstall()
            }
            await MainActor.run {
                switch result {
                case .success:
                    self.statusMessage = "Schedule removed."
                case let .failure(error):
                    self.statusMessage = "Could not remove schedule: \(error)"
                }
                self.refresh(showStatus: true)
            }
        }
    }

    func copyLoggingToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loggingExportText, forType: .string)
        statusMessage = "Copied logging output."
    }

    func focusActivityTarget() {
        if let package = currentPackage {
            selectedSection = .library
            selectedPackageID = package.id
            statusMessage = "Showing \(package.displayName)."
        } else {
            selectedSection = .output
            statusMessage = "Showing recent helper logging."
        }
    }

    func refreshContentCacheStatus() {
        contentCacheStatus = .checking
        Task.detached(priority: .utility) {
            let status = Self.loadContentCacheStatus()
            await MainActor.run {
                self.contentCacheStatus = status
            }
        }
    }

    private func requestHelperRun(packageID: String?) throws {
        guard LooperPaths.usesDeviceHelper else {
            throw LooperError.scheduleFailed("Install Looper.pkg to enable device-wide package operations.")
        }
        guard FileManager.default.fileExists(atPath: paths.requestDirectory.path) else {
            throw LooperError.scheduleFailed("Request folder is not ready yet. Reinstall Looper.pkg to create \(paths.requestDirectory.path).")
        }
        guard FileManager.default.isWritableFile(atPath: paths.requestDirectory.path) else {
            throw LooperError.scheduleFailed("Request folder is not writable by this user. The helper should set \(paths.requestDirectory.path) to a sticky writable drop point; reinstall Looper.pkg.")
        }
        let id = try PendingRequestStore(url: paths.requestFile).requestRun(
            requestedPackageID: packageID,
            targetApps: runTargetApps,
            packageSets: runPackageSets,
            appContentSets: runAppContentSets,
            appPackageOverrides: appPackageOverrides,
            excludedPackageIDs: Array(excludedPackageIDs).sorted(),
            packagePriorities: packagePriorities
        )
        submittedRun = (id, Date())
    }

    private func updatePendingRun(_ requests: PendingRequests, results: [HelperResult]) {
        pendingRunAt = requests.runRequestedAt
        guard let submittedRun else { return }
        if results.contains(where: { $0.id == submittedRun.id }) {
            self.submittedRun = nil
        } else if pendingRunAt == nil, !isRunning {
            // The helper consumes the request before publishing the run result.
            // An in-flight snapshot can also predate the click.
            if Date().timeIntervalSince(submittedRun.at) < 30 {
                pendingRunAt = submittedRun.at
            } else {
                self.submittedRun = nil
            }
        }
    }

    @discardableResult
    private func applyInstallState(_ next: InstallState) -> Set<String> {
        let completed = Set(next.installedPackages.keys.filter { id in
            guard hasLoadedSnapshot, let record = next.installedPackages[id] else { return false }
            return record.installedAt > (installState.installedPackages[id]?.installedAt ?? .distantPast)
        })
        installState = next
        if !completed.isEmpty { installationPulse += 1 }
        return completed
    }

    private func apply(_ snapshot: Snapshot) {
        manifest = snapshot.manifest
        isDiscoveredManifest = snapshot.isDiscoveredManifest
        catalogueSource = snapshot.catalogueSource
        applyInstallState(snapshot.installState)
        updatePendingRun(snapshot.pendingRequests, results: snapshot.helperResults)
        pendingStopAt = snapshot.pendingRequests.stopRequestedAt
        helperResults = snapshot.helperResults
        events = snapshot.events
        liveOutput = snapshot.liveOutput
        pendingDeleteIdentifiers = Set(snapshot.pendingRequests.deletePackageIdentifiers).union(
            snapshot.helperResults
                .filter { $0.kind == .deletePackage && $0.status == .running && !Self.helperResultIsStale($0) }
                .compactMap(\.identifier)
        )
        rows = sortedLibraryRows(snapshot.rows)
        receiptCount = snapshot.receiptCount
        scheduleStatus = snapshot.scheduleStatus
        applyStoredSettings(snapshot.settings)
        isRefreshing = false
        hasLoadedSnapshot = true
        refreshHelperStatus()
        handleNotificationTriggers(snapshot: snapshot)

        if selectedPackageID == nil {
            selectedPackageID = rows.first?.id
        } else if selectedPackage == nil {
            selectedPackageID = rows.first?.id
        }

        if !snapshot.detail.isEmpty {
            statusMessage = snapshot.detail
        } else if showReadyAfterRefresh {
            statusMessage = "Ready."
        }
        let helperActionIsRunning = snapshot.helperResults.contains { $0.status == .running && !Self.helperResultIsStale($0) }
        if isRunning || isCheckingCatalogue || helperActionIsRunning || (pendingRunAt != nil) {
            startPolling()
            notifyProcessing(isRunning || isCheckingCatalogue || helperActionIsRunning)
        } else {
            stopPolling()
            notifyProcessing(false)
        }
    }

    private func applyProgress(_ snapshot: ProgressSnapshot) {
        let previousActiveID = currentPackageID
        let previousPhase = activityTitle
        helperLaunchFailure = snapshot.helperLaunchFailure
        let completed = applyInstallState(snapshot.installState)
        updatePendingRun(snapshot.pendingRequests, results: snapshot.helperResults)
        pendingStopAt = snapshot.pendingRequests.stopRequestedAt
        helperResults = snapshot.helperResults
        events = snapshot.events
        liveOutput = snapshot.liveOutput
        let updatedRows = Self.rowsByApplyingProgressState(rows, installState: snapshot.installState, completed: completed)
        if rows != updatedRows || (libraryColumn == .status && (previousActiveID != currentPackageID || previousPhase != activityTitle)) {
            rows = sortedLibraryRows(updatedRows)
        }
        scheduleStatus = snapshot.scheduleStatus
        applyStoredSettings(snapshot.settings)
        refreshHelperStatus()

        let helperActionIsRunning = snapshot.helperResults.contains { $0.status == .running && !Self.helperResultIsStale($0) }
        if isRunning || isCheckingCatalogue || helperActionIsRunning || (pendingRunAt != nil) {
            startPolling()
            notifyProcessing(isRunning || isCheckingCatalogue || helperActionIsRunning)
        } else {
            stopPolling()
            notifyProcessing(false)
            refresh(mode: .localCache)
        }
    }

    private func startPolling() {
        if pollTimer != nil { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshProgress()
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshHelperStatus() {
        helperStatusText = LooperPaths.usesDeviceHelper ? "Package-managed" : "Install Looper.pkg"
    }

    private func notifyProcessing(_ isProcessing: Bool) {
        var info: [String: Any] = ["isProcessing": isProcessing, "activityTitle": activityTitle,
                                   "detail": activityDetail, "queued": pendingRunAt != nil]
        info["failureDetail"] = activityTitle == "Helper unavailable" ? activityDetail : actionableFailures.attentionDetail
        info["overallPercent"] = currentRun?.overallPercent
        NotificationCenter.default.post(name: .looperProcessingStateDidChange, object: self, userInfo: info)
    }

    var savedDeploymentSettings: LooperSettings { settingsStore.load() }

    private func currentSettings() -> LooperSettings {
        LooperSettings(
            logRetentionDays: logRetentionDays,
            helperRunMode: helperRunMode,
            runAppContentSets: runAppContentSets,
            appPackageOverrides: appPackageOverrides,
            excludedPackageIDs: Array(excludedPackageIDs).sorted(),
            packagePriorities: packagePriorities,
            notifyNewLoopsAvailable: notifyNewLoopsAvailable,
            notifyRelaunchPrompts: notifyRelaunchPrompts,
            notifyRunFailures: notifyRunFailures,
            notifyRunSummaries: notifyRunSummaries
        )
    }

    private func markSettingsDirty() {
        settingsAreDirty = true
        statusMessage = "Settings have unsaved changes."
    }

    func settingIsManaged(_ key: String) -> Bool {
        managedSettingKeys.contains(key)
    }

    private func notificationManagedKey(for keyPath: ReferenceWritableKeyPath<LooperWindowModel, Bool>) -> String {
        switch keyPath {
        case \.notifyNewLoopsAvailable: return "NotifyNewLoopsAvailable"
        case \.notifyRelaunchPrompts: return "NotifyRelaunchPrompts"
        case \.notifyRunFailures: return "NotifyRunFailures"
        case \.notifyRunSummaries: return "NotifyRunSummaries"
        default: return ""
        }
    }

    private func applyStoredSettings(_ settings: LooperSettings, force: Bool = false) {
        managedSettingKeys = LooperSettingsStore.managedKeys()
        managedScheduleEnabled = settings.scheduledInstallEnabled == true
        managedScheduleQuietHours = settings.scheduleQuietHours
        guard force || !settingsAreDirty else { return }

        logRetentionDays = settings.logRetentionDays
        helperRunMode = settings.helperRunMode
        excludedPackageIDs = Set(settings.excludedPackageIDs)
        packagePriorities = settings.packagePriorities.filter { $0.value != 0 }
        notifyNewLoopsAvailable = settings.notifyNewLoopsAvailable
        notifyRelaunchPrompts = settings.notifyRelaunchPrompts
        notifyRunFailures = settings.notifyRunFailures
        notifyRunSummaries = settings.notifyRunSummaries

        appPackageOverrides = settings.appPackageOverrides ?? [:]
        var scopes = ["GarageBand": "None", "Logic Pro": "None"]
        for (app, sets) in settings.runAppContentSets {
            let normalizedSets = sets.map { $0.lowercased() }
            if normalizedSets.contains("none") {
                scopes[app] = "None"
            } else {
                scopes[app] = normalizedSets.contains("essential") ? "Essential" : "All"
            }
        }
        runScopeByApp = scopes
    }

    private func helperExecutableURL() -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/looper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/local/bin/looper")
    }

    private func handleNotificationTriggers(snapshot: Snapshot) {
        let missing = snapshot.rows.filter { $0.state == "Missing" || $0.state == "Update Available" }.count
        if notifyNewLoopsAvailable,
           missing > 0,
           !isRunning,
           !isCheckingCatalogue,
           snapshot.pendingRequests.runRequestedAt == nil,
           shouldSendNewLoopsNotification(now: Date()) {
            lastNewLoopsNotificationDate = Date()
            Task {
                await UserPrompter().notifyNewLoopsAvailable(count: missing)
            }
        }

        if let latestRun = snapshot.helperResults.first(where: { $0.kind == .installRun && $0.status != .running }),
           latestRun.id != lastRunNotificationID {
            if latestRun.status == .failed,
               notifyRunFailures,
               latestRun.message.localizedCaseInsensitiveContains("storage") {
                lastRunNotificationID = latestRun.id
                Task {
                    await UserPrompter().notifyStorageWarning(message: latestRun.message)
                }
            } else if latestRun.status == .failed && notifyRunFailures {
                lastRunNotificationID = latestRun.id
                Task {
                    await UserPrompter().notifyRunFailed(message: latestRun.message)
                }
            } else if latestRun.status == .succeeded && notifyRunSummaries {
                lastRunNotificationID = latestRun.id
                Task {
                    await UserPrompter().notifyRunSummary(message: latestRun.message)
                }
            }
        }

        guard notifyRelaunchPrompts,
              let latestInstall = snapshot.helperResults.first(where: { $0.kind == .installRun && $0.status == .succeeded }),
              latestInstall.id != lastRelaunchPromptedRunID,
              !latestInstall.message.lowercased().hasPrefix("0 installed") else {
            return
        }

        let runningApps = Self.runningSupportedAudioApps()
        guard !runningApps.isEmpty else { return }

        lastRelaunchPromptedRunID = latestInstall.id
        Task {
            await UserPrompter().notifyRelaunchRecommended(appNames: runningApps)
        }
    }

    private func shouldSendNewLoopsNotification(now: Date) -> Bool {
        guard let lastNewLoopsNotificationDate else { return true }
        return now.timeIntervalSince(lastNewLoopsNotificationDate) > 21_600
    }

    private var runScopeDescription: String {
        runAppContentSets
            .keys
            .sorted()
            .map { app in
                let scope = runScopeByApp[app] ?? "All"
                return "\(app): \(scope.lowercased())"
            }
            .joined(separator: "; ")
    }

    private static func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .provisional: return "Provisionally allowed"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
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

    private var loggingExportText: String {
        var sections: [String] = []
        if !events.isEmpty {
            let eventText = events.map { event in
                let detail = event.detail.map { " - \($0)" } ?? ""
                let identifier = event.packageIdentifier.map { " [\($0)]" } ?? ""
                return "[\(Self.formattedDate(event.timestamp))] \(event.level.rawValue.uppercased()) \(event.category): \(event.message)\(detail)\(identifier)"
            }
            sections.append(eventText.joined(separator: "\n"))
        }
        if !liveOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(liveOutput)
        }
        return sections.isEmpty ? "No Looper logging output is available." : sections.joined(separator: "\n\n")
    }

    nonisolated private static func queuedHelperFailure() -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        let label = LooperPaths.usesDeviceHelper ? LooperPaths.deviceHelperLabel : "com.maxhewett.Looper.helper"
        task.arguments = ["print", "system/\(label)"]
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        if task.terminationStatus != 0 { return "The system helper is unavailable." }
        if output.contains("state = running") { return nil }
        if output.contains("last exit reason = OS_REASON_CODESIGNING") {
            return "macOS rejected the helper’s code signature."
        }
        if output.contains("job state = spawn failed") || output.contains("78: EX_CONFIG") {
            return "macOS could not launch the registered helper."
        }
        return nil
    }

    nonisolated private static func loadProgressSnapshot(paths: LooperPaths, scheduler: LaunchAgentScheduler) -> ProgressSnapshot {
        let state = (try? StateStore(url: paths.stateFile).load()) ?? InstallState()
        let settings = LooperSettingsStore(url: userSettingsURL()).load()
        var pendingRequests = PendingRequestStore.loadAll(in: paths.requestDirectory)
        pendingRequests.merge(PendingRequestStore(url: paths.legacyRequestFile).load())
        let helperResults = HelperResultStore(directory: paths.resultDirectory).loadAll()
        let events = mergedEvents(
            LooperEventStore(url: paths.eventLogFile).loadRecent(limit: 500, retentionDays: settings.logRetentionDays),
            LooperEventStore(url: paths.legacyEventLogFile).loadRecent(limit: 500, retentionDays: settings.logRetentionDays)
        )
        let liveOutput = loadLiveOutput(
            paths: paths,
            state: state,
            pendingRequests: pendingRequests,
            helperResults: helperResults,
            events: events
        )

        return ProgressSnapshot(
            helperLaunchFailure: pendingRequests.runRequestedAt == nil ? nil : queuedHelperFailure(),
            installState: state,
            pendingRequests: pendingRequests,
            helperResults: helperResults,
            events: events,
            liveOutput: liveOutput,
            scheduleStatus: scheduler.status(),
            settings: settings
        )
    }

    nonisolated private static func loadSnapshot(paths: LooperPaths, scheduler: LaunchAgentScheduler, mode: SnapshotMode) -> Snapshot {
        let state: InstallState
        let stateDetail: String

        do {
            state = try StateStore(url: paths.stateFile).load()
            stateDetail = ""
        } catch {
            state = InstallState()
            stateDetail = "State could not be read: \(error)"
        }

        let receipts = PackageInstaller().installedAppleAudioContent()
        let settings = LooperSettingsStore(url: userSettingsURL()).load()
        var pendingRequests = PendingRequestStore.loadAll(in: paths.requestDirectory)
        pendingRequests.merge(PendingRequestStore(url: paths.legacyRequestFile).load())
        let helperResults = HelperResultStore(directory: paths.resultDirectory).loadAll()
        LooperEventStore(url: paths.eventLogFile).prune(olderThan: settings.logRetentionDays)
        LooperEventStore(url: paths.legacyEventLogFile).prune(olderThan: settings.logRetentionDays)
        pruneSidecarLogs(in: paths.logDirectory, olderThan: settings.logRetentionDays)
        let events = mergedEvents(
            LooperEventStore(url: paths.eventLogFile).loadRecent(limit: 500, retentionDays: settings.logRetentionDays),
            LooperEventStore(url: paths.legacyEventLogFile).loadRecent(limit: 500, retentionDays: settings.logRetentionDays)
        )
        let catalogue = loadCatalogue(paths: paths, receipts: receipts, mode: mode)
        let manifest = catalogue.manifest
        let catalogueSource = catalogue.source
        let isDiscoveredManifest = catalogueSource == "Apple receipts"
        let musicAppsInstalledIDs = MusicAppsContentStore().installedPackageIDs()
        let rows = makeRows(
            manifest: manifest,
            receipts: receipts,
            installState: state,
            pendingRequests: pendingRequests,
            helperResults: helperResults,
            isDiscoveredManifest: isDiscoveredManifest,
            musicAppsInstalledIDs: musicAppsInstalledIDs,
            logicUpdateIDs: MusicAppsContentStore().sharedUpdateCandidates()
        )
        let manifestDetail = catalogueSource == "Apple receipts" ? "Catalogue is inferred from Apple receipts." : ""
        let helperDetail = helperResults.first.map { latestResultMessage($0) } ?? ""
        let liveOutput = loadLiveOutput(
            paths: paths,
            state: state,
            pendingRequests: pendingRequests,
            helperResults: helperResults,
            events: events
        )
        let detail = [stateDetail, helperDetail, manifestDetail].filter { !$0.isEmpty }.joined(separator: " ")

        return Snapshot(
            manifest: manifest,
            isDiscoveredManifest: isDiscoveredManifest,
            catalogueSource: catalogueSource,
            installState: state,
            pendingRequests: pendingRequests,
            helperResults: helperResults,
            events: events,
            liveOutput: liveOutput,
            scheduleStatus: scheduler.status(),
            settings: settings,
            rows: rows,
            receiptCount: receipts.count,
            detail: detail
        )
    }

    nonisolated private static func loadContentCacheStatus() -> ContentCacheStatus {
        let discovery = ContentCacheDiscovery.lookup()
        guard let servers = discovery.servers else {
            return ContentCacheStatus(state: .warning, summary: "Cache lookup could not be completed.",
                                      detail: "See diagnostics for the locator response.", checkedAt: Date(), rawOutput: discovery.diagnostic)
        }
        return ContentCacheStatus(state: servers.isEmpty ? .unavailable : .available,
                                  summary: servers.isEmpty ? "No shared content cache detected." : "\(servers.count) shared content cache\(servers.count == 1 ? "" : "s")",
                                  detail: "", checkedAt: Date(), rawOutput: discovery.diagnostic, servers: servers)
    }

    nonisolated private static func loadCatalogue(
        paths: LooperPaths,
        receipts: [InstalledAppleContentReceipt],
        mode: SnapshotMode
    ) -> (manifest: LoopManifest, source: String) {
        if mode == .appleCatalogue,
           let appleManifest = try? AppleContentDiscovery.appleCatalogueManifest() {
            saveWindowCatalogueCache(appleManifest, paths: paths)
            return (appleManifest, "Apple catalogue")
        }

        if var cachedManifest = try? ManifestLoader.load(from: windowCatalogueCacheURL(paths: paths)) {
            if let modern = try? MusicAppsContentStore().catalogueManifest() {
                // Use the latest locally cached pack metadata even when opening
                // the window offline after a helper run or a Logic upgrade.
                cachedManifest.packages.removeAll { $0.installFormat == .musicAppsArchive }
                cachedManifest.packages.append(contentsOf: modern.packages)
            }
            return (cachedManifest, "Cached Apple catalogue")
        }

        if let managedManifest = try? ManifestLoader.load(from: LooperPaths.defaultManifestURL) {
            return (managedManifest, "Saved Looper catalogue")
        }

        return (AppleContentDiscovery.discoveredReceiptManifest(receipts: receipts), "Apple receipts")
    }

    nonisolated private static func saveWindowCatalogueCache(_ manifest: LoopManifest, paths: LooperPaths) {
        let url = windowCatalogueCacheURL(paths: paths)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ManifestLoader.save(manifest, to: url)
        } catch {
            // The cache only speeds up first paint. Failure here should not
            // stop the helper-owned catalogue/state from being shown.
        }
    }

    nonisolated private static func windowCatalogueCacheURL(paths: LooperPaths) -> URL {
        guard let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return paths.applicationSupport.appendingPathComponent("window-cache.json")
        }
        return supportRoot.appendingPathComponent("Looper", isDirectory: true).appendingPathComponent("catalogue-cache.json")
    }

    nonisolated private static func userSettingsURL() -> URL {
        guard let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return LooperPaths().settingsFile
        }
        return supportRoot.appendingPathComponent("Looper", isDirectory: true).appendingPathComponent("settings.json")
    }

    nonisolated private static func mergedEvents(_ primary: [LooperEvent], _ legacy: [LooperEvent]) -> [LooperEvent] {
        var eventsByID: [String: LooperEvent] = [:]
        for event in primary + legacy {
            eventsByID[event.id] = event
        }
        return eventsByID.values.sorted { $0.timestamp > $1.timestamp }
    }

    nonisolated private static func pruneSidecarLogs(in directory: URL, olderThan days: Int) {
        guard days > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for file in files where ["log", "txt"].contains(file.pathExtension) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    nonisolated private static func makeRows(
        manifest: LoopManifest?,
        receipts: [InstalledAppleContentReceipt],
        installState: InstallState,
        pendingRequests: PendingRequests,
        helperResults: [HelperResult],
        isDiscoveredManifest: Bool,
        musicAppsInstalledIDs: Set<String>,
        logicUpdateIDs: Set<String>
    ) -> [PackageRow] {
        let pendingDeletes = Set(pendingRequests.deletePackageIdentifiers)
        let latestDeleteResults = Dictionary(
            helperResults
                .filter { $0.kind == .deletePackage }
                .compactMap { result -> (String, HelperResult)? in
                    guard let identifier = result.identifier else { return nil }
                    return (identifier, result)
                },
            uniquingKeysWith: { first, _ in first }
        )
        let packageInstaller = PackageInstaller()
        var installedIdentifiers = Set(receipts.map(\.identifier))
        let receiptVersions = Dictionary(uniqueKeysWithValues: receipts.compactMap { receipt -> (String, String)? in
            guard let version = receipt.packageVersion else { return nil }
            return (receipt.identifier, version)
        })
        let latestInstalledByReceipt = latestInstalledPackagesByReceipt(in: installState)
        for identifier in latestDeleteResults.keys where !packageInstaller.packageHasInstalledPayload(identifier: identifier) {
            installedIdentifiers.remove(identifier)
        }
        for (identifier, result) in latestDeleteResults
            where deleteResultIsCurrent(result, installedPackage: latestInstalledByReceipt[identifier]) {
            installedIdentifiers.remove(identifier)
        }
        for removal in installState.removedPackages.values {
            if let receipt = removal.pkgIdentifier {
                installedIdentifiers.remove(receipt)
            }
        }
        let packages = AppleContentDiscovery.uniquePackages(manifest?.packages ?? [])
        let installedPackageIDs = Set(packages.compactMap { package -> String? in
            packageHasInstalledEvidence(
                package,
                installedIdentifiers: installedIdentifiers,
                receiptVersions: receiptVersions,
                installState: installState,
                musicAppsInstalledIDs: musicAppsInstalledIDs
            )
                ? package.id
                : nil
        })
        var rowsByID: [String: PackageRow] = [:]

        let browseCategories = packages.contains { $0.installFormat == .musicAppsArchive } ? MusicAppsContentStore.browseCategories() : [:]
        for package in packages {
            let packageIsInstalled = installedPackageIDs.contains(package.id)
            let packageHasPresence = packageHasInstalledPresence(
                package,
                installedIdentifiers: installedIdentifiers,
                installState: installState,
                musicAppsInstalledIDs: musicAppsInstalledIDs
            )
            let state: String
            if let receipt = package.pkgIdentifier, pendingDeletes.contains(receipt) {
                state = "Deleting"
            } else if let receipt = package.pkgIdentifier,
                      latestDeleteResults[receipt]?.status == .running,
                      !helperResultIsStale(latestDeleteResults[receipt]!) {
                state = "Deleting"
            } else if let receipt = package.pkgIdentifier,
                      latestDeleteResults[receipt]?.status == .running {
                state = "Helper Stalled"
            } else if let receipt = package.pkgIdentifier, latestDeleteResults[receipt]?.status == .failed {
                state = packageIsInstalled ? "Delete Failed" : "Missing"
            } else if packageIsInstalled {
                state = "Installed"
            } else if packageHasPresence || (package.installFormat == .musicAppsArchive && logicUpdateIDs.contains(package.id)) {
                state = "Update Available"
            } else {
                state = "Missing"
            }

            rowsByID[package.id] = PackageRow(
                id: package.id,
                displayName: package.displayName,
                pkgIdentifier: package.pkgIdentifier,
                targetApps: package.targetApps,
                isMusicAppsArchive: package.installFormat == .musicAppsArchive,
                state: state,
                packageSet: inferredPackageSet(for: package),
                essentialApps: package.packageSet == nil && inferredPackageSet(for: package) == "Essential" ? package.targetApps : package.resolvedEssentialApps,
                downloadSize: package.downloadSize,
                kind: package.installFormat == .musicAppsArchive ? (browseCategories[package.id] ?? "Modern Sound Packs") : libraryKind(groups: package.contentGroups ?? []),
                source: isDiscoveredManifest ? "Apple receipt" : "Catalogue",
                url: package.url
            )
        }

        let rowIDsByReceipt = Dictionary(uniqueKeysWithValues: packages.compactMap { package in
            package.pkgIdentifier.map { ($0, package.id) }
        })
        for receipt in receipts {
            if let id = rowIDsByReceipt[receipt.identifier], var row = rowsByID[id] {
                let receiptState = rowStateForReceipt(
                    receipt.identifier,
                    pendingDeletes: pendingDeletes,
                    latestDeleteResults: latestDeleteResults,
                    installedPackage: latestInstalledByReceipt[receipt.identifier],
                    isInstalled: installedIdentifiers.contains(receipt.identifier)
                )
                if receiptState != "Installed" { row.state = receiptState }
                row.source = "Catalogue + receipt"
                rowsByID[id] = row
                continue
            }

            rowsByID[receipt.identifier] = PackageRow(
                id: receipt.identifier,
                displayName: receipt.displayName,
                pkgIdentifier: receipt.identifier,
                targetApps: receipt.targetApps,
                isMusicAppsArchive: false,
                state: rowStateForReceipt(
                    receipt.identifier,
                    pendingDeletes: pendingDeletes,
                    latestDeleteResults: latestDeleteResults,
                    installedPackage: latestInstalledByReceipt[receipt.identifier],
                    isInstalled: installedIdentifiers.contains(receipt.identifier)
                ),
                packageSet: receipt.packageSet,
                essentialApps: receipt.packageSet == "Essential" ? receipt.targetApps : [],
                downloadSize: nil,
                kind: "Uncategorised",
                source: "Apple receipt",
                url: nil
            )
        }

        return rowsByApplyingProgressState(Array(rowsByID.values), installState: installState, completed: []).sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    nonisolated private static func packageHasInstalledEvidence(
        _ package: LoopPackage,
        installedIdentifiers: Set<String>,
        receiptVersions: [String: String],
        installState: InstallState,
        musicAppsInstalledIDs: Set<String>
    ) -> Bool {
        if package.installFormat == .musicAppsArchive {
            return musicAppsInstalledIDs.contains(package.id)
        }

        if let fileCheck = package.normalisedFileCheckPath {
            guard FileManager.default.fileExists(atPath: fileCheck) else {
                return false
            }
        }

        if let receipt = package.pkgIdentifier {
            guard installedIdentifiers.contains(receipt) else {
                return false
            }
            return ApplePackageVersion.installedVersion(
                receiptVersions[receipt],
                satisfiesCatalogueVersion: package.packageVersion
            )
        }

        return installState.installedPackages[package.id] != nil
    }

    nonisolated private static func packageHasInstalledPresence(
        _ package: LoopPackage,
        installedIdentifiers: Set<String>,
        installState: InstallState,
        musicAppsInstalledIDs: Set<String>
    ) -> Bool {
        if package.installFormat == .musicAppsArchive {
            return musicAppsInstalledIDs.contains(package.id)
        }

        if let fileCheck = package.normalisedFileCheckPath,
           FileManager.default.fileExists(atPath: fileCheck) {
            return true
        }

        if let receipt = package.pkgIdentifier {
            return installedIdentifiers.contains(receipt)
        }

        return installState.installedPackages[package.id] != nil
    }

    nonisolated private static func latestInstalledPackagesByReceipt(in state: InstallState) -> [String: InstalledPackage] {
        Dictionary(
            state.installedPackages.values.compactMap { installedPackage -> (String, InstalledPackage)? in
                guard let receipt = installedPackage.pkgIdentifier else { return nil }
                return (receipt, installedPackage)
            },
            uniquingKeysWith: { first, second in
                first.installedAt >= second.installedAt ? first : second
            }
        )
    }

    nonisolated private static func rowsByApplyingProgressState(_ rows: [PackageRow], installState: InstallState, completed: Set<String>) -> [PackageRow] {
        let completedReceipts = Set(completed.compactMap { installState.installedPackages[$0]?.pkgIdentifier })
        var unmatchedFailures = installState.failedPackages

        var result = rows.map { row in
            var updated = row
            if unmatchedFailures.removeValue(forKey: row.id) != nil {
                updated.state = "Failed"
            } else if completed.contains(row.id) || row.pkgIdentifier.map(completedReceipts.contains) == true {
                updated.state = "Installed"
            }
            return updated
        }
        for (id, failure) in unmatchedFailures {
            result.append(PackageRow(
                id: id, displayName: failure.displayName, pkgIdentifier: nil, targetApps: [],
                isMusicAppsArchive: false, state: "Failed", packageSet: "", essentialApps: [],
                downloadSize: nil, kind: "Uncategorised", source: "Install history", url: nil
            ))
        }
        return result
    }

    nonisolated private static func rowStateForReceipt(
        _ identifier: String,
        pendingDeletes: Set<String>,
        latestDeleteResults: [String: HelperResult],
        installedPackage: InstalledPackage?,
        isInstalled: Bool
    ) -> String {
        if pendingDeletes.contains(identifier) {
            return "Deleting"
        }
        if let result = latestDeleteResults[identifier], result.status == .running, helperResultIsStale(result) {
            return "Helper Stalled"
        }
        if latestDeleteResults[identifier]?.status == .running {
            return "Deleting"
        }
        if let result = latestDeleteResults[identifier],
           deleteResultIsCurrent(result, installedPackage: installedPackage) {
            return "Missing"
        }
        if latestDeleteResults[identifier]?.status == .failed && isInstalled {
            return "Delete Failed"
        }
        return isInstalled ? "Installed" : "Missing"
    }

    nonisolated private static func deleteResultIsCurrent(_ result: HelperResult, installedPackage: InstalledPackage?) -> Bool {
        guard result.status == .succeeded else {
            return false
        }
        guard let installedPackage else {
            return true
        }
        return installedPackage.installedAt <= result.updatedAt
    }

    nonisolated private static func latestResultMessage(_ result: HelperResult) -> String {
        if result.status == .running && helperResultIsStale(result) {
            return "Helper has not updated this action since \(formattedDate(result.updatedAt)): \(result.message)"
        }

        switch result.status {
        case .running:
            return result.message
        case .succeeded:
            if result.kind == .installRun {
                return friendlyRunSummary(result.message)
            }
            return result.message
        case .failed:
            return result.message
        }
    }

    nonisolated private static func friendlyRunSummary(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.hasPrefix("0 installed") && lowercased.contains("0 failed") {
            return "Last run completed; no changes needed."
        }
        return "Last run: \(message)"
    }

    nonisolated private static func helperResultIsStale(_ result: HelperResult) -> Bool {
        result.status == .running && Date().timeIntervalSince(result.updatedAt) > 120
    }

    nonisolated private static func runIsStale(_ run: InstallRunState) -> Bool {
        run.isStale
    }

    nonisolated private static func loadLiveOutput(
        paths: LooperPaths,
        state: InstallState,
        pendingRequests: PendingRequests,
        helperResults: [HelperResult],
        events: [LooperEvent]
    ) -> String {
        var sections: [String] = []

        if !events.isEmpty {
            let renderedEvents = events.prefix(30).map { event in
                let detail = event.detail.map { " - \($0)" } ?? ""
                return "[\(formattedDate(event.timestamp))] \(event.level.rawValue.uppercased()) \(event.category): \(event.message)\(detail)"
            }.joined(separator: "\n")
            sections.append("Structured Events\n\(renderedEvents)")
        }

        if let run = state.currentRun {
            sections.append("""
            Current Run
            running: \(run.isRunning)
            message: \(run.message)
            package: \(run.currentPackageName ?? "None")
            progress: \(run.completedPackages)/\(run.totalPackages)
            """)
        }

        if pendingRequests.runRequestedAt != nil || !pendingRequests.deletePackageIdentifiers.isEmpty {
            sections.append("""
            Pending Requests
            run requested: \(pendingRequests.runRequestedAt.map(formattedDate) ?? "No")
            apps: \(pendingRequests.runTargetApps.isEmpty ? "All" : pendingRequests.runTargetApps.joined(separator: ", "))
            content: \(pendingRequests.runPackageSets.isEmpty ? "All" : pendingRequests.runPackageSets.joined(separator: ", "))
            deletes: \(pendingRequests.deletePackageIdentifiers.joined(separator: ", "))
            """)
        }

        if !helperResults.isEmpty {
            let renderedResults = helperResults.prefix(12).map { result in
                "[\(formattedDate(result.updatedAt))] \(result.status.rawValue): \(result.message)"
            }.joined(separator: "\n")
            sections.append("Helper Results\n\(renderedResults)")
        }

        let outLog = tailFile(paths.logDirectory.appendingPathComponent("looper.out.log"))
        if !outLog.isEmpty {
            sections.append("looper.out.log\n\(outLog)")
        }

        let errLog = tailFile(paths.logDirectory.appendingPathComponent("looper.err.log"))
        if !errLog.isEmpty {
            sections.append("looper.err.log\n\(errLog)")
        }

        return sections.isEmpty ? "No helper output is available yet." : sections.joined(separator: "\n\n")
    }

    nonisolated private static func tailFile(_ url: URL, maxCharacters: Int = 8_000) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ""
        }
        let suffix = data.count > maxCharacters ? data.suffix(maxCharacters) : data
        return String(decoding: suffix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    nonisolated private static func libraryKind(groups: [String]) -> String {
        let words = Set(groups.flatMap { $0.lowercased().split { !$0.isLetter }.map(String.init) })
        let kinds: [(String, Set<String>)] = [
            ("Drums & Percussion", ["drum", "drums", "drummer", "percussion"]),
            ("Synths", ["synth", "synths", "synthesizer", "synthesizers", "synthesisers"]),
            ("Guitars", ["guitar", "guitars"]), ("Bass", ["bass", "basses"]),
            ("Keys", ["piano", "pianos", "keyboards", "organ", "organs"]),
            ("Orchestral", ["orchestra", "orchestral", "strings", "woodwinds", "brass"]),
            ("Vocals", ["vocals", "choir", "voices"])
        ]
        let matches = kinds.filter { !$0.1.isDisjoint(with: words) }
        return matches.count > 1 ? "Mixed" : matches.first?.0 ?? "Uncategorised"
    }

    nonisolated private static func inferredPackageSet(for package: LoopPackage) -> String {
        if let packageSet = package.packageSet, !packageSet.isEmpty {
            return packageSet
        }
        let text = ([package.id, package.displayName, package.notes ?? ""]).joined(separator: " ").lowercased()
        if text.contains("essential") || text.contains("basic") {
            return "Essential"
        }
        return "All"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private struct Snapshot {
        var manifest: LoopManifest?
        var isDiscoveredManifest: Bool
        var catalogueSource: String
        var installState: InstallState
        var pendingRequests: PendingRequests
        var helperResults: [HelperResult]
        var events: [LooperEvent]
        var liveOutput: String
        var scheduleStatus: LaunchAgentStatus
        var settings: LooperSettings
        var rows: [PackageRow]
        var receiptCount: Int
        var detail: String
    }

    private struct ProgressSnapshot {
        var helperLaunchFailure: String?
        var installState: InstallState
        var pendingRequests: PendingRequests
        var helperResults: [HelperResult]
        var events: [LooperEvent]
        var liveOutput: String
        var scheduleStatus: LaunchAgentStatus
        var settings: LooperSettings
    }
}

private struct LooperWindowView: View {
    private struct LogDaySection: Identifiable {
        var id: Date { day }
        var day: Date
        var title: String
        var events: [LooperEvent]
    }

    private enum SettingsPane: String, CaseIterable, Identifiable {
        case scope = "Run Scope"
        case schedule = "Schedule"
        case logging = "Logging"
        case notifications = "Notifications"
        case caching = "Caching"
        case helper = "Helper"
        case behaviour = "Behaviour"
        case deployment = "Deployment"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .scope: return "scope"
            case .schedule: return "calendar.badge.clock"
            case .logging: return "doc.text.magnifyingglass"
            case .notifications: return "bell.badge"
            case .caching: return "externaldrive.badge.wifi"
            case .helper: return "lock.shield"
            case .behaviour: return "gearshape.2"
            case .deployment: return "square.and.arrow.up"
            case .about: return "info.circle"
            }
        }

        var summary: String {
            switch self {
            case .scope: return "Apps and content sets"
            case .schedule: return "Automatic runs"
            case .logging: return "Retention and Console"
            case .notifications: return "Availability and relaunch prompts"
            case .caching: return "Apple content cache"
            case .helper: return "Privileged service"
            case .behaviour: return "Helper run mode"
            case .deployment: return "Jamf and configuration profiles"
            case .about: return "Version and catalogue"
            }
        }
    }

    @ObservedObject var model: LooperWindowModel
    @AppStorage("SidebarCollapsed") private var sidebarCollapsed = false
    @State private var activityHovered = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var librarySearch = ""
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @AppStorage("LibraryGroupedByKind") private var groupByKind = false
    @State private var logLevelFilter = "All"
    @State private var logRangeFilter = "Last 7 Days"
    @State private var visibleLogDateTitle = ""
    @State private var isFollowingLogs = true
    @State private var frozenLogEntries: [LooperEvent]?
    @State private var livePulse = false
    @State private var logScrollRequest = 0
    @State private var filterApp = ""
    @State private var browseCategory = ""
    @State private var modernPacksOnly = false
    @State private var libraryScrolled = false
    @State private var filterCatalogue = ""
    @State private var filterStatus = ""
    @State private var showingLibraryFilters = false
    @State private var filterStatuses: [String] = []
    @State private var filterApps: [String] = []
    @State private var filterCatalogues: [String] = []
    @State private var libraryScrollTargetID: String?
    @State private var showLogLevelPopover = false
    @State private var showLogRangePopover = false
    @State private var showAdvancedScopeEditor = false
    @State private var showPackageIDLists = false
    @State private var advancedScopeSearch = ""
    @State private var advancedScopeAppFilter = "All Apps"
    @State private var advancedScopeSetFilter = "All Content"
    @State private var advancedScopeSort = "Priority"
    @State private var draftAppPackageOverrides: [String: AppPackageOverrides] = [:]
    @State private var draftExcludedPackageIDs: Set<String> = []
    @State private var draftPackagePriorities: [String: Int] = [:]
    @State private var infoPackageID: String?
    @State private var scheduleAmount = 6
    @State private var scheduleUnit = "Hours"
    @State private var quietHoursEnabled = false
    @State private var quietStartHour = 18
    @State private var quietEndHour = 7
    @State private var exclusionPeriodsEnabled = false
    @State private var exclusionPreset = "School Holidays"
    @State private var exportFormat: DeploymentExport = .profile
    @State private var exportSkipSetup = true
    @State private var exportPreload = true
    @State private var exportScheduled = false
    @State private var initializedExport = false
    @State private var exportMessage: String?
    @State private var selectedSettingsPane: SettingsPane = .scope
    @AppStorage("SetupAssistantCompleted") private var completedSetup = false
    @State private var showingSetup = false
    @State private var setupScheduleStep = false
    @State private var setupScopes: [String: String] = [:]
    @State private var setupSchedule = "Keep"
    @State private var submittingSetupRun = false
    @State private var setupRunAccepted = false
    @State private var setupRunNow = true
    @State private var setupInterval = 6
    @State private var setupError: String?
    @State private var savingSetup = false
    @State private var showStopConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                titlebarActionButton(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar", "sidebar.leading") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        activityHovered = false
                        sidebarCollapsed.toggle()
                    }
                }
                Spacer()
                titlebarActions
            }
            .padding(.leading, 90)
            .padding(.trailing, 16)
            .frame(height: 48)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarCollapsed ? 68 : 234)
                    .zIndex(1)

                ZStack {
                    detailContent
                        .id(model.selectedSection)
                        .transition(.opacity)
                }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.selectedSection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        LooperStyle.contentBackground.opacity(reduceTransparency ? 1 : 0.84)
                            .overlay(LooperStyle.waveformGradient.opacity(0.036))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(LooperStyle.separator)
                            .allowsHitTesting(false)
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1180, minHeight: 680)
        .tint(LooperStyle.accent)
        .accentColor(LooperStyle.accent)
        .background(LooperStyle.windowBackground.ignoresSafeArea())
        .onAppear {
            if !completedSetup && !LooperSettingsStore.skipSetupAssistant { openSetup() }
        }
        .sheet(isPresented: $showingSetup) { setupAssistant }
        .confirmationDialog(
            "Stop the current Looper run?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Run", role: .destructive) {
                model.stopRun()
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Looper will finish the current package step, then stop before starting the next package.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SidebarWaveform(runID: model.soundcheckRunID)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                if !sidebarCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looper").font(.headline)
                        Text(appVersionText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, sidebarCollapsed ? 5 : 9)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(LooperWindowModel.Section.allCases) { section in
                        sidebarNavigationRow(section)
                    }
                }
                .padding(.top, 8)
            }
            .scrollClipDisabled()

            Spacer(minLength: 0)

            sidebarActivityPanel
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var activityRing: some View {
        let progress = model.ringProgress
        let loading = model.isCheckingCatalogue || model.helperActionIsRunning || model.isRunning
        let stroke = StrokeStyle(lineWidth: 3, lineCap: .round)
        return ZStack {
            Circle().stroke(model.activityNeedsAttention ? Color.red.opacity(0.65) : LooperStyle.separator, lineWidth: stroke.lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(LooperStyle.waveformGradient, style: stroke)
                    .rotationEffect(.degrees(-90))
            } else if loading {
                activitySweep(width: 3, colour: LooperStyle.accent)
            }
            Image(systemName: model.activitySymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.activityNeedsAttention ? Color.red : (loading || model.pendingRunAt != nil ? LooperStyle.accent : .secondary))
        }
        .frame(width: 34, height: 34)
    }

    private func activitySweep(width: CGFloat, colour: Color) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            Circle().trim(from: 0, to: 0.32)
                .stroke(colour, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -90 : phase * 360 - 90))
        }
    }

    private var sidebarActivityPanel: some View {
        Button(action: focusActivityTarget) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    activityRing
                    if !sidebarCollapsed {
                        activityText
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(sidebarCollapsed ? 5 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if !sidebarCollapsed {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(LooperStyle.separator) }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { activityHovered = $0 }
        .overlay(alignment: .bottomLeading) {
            if sidebarCollapsed && activityHovered {
                activityText
                    .frame(width: 218, alignment: .leading)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(LooperStyle.separator) }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .fixedSize()
                    .offset(x: 54)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel([model.activityTitle, model.ringProgress == nil ? "" : model.activityProgressText, model.activityDetail].filter { !$0.isEmpty }.joined(separator: ". "))
        .help(model.isRunning ? "Show the active package" : (model.actionableFailures.failedPackages.isEmpty ? "Show helper logging" : "Show failed packages"))
    }

    private var activityText: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.ringProgress != nil {
                Text(model.activityProgressText).font(.headline).monospacedDigit()
            }
            Text(model.activityTitle).font(model.ringProgress == nil ? .headline : .subheadline.weight(.semibold))
            if !model.activityDetail.isEmpty {
                Text(model.activityDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
        }
    }

    private func sidebarNavigationRow(_ section: LooperWindowModel.Section) -> some View {
        let isSelected = model.selectedSection == section

        return Button {
            model.selectedSection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? LooperStyle.accent : .secondary)
                    .frame(width: 22)

                if !sidebarCollapsed {
                    Text(section.rawValue)
                        .font(.headline)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .leading)
            .padding(.horizontal, sidebarCollapsed ? 0 : 12)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LooperStyle.accent.opacity(isSelected ? 0.12 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(section.rawValue)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.selectedSection {
        case .library:
            libraryView
        case .settings:
            settingsView
        case .output:
            outputView
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider().opacity(0.35)
            HStack(spacing: 8) {
                sortHeading(.package)
                Spacer()
                sortHeading(.size).frame(width: 84, alignment: .trailing)
                sortHeading(.status).frame(width: 110, alignment: .trailing)
                Color.clear.frame(width: 116, height: 1).accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.vertical, 6)
            .background(LooperStyle.libraryHeaderBackground)
            packageBrowser
                .overlay(alignment: .top) {
                    if libraryScrolled {
                        VStack(spacing: 0) {
                            Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 1)
                            LinearGradient(colors: [.black.opacity(0.18), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 6)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
        }
    }

    private func sortHeading(_ column: LooperWindowModel.LibraryColumn) -> some View {
        let selected = model.libraryColumn == column
        return Button { model.sortLibrary(by: column) } label: {
            HStack(spacing: 3) {
                Text(column.rawValue)
                Image(systemName: selected ? (model.libraryAscending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(selected ? LooperStyle.accent : Color.secondary)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by " + column.rawValue)
        .accessibilityValue(selected ? (model.libraryAscending ? "Ascending" : "Descending") : "Unsorted")
    }

    private var titlebarActions: some View {
        let running = model.isRunning
        let disabled = running ? model.stopRequested : model.helperBusy
        let label = running ? (model.stopRequested ? "Stopping" : "Stop Run") : (disabled ? "Waiting for helper" : "Run Now")
        return HStack(spacing: 6) {
            titlebarActionButton("Refresh", "arrow.clockwise") {
                model.refreshAppleCatalogue()
            }
            titlebarActionButton(label, running ? "stop.fill" : "play.fill") {
                if model.isRunning {
                    showStopConfirmation = true
                } else {
                    model.runNow()
                }
            }
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
        }
    }

    private func titlebarActionButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
                .allowsHitTesting(false)
        }
        .accessibilityLabel(label)
        .help(label)
    }

    private func closeLibrarySearch() {
        librarySearch = ""
        searchFocused = false
        searchExpanded = false
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Library").font(.largeTitle.weight(.bold))
                Spacer()
                if searchExpanded {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(LooperStyle.accent)
                        TextField("Name or identifier", text: $librarySearch)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onAppear { searchFocused = true }
                            .onExitCommand { closeLibrarySearch() }
                        Button(action: closeLibrarySearch) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear and close search")
                    }
                    .padding(.horizontal, 10).frame(width: 245, height: 28)
                    .background(.thinMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(LooperStyle.separator).allowsHitTesting(false) }
                } else {
                    Button { searchExpanded = true } label: { libraryActionPill("Search", symbol: "magnifyingglass") }
                        .buttonStyle(.plain)
                        .keyboardShortcut("f", modifiers: .command)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: searchExpanded)
            HStack(spacing: 8) {
                compactMetric("Available", model.hasLoadedSnapshot ? "\(model.availableCount)" : "...", "shippingbox", LooperStyle.accent)
                compactMetric("Installed", model.hasLoadedSnapshot ? "\(model.installedDisplayCount)" : "...", "checkmark.circle.fill", .green, installationPulse: model.installationPulse)
                compactMetric("Missing", model.hasLoadedSnapshot ? "\(model.missingCount)" : "...", "arrow.down.circle.fill", .orange, animateChanges: false)
                Spacer()
                if !model.actionableFailures.failedPackages.isEmpty {
                    Button(action: model.retryFailedPackages) {
                        libraryActionPill("Retry Failed", symbol: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.helperBusy)
                    .help("Retry outstanding packages individually using the current managed policy")
                }
                Button {
                    selectedSettingsPane = .scope
                    model.selectedSection = .settings
                } label: {
                    libraryActionPill("Run Scope", symbol: "scope")
                }
                .buttonStyle(.plain)
                .help("Open Run Scope settings")
                Button {
                    filterStatuses = Set(model.rows.map(\.state)).union([filterStatus]).filter { !$0.isEmpty }.sorted()
                    filterApps = Set(model.libraryApps).union([filterApp]).filter { !$0.isEmpty }.sorted()
                    filterCatalogues = Set(model.rows.map(\.packageSet)).union(["All"]).union([filterCatalogue]).filter { !$0.isEmpty }.sorted()
                    showingLibraryFilters = true
                } label: {
                    libraryActionPill(filtersActive ? "Filtered" : "Filter", symbol: "line.3.horizontal.decrease.circle", selected: filtersActive)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingLibraryFilters) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 24) {
                            libraryFilterPicker("Status", $filterStatus, filterStatuses)
                            libraryFilterPicker("App", $filterApp, filterApps)
                            libraryFilterPicker("Catalogue", $filterCatalogue, filterCatalogues)
                        }
                        Toggle("Modern Sound Packs", isOn: $modernPacksOnly)
                        if modernPacksOnly {
                            Picker("Category", selection: $browseCategory) {
                                Text("Any").tag("")
                                ForEach(Set(model.rows.filter(\.isMusicAppsArchive).map(\.kind)).union([browseCategory]).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Toggle("Group by Kind", isOn: $groupByKind)
                        Divider()
                        HStack {
                            Button("Clear Filters", action: clearLibraryFilters).disabled(!filtersActive)
                            Spacer()
                            Button("Done") { showingLibraryFilters = false }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(16)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zIndex(2)
        .background {
            LooperStyle.libraryHeaderBackground
        }
    }

    private func libraryActionPill(_ title: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(LooperStyle.accent)
            Text(title).foregroundStyle(selected ? LooperStyle.accent : Color.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 27)
        .background(.thinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(selected ? LooperStyle.accent.opacity(0.55) : Color.white.opacity(0.08)) }
        .contentShape(Capsule())
    }

    private var runScopeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(["GarageBand", "Logic Pro"], id: \.self) { appName in
                runScopeAppPanel(appName)
                    .disabled(model.settingIsManaged("RunAppContentSets"))
            }

            HStack {
                Button {
                    openAdvancedScopeEditor()
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.below.rectangle")
                }
                .buttonStyle(LooperGlassButtonStyle(compact: true))
                .sheet(isPresented: $showAdvancedScopeEditor) {
                    advancedScopeEditor
                        .frame(minWidth: 980, idealWidth: 1040, minHeight: 620, idealHeight: 680)
                }

                Text(model.activePackagePreferenceCount == 0 ? "No package overrides" : "\(model.activePackagePreferenceCount) package overrides")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            ScopeStorageEstimate(packages: model.pendingPackages(for: model.runScopeByApp))
        }
        .frame(maxWidth: 620)
    }

    private func runScopeAppPanel(_ appName: String, draft: Binding<String>? = nil) -> some View {
        let scopeBinding = draft ?? Binding<String>(
            get: { model.runScopeByApp[appName] ?? "All" },
            set: { model.setRunScope($0, for: appName) }
        )

        let scope = scopeBinding.wrappedValue
        let isEnabled = scope != "None"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let icon = applicationIcon(for: appName) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "app.badge")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LooperStyle.accent)
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.headline.weight(.semibold))
                    Text(runScopeSummary(scope))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(scope)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isEnabled ? LooperStyle.accent : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(LooperStyle.settingsTint(0.09), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(isEnabled ? LooperStyle.accent.opacity(0.45) : LooperStyle.separator)
                            .allowsHitTesting(false)
                    }
            }

            LooperGlassSegmentedControl(selection: scopeBinding,
                                        options: [("All", "All"), ("Essential", "Essential"), ("None", "None")])
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(appName) sound catalogue")
        }
        .padding(14)
        .background(LooperStyle.settingsTint(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isEnabled ? LooperStyle.accent.opacity(0.18) : LooperStyle.separator)
                .allowsHitTesting(false)
        }
    }

    private var advancedScopeEditor: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Advanced Scope")
                        .font(.title.weight(.bold))
                    Text("Skip packages you do not want and raise priority for packages that should install earlier.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    showAdvancedScopeEditor = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(20)
            .background(LooperStyle.libraryHeaderBackground)

            Divider().opacity(0.32)

            HStack(spacing: 10) {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                TextField("Search packages", text: $advancedScopeSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                LooperGlassSegmentedControl(
                    selection: $advancedScopeAppFilter,
                    options: advancedScopeAppOptions.map { ($0, $0) }
                )
                .frame(maxWidth: 300)

                LooperGlassSegmentedControl(
                    selection: $advancedScopeSetFilter,
                    options: [
                        ("All", "All Content"),
                        ("Essential", "Essential"),
                    ]
                )
                .frame(maxWidth: 180)

                Menu {
                    ForEach(["Priority", "A-Z", "Z-A", "State"], id: \.self) { sort in
                        Button(sort) {
                            advancedScopeSort = sort
                        }
                    }
                } label: {
                    Label(advancedScopeSort, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.thinMaterial)

            Divider().opacity(0.32)

            DisclosureGroup("Edit package ID lists", isExpanded: $showPackageIDLists) {
                VStack(alignment: .leading, spacing: 8) {
                    managedNotice("Per-app package overrides", key: "AppPackageOverrides")
                    ForEach(["GarageBand", "Logic Pro"], id: \.self) { app in
                        HStack {
                            Text(app).frame(width: 85, alignment: .leading)
                            TextField("Skip package IDs", text: overrideBinding(for: app, key: \.skip))
                                .accessibilityLabel("\(app) package IDs to skip")
                            TextField("Only install package IDs", text: overrideBinding(for: app, key: \.only))
                                .accessibilityLabel("\(app) package IDs to install")
                        }
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.settingIsManaged("AppPackageOverrides") || model.settingIsManaged("RunAppContentSets"))
                    }
                    Text("Enter comma-separated package or receipt IDs. Only Install limits the app to those IDs. Skip takes precedence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(advancedScopeRows) { package in
                        advancedScopeRow(package)
                    }
                }
            }
            .background(LooperStyle.contentBackground)

            Divider().opacity(0.32)

            HStack {
                Text("\(advancedScopeRows.count) packages shown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        if !model.settingIsManaged("ExcludedPackageIDs") { draftExcludedPackageIDs.removeAll() }
                        if !model.settingIsManaged("PackagePriorities") { draftPackagePriorities.removeAll() }
                        if !model.settingIsManaged("AppPackageOverrides") && !model.settingIsManaged("RunAppContentSets") {
                            draftAppPackageOverrides.removeAll()
                        }
                    }
                } label: {
                    Label("Reset Overrides", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(LooperGlassButtonStyle(compact: true))
                .disabled(draftExcludedPackageIDs.isEmpty && draftPackagePriorities.isEmpty && draftAppPackageOverrides.isEmpty)

                Button {
                    showAdvancedScopeEditor = false
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(LooperGlassButtonStyle(compact: true))

                Button {
                    model.setPackagePreferences(
                        excludedPackageIDs: draftExcludedPackageIDs,
                        packagePriorities: draftPackagePriorities,
                        appPackageOverrides: draftAppPackageOverrides
                    )
                    showAdvancedScopeEditor = false
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(LooperGlassButtonStyle(compact: true))
                .disabled(!advancedScopeDraftHasChanges)
            }
            .padding(16)
            .background(.thinMaterial)
        }
        .background(LooperStyle.contentBackground)
    }

    private var advancedScopeAppOptions: [String] {
        ["All Apps"] + model.libraryApps
    }

    private var advancedScopeDraftHasChanges: Bool {
        draftAppPackageOverrides != model.appPackageOverrides
            || draftExcludedPackageIDs != model.excludedPackageIDs
            || draftPackagePriorities.filter { $0.value != 0 } != model.packagePriorities.filter { $0.value != 0 }
    }

    private func overrideBinding(for app: String, key: WritableKeyPath<AppPackageOverrides, String>) -> Binding<String> {
        Binding(
            get: { draftAppPackageOverrides[app, default: AppPackageOverrides()][keyPath: key] },
            set: { value in
                var overrides = draftAppPackageOverrides[app, default: AppPackageOverrides()]
                overrides[keyPath: key] = value
                draftAppPackageOverrides[app] = overrides == AppPackageOverrides() ? nil : overrides
            }
        )
    }

    private func openAdvancedScopeEditor() {
        showPackageIDLists = false
        draftAppPackageOverrides = model.appPackageOverrides
        draftExcludedPackageIDs = model.excludedPackageIDs
        draftPackagePriorities = model.packagePriorities
        showAdvancedScopeEditor = true
    }

    private func draftPackageKey(for package: LooperWindowModel.PackageRow) -> String {
        model.packagePreferenceKey(for: package)
    }

    private func draftPackageIsExcluded(_ package: LooperWindowModel.PackageRow) -> Bool {
        draftExcludedPackageIDs.contains(package.id)
            || package.pkgIdentifier.map { draftExcludedPackageIDs.contains($0) } == true
    }

    private func draftPackagePriority(_ package: LooperWindowModel.PackageRow) -> Int {
        if let priority = draftPackagePriorities[package.id] {
            return priority
        }
        if let identifier = package.pkgIdentifier,
           let priority = draftPackagePriorities[identifier] {
            return priority
        }
        return 0
    }

    private func setDraftPackageExcluded(_ package: LooperWindowModel.PackageRow, excluded: Bool) {
        let key = draftPackageKey(for: package)
        if excluded {
            draftExcludedPackageIDs.insert(key)
        } else {
            draftExcludedPackageIDs.remove(key)
            draftExcludedPackageIDs.remove(package.id)
        }
    }

    private func bumpDraftPackagePriority(_ package: LooperWindowModel.PackageRow, by delta: Int) {
        let key = draftPackageKey(for: package)
        let nextPriority = min(10, max(-10, draftPackagePriority(package) + delta))
        if nextPriority == 0 {
            draftPackagePriorities.removeValue(forKey: key)
        } else {
            draftPackagePriorities[key] = nextPriority
        }
    }

    private var advancedScopeRows: [LooperWindowModel.PackageRow] {
        let search = advancedScopeSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = model.rows.filter { package in
            let matchesSearch = search.isEmpty
                || package.displayName.lowercased().contains(search)
                || (package.pkgIdentifier ?? package.id).lowercased().contains(search)
            let matchesApp = advancedScopeAppFilter == "All Apps" || package.targetApps.contains(advancedScopeAppFilter)
            let matchesSet = advancedScopeSetFilter == "All Content" || package.matchesCatalogue(advancedScopeSetFilter, app: advancedScopeAppFilter == "All Apps" ? "" : advancedScopeAppFilter)
            return matchesSearch && matchesApp && matchesSet
        }

        return filtered.sorted { lhs, rhs in
            switch advancedScopeSort {
            case "A-Z":
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            case "Z-A":
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedDescending
            case "State":
                if lhs.state != rhs.state {
                    return lhs.state < rhs.state
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            default:
                let lhsPriority = draftPackagePriority(lhs)
                let rhsPriority = draftPackagePriority(rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func advancedScopeRow(_ package: LooperWindowModel.PackageRow) -> some View {
        let globalSkip = draftPackageIsExcluded(package)
        let apps = advancedScopeAppFilter == "All Apps" ? package.targetApps : [advancedScopeAppFilter]
        let aliases = Set([package.id, draftPackageKey(for: package)])
        let skippedApps = apps.filter { app in
            guard let overrides = draftAppPackageOverrides[app] else { return false }
            return !overrides.skippedIDs.isDisjoint(with: aliases)
        }
        let isExcluded = globalSkip || (!apps.isEmpty && skippedApps.count == apps.count)
        let partial = !isExcluded && !skippedApps.isEmpty
        let useGlobal = globalSkip || apps.isEmpty
        let priority = draftPackagePriority(package)

        return HStack(spacing: 12) {
            Button {
                if useGlobal {
                    setDraftPackageExcluded(package, excluded: !globalSkip)
                } else {
                    for app in apps {
                        let field = overrideBinding(for: app, key: \.skip)
                        var ids = field.wrappedValue.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        if isExcluded {
                            ids.removeAll { aliases.contains($0) }
                        } else if !ids.contains(where: aliases.contains) {
                            ids.append(draftPackageKey(for: package))
                        } else {
                            continue
                        }
                        field.wrappedValue = ids.filter { !$0.isEmpty }.joined(separator: ", ")
                    }
                }
            } label: {
                Label(isExcluded ? "Skipped" : (partial ? "Mixed" : "Skip"),
                      systemImage: isExcluded ? "minus.circle.fill" : (partial ? "circle.lefthalf.filled" : "minus.circle"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isExcluded || partial ? Color.orange : .secondary)
                    .frame(width: 70, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(globalSkip ? "Remove global exclusion" : "Skip for \(apps.joined(separator: ", ")). Currently skipped for \(skippedApps.isEmpty ? "no apps" : skippedApps.joined(separator: ", ")).")
            .disabled(useGlobal ? model.settingIsManaged("ExcludedPackageIDs") :
                        model.settingIsManaged("AppPackageOverrides") || model.settingIsManaged("RunAppContentSets"))

            VStack(alignment: .leading, spacing: 2) {
                Text(package.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(package.pkgIdentifier ?? package.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Text(package.targetApps.joined(separator: ", "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 132, alignment: .trailing)

                Text(package.packageSet)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(package.packageSet == "Essential" ? .green : LooperStyle.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())

                stateBadge(package.state)
                    .frame(width: 92, alignment: .trailing)

                Button {
                    bumpDraftPackagePriority(package, by: -1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(model.settingIsManaged("PackagePriorities") || priority <= -10)

                Text("\(priority)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(priority == 0 ? .secondary : LooperStyle.accent)
                    .frame(width: 28)

                Button {
                    bumpDraftPackagePriority(package, by: 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(model.settingIsManaged("PackagePriorities") || priority >= 10)
            }
        }
        .contextMenu {
            Button(globalSkip ? "Remove global exclusion" : "Skip globally") {
                setDraftPackageExcluded(package, excluded: !globalSkip)
            }
            .disabled(model.settingIsManaged("ExcludedPackageIDs"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background {
            if isExcluded {
                Rectangle().fill(Color.orange.opacity(0.055))
            } else if priority != 0 {
                Rectangle().fill(LooperStyle.accent.opacity(0.045))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LooperStyle.separator)
                .frame(height: 1)
                .padding(.leading, 56)
                .allowsHitTesting(false)
        }
    }

    private func runScopeSummary(_ scope: String) -> String {
        switch scope {
        case "Essential": return "Essential packages and updates to existing content"
        case "None": return "This app will be ignored"
        default: return "All catalogue packages for this app"
        }
    }

    private var filtersActive: Bool { modernPacksOnly || !filterStatus.isEmpty || !filterApp.isEmpty || !filterCatalogue.isEmpty }

    private func clearLibraryFilters() { modernPacksOnly = false; browseCategory = ""; filterStatus = ""; filterApp = ""; filterCatalogue = "" }

    private func libraryFilterPicker(_ title: String, _ selection: Binding<String>, _ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker(title, selection: selection) {
                Text("Any").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var visibleLibraryRows: [LooperWindowModel.PackageRow] {
        let query = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filtersActive && query.isEmpty { return model.rows }
        return model.rows.filter { row in
            let matchesStatus = filterStatus == "Failed"
                ? model.installState.failedPackages[row.id] != nil
                : filterStatus.isEmpty || row.state == filterStatus
            return (!modernPacksOnly || (row.isMusicAppsArchive && (browseCategory.isEmpty || row.kind == browseCategory))) && matchesStatus && row.matchesCatalogue(filterCatalogue, app: filterApp) &&
            (query.isEmpty || row.kind.localizedCaseInsensitiveContains(query) || row.displayName.localizedCaseInsensitiveContains(query) ||
             row.id.localizedCaseInsensitiveContains(query) || row.pkgIdentifier?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private func kindHeader(_ kind: String) -> some View {
        let symbol: String = switch kind {
        case "Drums & Percussion": "metronome"
        case "Synths": "waveform"
        case "Guitars": "guitars"
        case "Bass": "guitars.fill"
        case "Keys": "pianokeys"
        case "Orchestral": "music.quarternote.3"
        case "Vocals": "mic"
        case "Mixed": "square.stack.3d.up"
        case "Demo Song": "music.note.list"
        case "Electronic Music": "waveform"
        default: "tray"
        }
        return HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(LooperStyle.accent).frame(width: 18)
            Text(kind).font(.headline)
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LooperStyle.contentBackground
                .overlay(LooperStyle.waveformGradient.opacity(0.036))
                .overlay(Color.black.opacity(0.055))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LooperStyle.separator).frame(height: 1) }
    }

    private var packageBrowser: some View {
        let visible = visibleLibraryRows
        return ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if groupByKind {
                            let groups = Dictionary(grouping: visible, by: \.kind)
                            ForEach(groups.keys.sorted(), id: \.self) { kind in
                                Section {
                                    ForEach(groups[kind] ?? []) { package in
                                        packageRow(package, rowID: package.id).id(package.id)
                                    }
                                } header: {
                                    kindHeader(kind)
                                }
                            }
                        } else {
                            ForEach(visible) { package in packageRow(package, rowID: package.id).id(package.id) }
                        }
                    }
                    .padding(.bottom, 10)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 1
                } action: { _, scrolled in libraryScrolled = scrolled }
                .onChange(of: model.currentPackageID) {
                    guard model.currentPackageID != nil else {
                        libraryScrollTargetID = nil
                        return
                    }
                    guard let id = model.currentPackage?.id, visible.contains(where: { $0.id == id }) else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: libraryScrollTargetID) {
                    guard let id = libraryScrollTargetID else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    guard model.currentPackage != nil,
                          let id = libraryScrollTargetID else { return }
                    DispatchQueue.main.async {
                        withAnimation(.snappy(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            if model.isRefreshing && !model.hasLoadedSnapshot {
                loadingCatalogueView
            } else if visible.isEmpty && (filtersActive || !librarySearch.isEmpty) {
                ContentUnavailableView {
                    Label("No Matching Packages", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Search and Filters") { librarySearch = ""; clearLibraryFilters() }
                }
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    "No Catalogue",
                    systemImage: "shippingbox",
                    description: Text("Apple catalogue packages will appear here after discovery finishes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
    }

    private func focusActivityTarget() {
        if model.activityTitle == "Needs attention", !model.actionableFailures.failedPackages.isEmpty, !model.isRunning {
            clearLibraryFilters()
            librarySearch = ""
            filterStatus = "Failed"
            model.selectedSection = .library
            return
        }
        guard let package = model.currentPackage else {
            libraryScrollTargetID = nil
            model.focusActivityTarget()
            return
        }

        clearLibraryFilters()
        librarySearch = ""
        libraryScrollTargetID = nil
        let target = package.id
        model.focusActivityTarget()
        DispatchQueue.main.async {
            libraryScrollTargetID = target
        }
    }

    private var loadingCatalogueView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .tint(LooperStyle.accent)
            Text("Loading Apple catalogue")
                .font(.headline.weight(.semibold))
            Text("Reading Apple loops, receipts, and helper state.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applicationIcon(for appName: String) -> NSImage? {
        let bundleIdentifiers: [String: String] = [
            "GarageBand": "com.apple.garageband10",
            "Logic Pro": "com.apple.logic10",
        ]

        if let bundleIdentifier = bundleIdentifiers[appName],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        let candidatePaths = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
        ]
        if let path = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        return nil
    }

    private var settingsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    pageTitle("Settings", "Looper preferences and deployment controls.")

                    VStack(spacing: 6) {
                        ForEach(SettingsPane.allCases) { pane in
                            settingsPaneRow(pane)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 18)
                .frame(width: 300, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        settingsSaveStrip
                        settingsDetailPane
                    }
                    .padding(26)
                        .frame(maxWidth: 760, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollClipDisabled()
            }

        }
    }

    private func settingsPaneRow(_ pane: SettingsPane) -> some View {
        let isSelected = selectedSettingsPane == pane

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                selectedSettingsPane = pane
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pane.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? LooperStyle.accent : LooperStyle.accent.opacity(0.8))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.rawValue)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(pane.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LooperStyle.settingsTint(isSelected ? 0.23 : 0.055))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? LooperStyle.accent.opacity(0.65) : .clear, lineWidth: isSelected ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var settingsSaveStrip: some View {
        HStack(spacing: 10) {
            if model.settingsAreDirty {
                Label("Unsaved changes", systemImage: "pencil.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(LooperStyle.accent)
            } else {
                Label("Settings saved", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !model.managedSettingKeys.isEmpty {
                Label("Some settings are managed", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(LooperStyle.settingsTint(0.10)))
            }

            Spacer(minLength: 0)

            Button(action: model.revertSettings) {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.settingsAreDirty)

            Button(action: model.saveSettings) {
                Label("Save", systemImage: "checkmark")
            }
            .disabled(!model.settingsAreDirty)
        }
        .buttonStyle(LooperGlassButtonStyle(compact: true))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LooperStyle.settingsTint(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.settingsAreDirty ? LooperStyle.accent.opacity(0.45) : LooperStyle.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var settingsDetailPane: some View {
        switch selectedSettingsPane {
        case .scope:
            settingsSection("Run Scope", "scope", "Choose what the next manual or scheduled run should reconcile.") {
                managedNotice("Run scope", key: "RunAppContentSets")
                runScopeControls
            }
        case .schedule:
            settingsSection("Schedule", "calendar.badge.clock", "Configure automatic loop checks for managed machines.") {
                detailRow("Current", model.scheduleStatus.isInstalled ? "Every \(intervalText(model.scheduleStatus.interval))" : "Not scheduled")

                if model.settingIsManaged("ScheduledInstallEnabled") {
                    detailRow("Jamf scheduled installs", model.managedScheduleEnabled ? "Enabled" : "Disabled")
                    if let quietHours = model.managedScheduleQuietHours, !quietHours.isEmpty {
                        detailRow("Jamf quiet hours", quietHours)
                    }
                }

                scheduleFrequencyPanel
                quietHoursPanel
                exclusionPeriodsPanel

                HStack {
                    Button {
                        model.installSchedule(
                            interval: selectedScheduleInterval,
                            quietHours: quietHoursEnabled ? quietHoursArgument : nil,
                            exclusionPreset: exclusionPeriodsEnabled ? exclusionPreset : nil
                        )
                    } label: {
                        Label("Apply Schedule", systemImage: "calendar.badge.clock")
                    }
                    .disabled(model.settingIsManaged("ScheduledInstallEnabled"))
                    Button(role: .destructive, action: model.removeSchedule) {
                        Label("Remove", systemImage: "calendar.badge.minus")
                    }
                    .disabled(!model.scheduleStatus.isInstalled)
                }
                .buttonStyle(LooperGlassButtonStyle(compact: true))
            }
            .onAppear {
                syncScheduleControlsFromStatus()
            }
        case .logging:
            loggingSettingsPane
        case .notifications:
            notificationsSettingsPane
        case .caching:
            contentCachingSettingsPane
        case .helper:
            settingsSection("Privileged Helper", "lock.shield", "Runs installs and deletes with system privileges after approval.") {
                detailRow("Status", model.helperStatusText)
                Text("Looper.pkg installs the app and device helper together. An administrator can run the installer or deploy it through MDM.")
                    .foregroundStyle(.secondary)
            }
        case .behaviour:
            helperBehaviourSettingsPane
        case .deployment:
            deploymentSettingsPane
        case .about:
            aboutSettingsPane
        }
    }

    private var scheduleFrequencyPanel: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Frequency", systemImage: "clock")
                    .font(.headline.weight(.semibold))

                HStack(spacing: 12) {
                    Stepper(value: $scheduleAmount, in: 1...52) {
                        Text("\(scheduleAmount)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .leading)
                    }
                    .frame(width: 140)

                    LooperGlassSegmentedControl(
                        selection: $scheduleUnit,
                        options: [
                            ("Minutes", "Minutes"),
                            ("Hours", "Hours"),
                            ("Days", "Days"),
                            ("Weeks", "Weeks"),
                        ]
                    )
                    .frame(maxWidth: 420)
                }

                Text("Every \(scheduleAmount) \(scheduleUnit.lowercased()).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quietHoursPanel: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingToggleRow(
                    title: "Quiet Hours",
                    subtitle: quietHoursEnabled ? "\(hourText(quietStartHour)) to \(hourText(quietEndHour))" : "Off",
                    symbol: "moon.zzz",
                    isOn: $quietHoursEnabled
                )

                if quietHoursEnabled {
                    HStack(spacing: 16) {
                        hourStepper("Start", value: $quietStartHour)
                        hourStepper("End", value: $quietEndHour)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var exclusionPeriodsPanel: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingToggleRow(
                    title: "Exclusion Periods",
                    subtitle: exclusionPeriodsEnabled ? exclusionPreset : "Off",
                    symbol: "calendar.badge.exclamationmark",
                    isOn: $exclusionPeriodsEnabled
                )

                if exclusionPeriodsEnabled {
                    LooperGlassSegmentedControl(
                        selection: $exclusionPreset,
                        options: [
                            ("School Holidays", "School Holidays"),
                            ("Public Holidays", "Public Holidays"),
                            ("Custom Dates", "Custom Dates"),
                        ]
                    )
                    .frame(maxWidth: 520)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var notificationsSettingsPane: some View {
        settingsSection("Notifications", "bell.badge", "Choose when Looper should notify the signed-in user.") {
            detailRow("Permission", model.notificationStatusText)

            HStack {
                Button(action: model.requestNotificationAuthorisation) {
                    Label("Request Permission", systemImage: "bell.badge")
                }
                Button(action: model.sendTestNotification) {
                    Label("Send Test", systemImage: "paperplane")
                }
                Button(action: model.refreshNotificationStatus) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(LooperGlassButtonStyle(compact: true))

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    managedNotice("New loops notifications", key: "NotifyNewLoopsAvailable")
                    settingToggleRow(
                        title: "New Loops Available",
                        subtitle: "Notify when the catalogue has packages that are not installed.",
                        symbol: "shippingbox.and.arrow.backward",
                        isOn: notificationBinding(\.notifyNewLoopsAvailable)
                    )
                    .disabled(model.settingIsManaged("NotifyNewLoopsAvailable"))
                    Divider().opacity(0.35)
                    managedNotice("Relaunch prompts", key: "NotifyRelaunchPrompts")
                    settingToggleRow(
                        title: "Relaunch Prompts",
                        subtitle: "Prompt when loops are installed while GarageBand or Logic Pro is open.",
                        symbol: "arrow.clockwise.circle",
                        isOn: notificationBinding(\.notifyRelaunchPrompts)
                    )
                    .disabled(model.settingIsManaged("NotifyRelaunchPrompts"))
                    Divider().opacity(0.35)
                    managedNotice("Run failure notifications", key: "NotifyRunFailures")
                    settingToggleRow(
                        title: "Run Failures",
                        subtitle: "Notify when a helper run cannot finish cleanly.",
                        symbol: "exclamationmark.triangle",
                        isOn: notificationBinding(\.notifyRunFailures)
                    )
                    .disabled(model.settingIsManaged("NotifyRunFailures"))
                    Divider().opacity(0.35)
                    managedNotice("Run summary notifications", key: "NotifyRunSummaries")
                    settingToggleRow(
                        title: "Run Summaries",
                        subtitle: "Notify after successful scheduled runs.",
                        symbol: "checkmark.seal",
                        isOn: notificationBinding(\.notifyRunSummaries)
                    )
                    .disabled(model.settingIsManaged("NotifyRunSummaries"))
                }
            }
        }
    }

    private var helperBehaviourSettingsPane: some View {
        settingsSection("Helper Behaviour", "gearshape.2", "Choose how the helper should move packages through a run.") {
            managedNotice("Helper behaviour", key: "HelperRunMode")
            settingsCard {
                VStack(spacing: 10) {
                    helperModeRow(
                        .sequential,
                        title: "Sequential",
                        subtitle: "Download, verify, and install one package at a time. Best for lower free space."
                    )
                    Divider().opacity(0.35)
                    helperModeRow(
                        .staged,
                        title: "Staged",
                        subtitle: "Download scoped packages first, then install the local package cache in one install pass."
                    )
                }
            }
            .disabled(model.settingIsManaged("HelperRunMode"))
        }
    }

    private func helperModeRow(_ mode: LooperHelperRunMode, title: String, subtitle: String) -> some View {
        let selected = model.helperRunMode == mode

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                model.setHelperRunMode(mode)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(selected ? LooperStyle.accent : .secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func notificationBinding(_ keyPath: ReferenceWritableKeyPath<LooperWindowModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model.setNotification(keyPath, enabled: $0) }
        )
    }

    private var loggingSettingsPane: some View {
        settingsSection("Logging", "doc.text.magnifyingglass", "Control how long helper events are kept.") {
            managedNotice("Log retention", key: "LogRetentionDays")
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(LooperStyle.accent)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Retention")
                                .font(.headline.weight(.semibold))
                            Text("Keep structured log entries for \(model.logRetentionDays) day\(model.logRetentionDays == 1 ? "" : "s").")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Stepper(value: Binding(
                            get: { model.logRetentionDays },
                            set: { model.updateLogRetention(days: $0) }
                        ), in: 1...365) {
                            Text("\(model.logRetentionDays)")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .frame(width: 150)
                        .disabled(model.settingIsManaged("LogRetentionDays"))
                    }

                    LooperGlassSegmentedControl(
                        selection: Binding(
                            get: { retentionPreset(for: model.logRetentionDays) },
                            set: { preset in model.updateLogRetention(days: retentionDays(for: preset)) }
                        ),
                        options: [
                            ("7 Days", "7 Days"),
                            ("30 Days", "30 Days"),
                            ("90 Days", "90 Days"),
                            ("1 Year", "1 Year"),
                        ]
                    )
                    .frame(maxWidth: 520)
                    .disabled(model.settingIsManaged("LogRetentionDays"))
                }
            }

            detailRow("Structured Log", LooperPaths().eventLogFile.path)
            detailRow("Legacy Development Log", LooperPaths().legacyEventLogFile.path)

            HStack {
                Button(action: model.openLogInConsole) {
                    Label("Open in Console", systemImage: "text.magnifyingglass")
                }
                Button(action: model.copyLoggingToClipboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.events.isEmpty && model.liveOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(LooperGlassButtonStyle(compact: true))
        }
    }

    private var contentCachingSettingsPane: some View {
        settingsSection("Content Caching", "externaldrive.badge.wifi", "Check whether macOS can discover an Apple Content Caching server for loop downloads.") {
            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: contentCacheSymbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(contentCacheColour)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.contentCacheStatus.state.rawValue)
                            .font(.headline.weight(.semibold))
                        Text(model.contentCacheStatus.summary)
                            .font(.callout)
                        if !model.contentCacheStatus.detail.isEmpty {
                            Text(model.contentCacheStatus.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.contentCacheStatus.servers) { server in
                            HStack {
                                Text(server.endpoint).monospacedDigit().textSelection(.enabled)
                                if let healthy = server.healthy {
                                    Text(healthy ? "Healthy" : "Unhealthy")
                                        .foregroundStyle(healthy ? Color.green : .orange)
                                }
                                if server.favored { Text("Preferred").foregroundStyle(.secondary) }
                            }.font(.callout)
                        }
                    }

                    Spacer(minLength: 0)

                    Button(action: model.refreshContentCacheStatus) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LooperGlassButtonStyle(compact: true))
                }
            }

            detailRow("Last checked", model.contentCacheStatus.checkedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Looper downloads").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow {
                            Text("Source")
                            Text("Installs")
                            Text("Downloaded")
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(DownloadSource.allCases, id: \.self) { source in
                            cacheStatisticsRow(source.rawValue, model.installState.transferTotals[source.rawValue] ?? TransferTotals())
                        }
                        Divider()
                        let total = model.installState.transferTotals.values.reduce(into: TransferTotals()) {
                            $0.bytes += $1.bytes
                            $0.installs += $1.installs
                        }
                        cacheStatisticsRow("Total", total).fontWeight(.semibold)
                    }
                    Text("Counts completed installs and download payloads on this Mac since Looper 1.3.22. Unattributed means the connection source could not be verified.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup {
                ScrollView {
                    Text(model.contentCacheStatus.rawOutput.isEmpty ? "No diagnostic output has been captured." : model.contentCacheStatus.rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(LooperStyle.settingsTint(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LooperStyle.separator)
                        .allowsHitTesting(false)
                }
            } label: {
                Label("Diagnostic Output", systemImage: "terminal")
                    .font(.headline.weight(.semibold))
            }
        }
        .onAppear {
            if model.contentCacheStatus.state == .unknown {
                model.refreshContentCacheStatus()
            }
        }
    }

    private func cacheStatisticsRow(_ name: String, _ totals: TransferTotals) -> some View {
        GridRow {
            Text(name)
            Text(totals.installs, format: .number).monospacedDigit()
            Text(totals.bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file))
                .monospacedDigit()
        }
    }

    private var contentCacheSymbol: String {
        switch model.contentCacheStatus.state {
        case .available: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .checking: return "magnifyingglass"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var contentCacheColour: Color {
        switch model.contentCacheStatus.state {
        case .available: return .green
        case .unavailable: return .orange
        case .warning: return .orange
        case .checking: return LooperStyle.accent
        case .unknown: return .secondary
        }
    }

    private func retentionPreset(for days: Int) -> String {
        switch days {
        case 7: return "7 Days"
        case 30: return "30 Days"
        case 90: return "90 Days"
        case 365: return "1 Year"
        default: return "30 Days"
        }
    }

    private func retentionDays(for preset: String) -> Int {
        switch preset {
        case "7 Days": return 7
        case "90 Days": return 90
        case "1 Year": return 365
        default: return 30
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LooperStyle.settingsTint(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LooperStyle.separator)
                    .allowsHitTesting(false)
            }
    }

    private func settingToggleRow(title: String, subtitle: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(isOn.wrappedValue ? LooperStyle.accent : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isOn.wrappedValue.toggle()
                }
            } label: {
                ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Capsule()
                        .fill(LooperStyle.settingsTint(0.10))
                        .overlay {
                            Capsule()
                                .strokeBorder(isOn.wrappedValue ? LooperStyle.accent.opacity(0.52) : LooperStyle.separator)
                                .allowsHitTesting(false)
                        }
                    Circle()
                        .fill(isOn.wrappedValue ? LooperStyle.accent : Color.secondary.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .padding(3)
                }
                .frame(width: 44, height: 24)
            }
            .buttonStyle(.plain)
        }
    }

    private func hourStepper(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...23) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(hourText(value.wrappedValue))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 82, alignment: .leading)
        }
        .frame(width: 150)
    }

    private func openSetup() {
        setupRunAccepted = false
        submittingSetupRun = false
        setupScopes = model.runScopeByApp
        setupScheduleStep = false
        setupSchedule = "Keep"
        setupRunNow = true
        setupError = nil
        showingSetup = true
    }

    private var canRunAfterSetup: Bool {
        let scopes = model.settingIsManaged("RunAppContentSets") ? model.runScopeByApp : setupScopes
        return scopes.values.contains { $0 != "None" } && !model.helperBusy
    }

    private func finishSetup() {
        let run = setupRunNow && canRunAfterSetup
        savingSetup = true
        submittingSetupRun = run
        setupError = nil
        Task {
            defer { savingSetup = false; submittingSetupRun = false }
            do {
                try await model.applySetup(scopes: setupScopes, schedule: setupSchedule,
                                           interval: TimeInterval(setupInterval) * 3600, runNow: run)
                completedSetup = true
                if run {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        setupRunAccepted = true
                    }
                    try? await Task.sleep(for: .milliseconds(600))
                    model.selectedSection = .library
                }
                showingSetup = false
            } catch { setupError = error.localizedDescription }
        }
    }

    private var setupAssistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: LooperStyle.appIcon)
                    .resizable().interpolation(.high).frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Looper Setup Assistant").font(.subheadline).foregroundStyle(.secondary)
                    Text(setupScheduleStep ? "Schedule" : "Sound catalogue").font(.largeTitle.bold())
                }
                Spacer()
                Text(setupScheduleStep ? "2 of 2" : "1 of 2")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(LooperStyle.glassBar)

            VStack(alignment: .leading, spacing: 12) {
                if setupScheduleStep {
                    settingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Automatic runs", systemImage: "calendar.badge.clock").font(.headline)
                            if model.settingIsManaged("ScheduledInstallEnabled") {
                                Text(model.managedScheduleEnabled ? "Enabled by your organisation" : "Disabled by your organisation")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Schedule", selection: $setupSchedule) {
                                    Text(model.scheduleStatus.isInstalled ? "Keep current schedule" : "Manual runs only").tag("Keep")
                                    if model.scheduleStatus.isInstalled { Text("Manual runs only").tag("Manual") }
                                    Text("Repeat automatically").tag("Repeat")
                                }
                                if setupSchedule == "Repeat" {
                                    Stepper("Every \(setupInterval) hours", value: $setupInterval, in: 1...168)
                                }
                            }
                        }
                    }
                    settingsCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Run now after setup", isOn: Binding(
                                get: { setupRunNow && canRunAfterSetup }, set: { setupRunNow = $0 }
                            ))
                            .toggleStyle(.checkbox).font(.headline).disabled(!canRunAfterSetup)
                            Text(canRunAfterSetup ? "Download and install missing sounds from your selected catalogue."
                                 : (model.helperBusy ? "The helper already has work in progress." : "Select a catalogue on the previous step to start a run."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(["GarageBand", "Logic Pro"], id: \.self) { app in
                        runScopeAppPanel(app, draft: Binding(get: { setupScopes[app] ?? "None" }, set: { setupScopes[app] = $0 }))
                            .disabled(model.settingIsManaged("RunAppContentSets"))
                    }
                    ScopeStorageEstimate(packages: model.pendingPackages(for: model.settingIsManaged("RunAppContentSets") ? model.runScopeByApp : setupScopes))
                    managedNotice("Run scope", key: "RunAppContentSets")
                }
                if let setupError {
                    Label(setupError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 285, alignment: .topLeading)

            Divider()
            HStack {
                Button(completedSetup ? "Cancel" : "Skip Setup") { completedSetup = true; showingSetup = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if setupScheduleStep {
                    Button("Back") { setupScheduleStep = false; setupError = nil }
                        .buttonStyle(LooperGlassButtonStyle(compact: true))
                }
                Button {
                    if setupScheduleStep { finishSetup() } else { setupScheduleStep = true }
                } label: {
                    if setupScheduleStep && (submittingSetupRun || (setupRunNow && canRunAfterSetup)) {
                        Label {
                            Text(setupRunAccepted ? "Run queued" : "Save and Run")
                        } icon: {
                            Image(systemName: setupRunAccepted ? "checkmark" : "play.fill")
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                    } else {
                        Text(setupScheduleStep ? "Finish Setup" : "Continue")
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(LooperStyle.glassBar)
        }
        .frame(width: 570)
        .background(LooperStyle.contentBackground.overlay(LooperStyle.settingsTint(0.06)))
        .tint(LooperStyle.accent)
        .disabled(savingSetup)
        .interactiveDismissDisabled(savingSetup)
    }

    private var deploymentSettingsPane: some View {
        settingsSection("Deployment", "square.and.arrow.up", "Build a Jamf deployment from Looper’s saved settings on this Mac.") {
            Picker("Export format", selection: $exportFormat) {
                ForEach(DeploymentExport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: exportFormat) { _, _ in exportMessage = nil }
            if exportFormat == .schema {
                Text("Import the schema into Application & Custom Settings → External Applications for com.maxhewett.Looper to build a settings form in Jamf.")
            } else {
                Text(exportFormat == .profile
                     ? "Upload the profile in Jamf Pro → Computers → Configuration Profiles. It includes the saved preferences and background-item approvals. Deploy Looper.pkg through a policy."
                     : "Upload the plist in Application & Custom Settings using the preference domain com.maxhewett.Looper.")
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Skip Setup Assistant", isOn: $exportSkipSetup)
                        Toggle("Preload at deployment, boot and hourly", isOn: $exportPreload)
                        Toggle("Allow scheduled runs from Jamf", isOn: $exportScheduled)
                        if exportScheduled {
                            Text("Set the frequency in a Jamf policy that runs /usr/local/bin/looper install --scheduled.")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let hours = deploymentQuietHours, !hours.isEmpty {
                            Text("Quiet hours: " + hours).font(.callout).foregroundStyle(.secondary)
                        }
                        if model.scheduleStatus.isInstalled {
                            Text("Local LaunchAgent timing and calendar exclusions stay on this Mac. Configure the equivalent schedule in Jamf.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.settingsAreDirty { Text("Save your settings above to include the changes in this export.").foregroundStyle(.secondary) }
            }
            Button { saveDeploymentExport() } label: { Label("Export File…", systemImage: "square.and.arrow.up") }
                .buttonStyle(LooperGlassButtonStyle(compact: true))
                .disabled(exportFormat != .schema && model.settingsAreDirty)
            if let exportMessage { Text(exportMessage).font(.callout).textSelection(.enabled) }
        }
        .onAppear {
            guard !initializedExport else { return }
            initializedExport = true
            exportSkipSetup = !model.settingIsManaged("SkipSetupAssistant") || LooperSettingsStore.skipSetupAssistant
            exportScheduled = model.settingIsManaged("ScheduledInstallEnabled") ? model.managedScheduleEnabled : model.scheduleStatus.isInstalled
            exportPreload = model.settingIsManaged("ManagedPreloadEnabled") ? LooperSettingsStore.managedPreloadEnabled : !exportScheduled
        }
    }

    private var deploymentQuietHours: String? {
        if model.settingIsManaged("ScheduleQuietHours") { return model.managedScheduleQuietHours }
        let args = model.scheduleStatus.arguments
        guard let i = args.firstIndex(of: "--quiet-hours"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private func saveDeploymentExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportFormat.filename
        if let type = UTType(filenameExtension: (exportFormat.filename as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            let data = try exportFormat.data(settings: model.savedDeploymentSettings, skipSetup: exportSkipSetup,
                                             preload: exportPreload, scheduled: exportScheduled,
                                             quietHours: deploymentQuietHours, resources: resources)
            try data.write(to: destination, options: .atomic)
            exportMessage = "Exported " + destination.lastPathComponent
        } catch { exportMessage = "Export failed. " + error.localizedDescription }
    }

    private var aboutSettingsPane: some View {
        settingsSection("About", "info.circle", "App, catalogue, and build information.") {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: LooperStyle.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(bundleString("CFBundleDisplayName") ?? bundleString("CFBundleName") ?? "Looper")
                        .font(.title2.weight(.bold))
                    Text(appVersionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(appDeveloperText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            Button("Run Setup Assistant…", action: openSetup)
            detailRow("Bundle Identifier", bundleString("CFBundleIdentifier") ?? "Unknown")
            detailRow("Minimum macOS", bundleString("LSMinimumSystemVersion") ?? "15.0")
            detailRow("Last run", model.lastRunText)
            detailRow("Catalogue updated", model.catalogueUpdatedText)
            detailRow("Catalogue source", model.catalogueSource)
            detailRow("Available packages", "\(model.availableCount)")
            detailRow("Installed packages", "\(model.installedDisplayCount)")
            detailRow("Installed receipts", "\(model.receiptCount)")
        }
    }

    private var outputView: some View {
        VStack(spacing: 0) {
            loggingHeader
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.35)

            if model.isRefreshing && !model.hasLoadedSnapshot {
                loadingLoggingView
            } else if displayedLogEntries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Helper events matching the current filters will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .top) {
                    ScrollViewReader { proxy in
                        GeometryReader { viewportProxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(logDaySections) { section in
                                        Section {
                                            ForEach(section.events) { event in
                                                logEntryRow(event, dateTitle: section.title)
                                                    .id(event.id)
                                            }
                                        } header: {
                                            logDateHeader(section.title)
                                        }
                                    }

                                    Color.clear
                                        .frame(height: 40)
                                        .id(logBottomAnchorID)
                                        .background {
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: LogBottomPositionPreferenceKey.self,
                                                    value: proxy.frame(in: .named(logScrollCoordinateSpace)).minY
                                                )
                                            }
                                        }
                                }
                                .padding(.top, 36)
                            }
                            .coordinateSpace(name: logScrollCoordinateSpace)
                            .onPreferenceChange(LogHeaderPositionPreferenceKey.self) { positions in
                                updateVisibleLogDate(from: positions)
                            }
                            .onPreferenceChange(LogBottomPositionPreferenceKey.self) { bottomY in
                                if isFollowingLogs && bottomY > viewportProxy.size.height + 80 {
                                    setLogFollowing(false)
                                }
                            }
                            .onChange(of: filteredLogEntries.count) {
                                if isFollowingLogs {
                                    scrollLoggingToBottom(proxy)
                                }
                            }
                            .onChange(of: logScrollRequest) {
                                scrollLoggingToBottom(proxy)
                            }
                            .onAppear {
                                updateVisibleLogDate(from: [])
                                if isFollowingLogs {
                                    scrollLoggingToBottom(proxy)
                                }
                            }
                        }
                    }

                    currentLogDateBar
                        .zIndex(2)
                }
            }

        }
    }

    private var loadingLoggingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .tint(LooperStyle.accent)
            Text("Loading logging")
                .font(.headline.weight(.semibold))
            Text("Reading structured helper events and retained log files.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loggingHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Logging")
                    .font(.largeTitle.weight(.bold))
                Text("\(displayedLogEntries.count) of \(model.events.count) entr\(model.events.count == 1 ? "y" : "ies") • \(logRangeFilter)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                compactPopoverButton("Level", "line.3.horizontal.decrease.circle", isPresented: $showLogLevelPopover) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Level")
                            .font(.headline.weight(.semibold))
                        LooperGlassSegmentedControl(
                            selection: $logLevelFilter,
                            options: [
                                ("All", "All"),
                                ("Errors", "Errors"),
                                ("Warnings", "Warnings"),
                                ("Info", "Info"),
                            ]
                        )
                        .frame(width: 300)
                    }
                    .padding(14)
                }

                compactPopoverButton("Range", "calendar", isPresented: $showLogRangePopover) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Range")
                            .font(.headline.weight(.semibold))
                        LooperGlassSegmentedControl(
                            selection: $logRangeFilter,
                            options: [
                                ("Today", "Today"),
                                ("7 Days", "Last 7 Days"),
                                ("30 Days", "Last 30 Days"),
                                ("All", "All"),
                            ]
                        )
                        .frame(width: 360)
                    }
                    .padding(14)
                }

                Button {
                    let shouldFollow = !isFollowingLogs
                    setLogFollowing(shouldFollow)
                    if shouldFollow {
                        logScrollRequest += 1
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 26, height: 24)
                }
                .foregroundStyle(isFollowingLogs ? LooperStyle.accent : .secondary)
                .background(isFollowingLogs ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background {
                    if isFollowingLogs {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LooperStyle.accent.opacity(livePulse ? 0.20 : 0.06))
                            .blur(radius: livePulse ? 7 : 3)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: livePulse)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isFollowingLogs ? LooperStyle.accent.opacity(0.80) : LooperStyle.separator, lineWidth: isFollowingLogs ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .onAppear {
                    livePulse = true
                }
                .help(isFollowingLogs ? "Following the newest log entries" : "Manual scrolling")

                Button(action: model.openLogInConsole) {
                    Image(systemName: "text.magnifyingglass")
                        .frame(width: 26, height: 24)
                }
                .foregroundStyle(.secondary)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LooperStyle.separator)
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .help("Open Looper log in Console")

                Button(action: model.copyLoggingToClipboard) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 26, height: 24)
                }
                .foregroundStyle(.secondary)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LooperStyle.separator)
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .disabled(model.events.isEmpty && model.liveOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Copy visible logging")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooperStyle.libraryHeaderBackground)
    }

    private var currentLogDateBar: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(LooperStyle.accent.opacity(0.34))
                .frame(height: 1)
            Label(currentLogDateTitle, systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Rectangle()
                .fill(LooperStyle.accent.opacity(0.34))
                .frame(height: 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(LooperStyle.logStickyDateBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LooperStyle.separator)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private var currentLogDateTitle: String {
        let sectionTitles = Set(logDaySections.map(\.title))
        if sectionTitles.contains(visibleLogDateTitle) {
            return visibleLogDateTitle
        }
        return logDaySections.first?.title ?? "No log entries"
    }

    private var logScrollCoordinateSpace: String {
        "LooperLogScroll"
    }

    private func compactPopoverButton<Content: View>(
        _ label: String,
        _ symbol: String,
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .frame(width: 26, height: 24)
        }
        .foregroundStyle(.secondary)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LooperStyle.separator)
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .help(label)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            content()
        }
    }

    private var logBottomAnchorID: String {
        "looper-log-bottom"
    }

    private var selectedScheduleInterval: TimeInterval {
        let multiplier: TimeInterval
        switch scheduleUnit {
        case "Minutes": multiplier = 60
        case "Days": multiplier = 86_400
        case "Weeks": multiplier = 604_800
        default: multiplier = 3_600
        }
        return TimeInterval(scheduleAmount) * multiplier
    }

    private var quietHoursArgument: String {
        "\(quietStartHour)-\(quietEndHour)"
    }

    private func syncScheduleControlsFromStatus() {
        guard let interval = model.scheduleStatus.interval else { return }
        let seconds = Int(interval)

        if seconds >= 604_800, seconds % 604_800 == 0 {
            scheduleUnit = "Weeks"
            scheduleAmount = max(1, seconds / 604_800)
        } else if seconds >= 86_400, seconds % 86_400 == 0 {
            scheduleUnit = "Days"
            scheduleAmount = max(1, seconds / 86_400)
        } else if seconds >= 3_600, seconds % 3_600 == 0 {
            scheduleUnit = "Hours"
            scheduleAmount = max(1, seconds / 3_600)
        } else {
            scheduleUnit = "Minutes"
            scheduleAmount = max(1, seconds / 60)
        }
    }

    private func hourText(_ hour: Int) -> String {
        let clamped = min(23, max(0, hour))
        let date = Calendar.current.date(from: DateComponents(hour: clamped, minute: 0)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var filteredLogEntries: [LooperEvent] {
        model.events
            .filter { event in
                levelMatches(event) && rangeMatches(event)
            }
            .sorted(by: logSort)
    }

    private var displayedLogEntries: [LooperEvent] {
        frozenLogEntries ?? filteredLogEntries
    }

    private var logDaySections: [LogDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: displayedLogEntries) { event in
            calendar.startOfDay(for: event.timestamp)
        }

        return grouped.keys.sorted().map { day in
            LogDaySection(
                day: day,
                title: day.formatted(date: .complete, time: .omitted),
                events: grouped[day] ?? []
            )
        }
    }

    private func setLogFollowing(_ shouldFollow: Bool) {
        if shouldFollow {
            frozenLogEntries = nil
            isFollowingLogs = true
        } else {
            frozenLogEntries = filteredLogEntries
            isFollowingLogs = false
        }
    }

    private func logSort(_ lhs: LooperEvent, _ rhs: LooperEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }

        let lhsRank = logOrderingRank(lhs)
        let rhsRank = logOrderingRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.id < rhs.id
    }

    private func logOrderingRank(_ event: LooperEvent) -> Int {
        let text = "\(event.category) \(event.message)".lowercased()
        if text.contains("download") && text.contains("start") { return 10 }
        if text.contains("downloading") { return 12 }
        if text.contains("downloaded") { return 20 }
        if text.contains("install") && text.contains("start") { return 30 }
        if text.contains("installing") { return 32 }
        if text.contains("installed") { return 40 }
        if text.contains("finished") || text.contains("completed") { return 90 }
        return 50
    }

    private func updateVisibleLogDate(from positions: [LogHeaderPosition]) {
        let fallbackTitle = logDaySections.first?.title ?? "No log entries"
        guard !positions.isEmpty else {
            if !Set(logDaySections.map(\.title)).contains(visibleLogDateTitle) {
                visibleLogDateTitle = fallbackTitle
            }
            return
        }

        let sortedPositions = positions.sorted { $0.minY < $1.minY }
        let stickyThreshold: CGFloat = 42
        let currentTitle = sortedPositions.last(where: { $0.minY <= stickyThreshold })?.title
            ?? sortedPositions.first(where: { $0.minY > stickyThreshold })?.title
            ?? fallbackTitle

        if visibleLogDateTitle != currentTitle {
            visibleLogDateTitle = currentTitle
        }
    }

    private func levelMatches(_ event: LooperEvent) -> Bool {
        switch logLevelFilter {
                case "Errors": return event.level == .error
                case "Warnings": return event.level == .warning
                case "Info": return [.debug, .info, .success].contains(event.level)
                default: return true
        }
    }

    private func rangeMatches(_ event: LooperEvent) -> Bool {
        guard let cutoff = logRangeCutoff else { return true }
        return event.timestamp >= cutoff
    }

    private var logRangeCutoff: Date? {
        switch logRangeFilter {
        case "Today":
            return Calendar.current.startOfDay(for: Date())
        case "Last 30 Days":
            return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case "All":
            return nil
        default:
            return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        }
    }

    private func scrollLoggingToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(logBottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func logEntryRow(_ event: LooperEvent, dateTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.level.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(eventColour(event.level))
                Text(event.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(event.message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)

            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let identifier = event.packageIdentifier {
                Text(identifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LogHeaderPositionPreferenceKey.self,
                    value: [LogHeaderPosition(title: dateTitle, minY: proxy.frame(in: .named(logScrollCoordinateSpace)).minY)]
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LooperStyle.separator)
                .frame(height: 1)
                .padding(.leading, 22)
                .padding(.trailing, 22)
                .allowsHitTesting(false)
        }
    }

    private func logDateHeader(_ title: String) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
            Label(title, systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
    }

    private var statusSymbol: String {
        switch model.statusLevel {
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var statusColour: Color {
        switch model.statusLevel {
        case .running: return LooperStyle.accent
        case .normal: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func eventColour(_ level: LooperEvent.Level) -> Color {
        switch level {
        case .debug: return LooperStyle.accent.opacity(0.72)
        case .info: return LooperStyle.accent
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private func pageTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsSection<Content: View>(_ title: String, _ symbol: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooperStyle.settingsTint(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LooperStyle.separator)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func managedNotice(_ title: String, key: String) -> some View {
        if model.settingIsManaged(key) {
            Label("\(title) is managed by a configuration profile.", systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LooperStyle.settingsTint(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LooperStyle.separator)
                        .allowsHitTesting(false)
                }
        }
    }

    private func compactMetric(_ title: String, _ value: Int, _ symbol: String, _ colour: Color) -> some View {
        compactMetric(title, "\(value)", symbol, colour)
    }

    private func compactMetric(_ title: String, _ value: String, _ symbol: String, _ colour: Color, animateChanges: Bool = true, installationPulse: Int? = nil) -> some View {
        MetricPill(title: title, value: value, symbol: symbol, colour: colour, animateChanges: animateChanges, installationPulse: installationPulse)
    }

    private func packageRow(_ package: LooperWindowModel.PackageRow, rowID: String) -> some View {
        let isActivePackage = model.currentPackageID.map { $0 == package.id || $0 == package.pkgIdentifier } ?? false
        let rowProgress = isActivePackage ? model.currentPackageRowProgress : 0
        let usesIndeterminateFill = isActivePackage && model.activityTitle == "Installing"

        return HStack(spacing: 8) {
            HStack(spacing: 10) {
                if isActivePackage {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LooperStyle.accent)
                        .frame(width: 16, height: 16)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        ForEach(package.targetApps, id: \.self) { app in
                            let essential = package.essentialApps.contains(app)
                            HStack(spacing: 4) {
                                if app == "Logic Pro" || app == "GarageBand" {
                                    Image(app == "Logic Pro" ? "LogicProBadge" : "GarageBandBadge")
                                        .resizable().interpolation(.high).scaledToFit()
                                        .frame(width: 16, height: 16).accessibilityHidden(true)
                                }
                                Text(essential ? "\(app) · Essential" : app)
                            }
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(LooperStyle.settingsTint(essential ? 0.18 : 0.08), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 12)
                Text(package.downloadSize.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? "—")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing).help("Download size")
                VStack(alignment: .trailing, spacing: 4) {
                    stateBadge(isActivePackage ? model.activityTitle : (package.state == "Failed" && model.isSkipped(package) ? "Skipped" : package.state))
                }
                .frame(width: 110, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                packageActionButton("Details", "info.circle") {
                    infoPackageID = rowID
                }
                .popover(
                    isPresented: Binding(
                        get: { infoPackageID == rowID },
                        set: { isPresented in
                            if !isPresented {
                                infoPackageID = nil
                            }
                        }
                    ),
                    arrowEdge: .trailing
                ) {
                    packageInfoPopover(package)
                        .frame(width: 340)
                }

                if package.state == "Failed" {
                    packageActionButton(model.isSkipped(package) ? "Skipped in Advanced Scope" : "Skip in Advanced Scope",
                                        model.isSkipped(package) ? "minus.circle.fill" : "minus.circle") {
                        model.skipFailedPackage(package)
                    }
                    .disabled(model.isSkipped(package) || model.settingIsManaged("AppPackageOverrides") || model.settingIsManaged("RunAppContentSets"))
                } else {
                    packageActionButton("Show in Finder", "folder") { model.revealPackageInFinder(package) }
                        .disabled(package.pkgIdentifier == nil || package.state == "Missing")
                }

                packageActionButton((package.state == "Failed" ? "Retry " : "Install ") + package.displayName, package.state == "Failed" ? "arrow.clockwise.circle" : "arrow.down.circle") {
                    model.installPackage(package)
                }
                .disabled(package.url == nil || model.isSkipped(package) || ["Installed", "Deleting"].contains(package.state) ||
                          model.isRunning || model.pendingRunAt != nil || model.helperActionIsRunning)

                packageActionButton(deleteButtonTitle(for: package.state), deleteButtonSymbol(for: package.state), role: .destructive) {
                    model.deletePackage(package)
                }
                .disabled(package.pkgIdentifier == nil || package.state == "Deleting")
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.vertical, 7)
        .background {
            if isActivePackage {
                PackageRowProgressBackground(
                    progress: rowProgress,
                    isIndeterminate: usesIndeterminateFill
                )
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LooperStyle.separator)
                .frame(height: 1)
                .padding(.leading, 22)
                .padding(.trailing, 22)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button {
                infoPackageID = rowID
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button {
                model.revealPackageInFinder(package)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(package.pkgIdentifier == nil || package.state == "Missing")
            Button(role: .destructive) {
                model.deletePackage(package)
            } label: {
                Label(deleteButtonTitle(for: package.state), systemImage: deleteButtonSymbol(for: package.state))
            }
            .disabled(package.pkgIdentifier == nil || package.state == "Deleting")
        }
    }

    private func packageActionButton(_ label: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .secondary)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
                .allowsHitTesting(false)
        }
        .help(label)
    }

    private func packageInfoPopover(_ package: LooperWindowModel.PackageRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "music.note")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LooperStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    stateBadge(package.state)
                    Text(package.displayName)
                        .font(.headline.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            detailRow("Identifier", package.pkgIdentifier ?? package.id)
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.pkgIdentifier ?? package.id, forType: .string)
            }
            detailRow("Apps", package.targetApps.joined(separator: ", "))
            if !package.essentialApps.isEmpty { detailRow("Essential for", package.essentialApps.joined(separator: ", ")) }
            detailRow("Kind", package.kind)
            detailRow("Source", package.source)
            if let url = package.url {
                detailRow("URL", url.absoluteString)
            }
        }
        .padding(18)
    }

    private func stateBadge(_ state: String) -> some View {
        Text(state)
            .font(.caption.weight(.bold))
            .foregroundStyle(stateColour(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColour(state).opacity(0.14), in: Capsule())
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appVersionText: String {
        let version = bundleString("CFBundleShortVersionString") ?? "1.0"
        let build = bundleString("CFBundleVersion")
        guard let build, !build.isEmpty, build != version else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
    }

    private var appDeveloperText: String {
        bundleString("NSHumanReadableCopyright") ?? "Max Hewett"
    }

    private func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private func stateColour(_ state: String) -> Color {
        switch state {
        case "Installed": return .green
        case "Missing": return .orange
        case "Update Available": return .orange
        case "Downloading": return LooperStyle.accent
        case "Installing": return LooperStyle.accent
        case "Running": return LooperStyle.accent
        case "Failed": return .red
        case "Deleting": return .orange
        case "Helper Stalled": return .orange
        case "Delete Failed": return .red
        default: return .secondary
        }
    }

    private func deleteButtonTitle(for state: String) -> String {
        switch state {
        case "Deleting": return "Deleting"
        case "Helper Stalled": return "Retry Delete"
        case "Delete Failed": return "Retry Delete"
        default: return "Delete Package"
        }
    }

    private func deleteButtonSymbol(for state: String) -> String {
        switch state {
        case "Deleting": return "arrow.triangle.2.circlepath"
        case "Helper Stalled": return "arrow.clockwise"
        case "Delete Failed": return "arrow.clockwise"
        default: return "trash"
        }
    }

    private func intervalText(_ interval: TimeInterval?) -> String {
        guard let interval else { return "unknown" }
        switch Int(interval) {
        case 3_600: return "hour"
        case 21_600: return "6 hours"
        case 43_200: return "12 hours"
        case 86_400: return "day"
        case 604_800: return "week"
        default: return "\(Int(interval)) seconds"
        }
    }
}

/// Animate the five painted bars while preserving the surrounding artwork.
private struct SidebarWaveform: View {
    let runID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Pixel bounds in the 128-point SidebarWaveform artwork, including antialiasing.
    private static let bars = [
        CGRect(x: 32, y: 56, width: 12, height: 21),
        CGRect(x: 45, y: 49, width: 12, height: 34),
        CGRect(x: 58, y: 40, width: 12, height: 51),
        CGRect(x: 71, y: 49, width: 12, height: 34),
        CGRect(x: 84, y: 56, width: 12, height: 21)
    ]

    var body: some View {
        if reduceMotion {
            Image("SidebarWaveform").resizable().interpolation(.high)
        } else {
            Color.clear.keyframeAnimator(initialValue: 0.0, trigger: runID) { _, progress in
                Canvas { context, size in
                    let artwork = context.resolve(Image("SidebarWaveform"))
                    let bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
                    context.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
                    if progress <= 0 || progress >= 1 {
                        context.draw(artwork, in: bounds)
                        return
                    }
                    var ring = context
                    var outline = Path(bounds)
                    for bar in Self.bars { outline.addRect(bar) }
                    ring.clip(to: outline, style: FillStyle(eoFill: true))
                    ring.draw(artwork, in: bounds)
                    for (index, bar) in Self.bars.enumerated() {
                        let beat = min(1, max(0, progress * 2 - Double(index) * 0.24))
                        let stretch = 1 + 0.25 * sin(beat * 2 * .pi) * sin(beat * .pi)
                        var segment = context
                        segment.translateBy(x: 0, y: bar.midY)
                        segment.scaleBy(x: 1, y: stretch)
                        segment.translateBy(x: 0, y: -bar.midY)
                        segment.clip(to: Path(bar))
                        segment.draw(artwork, in: bounds)
                    }
                }
            } keyframes: { _ in
                MoveKeyframe(0.0)
                LinearKeyframe(1.0, duration: 0.8)
            }
        }
    }
}

private struct MetricPill: View {
    private struct Particle: Identifiable {
        let id = UUID()
        let text: String
        let x: CGFloat
        let y: CGFloat
        let delay: Double
    }

    private enum PulseKind {
        case increase
        case decrease
    }

    let title: String
    let value: String
    let symbol: String
    let colour: Color
    let animateChanges: Bool
    let installationPulse: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsMotion: Bool { animateChanges && !reduceMotion }

    @State private var previousNumericValue: Int?
    @State private var particles: [Particle] = []
    @State private var particlesExpanded = false
    @State private var pulseKind: PulseKind?
    @State private var shakeOffset: CGFloat = 0

    private var numericValue: Int? {
        Int(value)
    }

    private var symbolColour: Color {
        pulseKind == nil ? colour : Color.black.opacity(0.82)
    }

    private var textColour: Color {
        pulseKind == nil ? .primary : Color.black.opacity(0.82)
    }

    private var subtitleColour: Color {
        pulseKind == nil ? .secondary : Color.black.opacity(0.72)
    }

    private var pulseColour: Color {
        switch pulseKind {
        case .increase: return .green
        case .decrease: return .secondary
        case nil: return .clear
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(symbolColour)
            Text(value)
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(textColour)
                .contentTransition(showsMotion ? .numericText() : .identity)
                .overlay {
                    ForEach(particles) { particle in
                        Text(particle.text)
                            .font(.caption.weight(.bold))
                            .scaleEffect(particlesExpanded ? 0.85 : 0.35)
                            .opacity(particlesExpanded ? 0 : 1)
                            .offset(
                                x: particlesExpanded ? particle.x : 0,
                                y: particlesExpanded ? particle.y : 0
                            )
                            .animation(.easeOut(duration: 0.9).delay(particle.delay), value: particlesExpanded)
                    }
                }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(subtitleColour)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.thinMaterial)
                .overlay { Capsule().fill(colour.opacity(0.10)) }
                .overlay {
                    Capsule()
                        .fill(pulseColour.opacity(pulseKind == nil ? 0 : 0.92))
                        .allowsHitTesting(false)
                }
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    pulseKind == nil ? Color.white.opacity(0.08) : pulseColour.opacity(0.75),
                    lineWidth: pulseKind == nil ? 1 : 1.5
                )
                .allowsHitTesting(false)
        }
        .offset(x: shakeOffset)
        .animation(showsMotion ? .snappy(duration: 0.25) : nil, value: value)
        .onAppear {
            previousNumericValue = numericValue
        }
        .onChange(of: value) {
            if installationPulse == nil { animateValueChange() }
        }
        .onChange(of: installationPulse) {
            if showsMotion { launchParticles(text: "🙂", kind: .increase) }
        }
    }

    private func animateValueChange() {
        guard let newValue = numericValue else {
            previousNumericValue = nil
            return
        }
        defer { previousNumericValue = newValue }
        guard showsMotion, let oldValue = previousNumericValue, oldValue != newValue else { return }

        if newValue > oldValue {
            launchParticles(text: "🙂", kind: .increase)
        } else {
            launchParticles(text: "☹︎", kind: .decrease)
            shake()
        }
    }

    private func launchParticles(text: String, kind: PulseKind) {
        let offsets: [(CGFloat, CGFloat, Double)] = [
            (-34, -18, 0.00),
            (-14, -30, 0.04),
            (12, -34, 0.02),
            (32, -18, 0.06),
            (18, 20, 0.10),
        ]
        particles = offsets.map { Particle(text: text, x: $0.0, y: $0.1, delay: $0.2) }
        particlesExpanded = false
        pulseKind = kind

        let burstID = particles.first?.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard particles.first?.id == burstID else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                particlesExpanded = true
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard particles.first?.id == burstID else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                pulseKind = nil
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard particles.first?.id == burstID else { return }
            particles.removeAll()
        }
    }

    private func shake() {
        shakeOffset = -4
        withAnimation(.bouncy(duration: 0.42, extraBounce: 0.18)) {
            shakeOffset = 0
        }
    }
}

private struct PackageRowProgressBackground: View {
    let progress: Double
    let isIndeterminate: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(LooperStyle.accent.opacity(0.045))

                if isIndeterminate {
                    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let phase = time.truncatingRemainder(dividingBy: 3.2) / 3.2
                        let bounce = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                        let pulse = (sin(time * Double.pi * 1.1) + 1) / 2
                        let sweepWidth = max(180, proxy.size.width * 0.34)

                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(LooperStyle.accent.opacity(0.050 + (0.018 * pulse)))

                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            LooperStyle.accent.opacity(0.00),
                                            LooperStyle.accent.opacity(0.20),
                                            LooperStyle.accent.opacity(0.00),
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: sweepWidth)
                                .offset(x: CGFloat(bounce) * (proxy.size.width - sweepWidth))
                        }
                    }
                } else {
                    Rectangle()
                        .fill(LooperStyle.accent.opacity(0.18))
                        .frame(width: proxy.size.width * min(1, max(0, progress)))
                        .animation(.snappy(duration: 0.22), value: progress)
                }
            }
            .clipped()
        }
    }
}

private enum LooperStyle {
    static let appIcon: NSImage = Bundle.main.url(forResource: "Looper", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    static let accent = Color(red: 0.54, green: 0.24, blue: 0.96)
    static let magenta = Color(red: 0.84, green: 0.20, blue: 0.78)
    static let orange = Color(red: 1, green: 0.49, blue: 0.18)
    static let waveformGradient = LinearGradient(colors: [accent, magenta, orange], startPoint: .leading, endPoint: .trailing)
    static let separator = Color.primary.opacity(0.085)

    static func settingsTint(_ opacity: Double) -> LinearGradient {
        LinearGradient(colors: [accent.opacity(opacity * 0.55), magenta.opacity(opacity * 0.24), orange.opacity(opacity * 0.17)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var windowBackground: some View {
        LooperVisualEffect(material: .sidebar, blendingMode: .behindWindow)
            .overlay(waveformGradient.opacity(0.065))
    }

    static var contentBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var glassBar: some View {
        ZStack {
            LooperVisualEffect(material: .headerView, blendingMode: .withinWindow)
            LinearGradient(
                colors: [Color.white.opacity(0.036), accent.opacity(0.018)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var logStickyDateBackground: some View {
        ZStack {
            LooperVisualEffect(material: .headerView, blendingMode: .withinWindow)
            LinearGradient(
                colors: [
                    accent.opacity(0.046),
                    magenta.opacity(0.042),
                    Color.white.opacity(0.024),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            Rectangle()
                .fill(accent.opacity(0.010))
        }
    }

    static var libraryHeaderBackground: some View {
        ZStack {
            LooperVisualEffect(material: .headerView, blendingMode: .withinWindow)
            LinearGradient(
                colors: [
                    accent.opacity(0.038),
                    orange.opacity(0.024),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var listHeaderBackground: some View {
        ZStack {
            LooperVisualEffect(material: .headerView, blendingMode: .withinWindow)
            LinearGradient(
                colors: [Color.white.opacity(0.028), accent.opacity(0.014)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var appSectionHeaderBackground: some View {
        ZStack {
            LooperVisualEffect(material: .headerView, blendingMode: .withinWindow)
            LinearGradient(
                colors: [
                    accent.opacity(0.032),
                    Color.primary.opacity(0.018),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var subsectionHeaderBackground: some View {
        ZStack {
            LooperVisualEffect(material: .headerView, blendingMode: .withinWindow)
            LinearGradient(
                colors: [
                    accent.opacity(0.026),
                    orange.opacity(0.018),
                    Color.primary.opacity(0.012),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct LogHeaderPosition: Equatable {
    var title: String
    var minY: CGFloat
}

private struct LogHeaderPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [LogHeaderPosition] = []

    static func reduce(value: inout [LogHeaderPosition], nextValue: () -> [LogHeaderPosition]) {
        value.append(contentsOf: nextValue())
    }
}

private struct LogBottomPositionPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LooperVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

private struct LooperGlassButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 8 : 10)
            .background {
                RoundedRectangle(cornerRadius: compact ? 13 : 16, style: .continuous)
                    .fill(LooperStyle.settingsTint(configuration.isPressed ? 0.24 : 0.14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 13 : 16, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.28 : 0.14))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.10), radius: compact ? 8 : 10, y: compact ? 4 : 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct ScopeStorageEstimate: View {
    let packages: [LoopPackage]?
    @State private var estimate: DiskSpacePreflight?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Storage for this scope", systemImage: "internaldrive").font(.headline)
            if let packages, let estimate {
                if packages.isEmpty {
                    Text("No additional space required.")
                } else {
                    let needed = estimate.requiredBytes.map(DiskSpaceChecker.formatBytes) ?? "Unknown"
                    let available = estimate.availableBytes.map(DiskSpaceChecker.formatBytes) ?? "Unknown"
                    Text("\(packages.count) pending · \(needed) estimated · \(available) available")
                    if estimate.shouldStop {
                        Text(estimate.detail).foregroundStyle(.red)
                    } else if estimate.level == .warning {
                        Text(estimate.message).foregroundStyle(.orange)
                    }
                    let unknown = packages.filter { ($0.downloadSize ?? 0) <= 0 || ($0.installedSize ?? 0) <= 0 }.count
                    Text(unknown > 0 ? "Size information is incomplete for \(unknown) of these packages." : "Includes uncached downloads, installation space and a 2 GiB reserve.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(packages == nil ? "Waiting for catalogue sizes." : "Calculating storage…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: packages) {
            estimate = nil
            guard let packages else { return }
            let result = await Task.detached(priority: .utility) {
                DiskSpaceChecker.preflightRun(paths: LooperPaths(), packages: packages)
            }.value
            if !Task.isCancelled { estimate = result }
        }
    }
}

private struct LooperGlassSegmentedControl<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(Selection, String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.0 == selection

                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? LooperStyle.accent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.thinMaterial.opacity(0.20)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? LooperStyle.accent.opacity(0.68) : LooperStyle.separator,
                                              lineWidth: isSelected ? 1.5 : 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
                .allowsHitTesting(false)
        }
    }
}

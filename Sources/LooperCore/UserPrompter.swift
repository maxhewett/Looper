import Foundation
import UserNotifications

/// User-facing prompts after content changes.
///
/// This is deliberately best-effort. The unattended installer should still
/// succeed even when notifications are denied or there is no active GUI user.
public struct UserPrompter: Sendable {
    public init() {}

    /// GarageBand and Logic often need a relaunch before newly installed loops
    /// appear in their browsers.
    @discardableResult
    public func notifyInstalledPackages(_ packages: [LoopPackage]) async -> Bool {
        guard !packages.isEmpty else { return false }

        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Apple Loops installed"
        content.body = "Relaunch GarageBand or Logic Pro to refresh newly installed loop content."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "looper.install-complete.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    /// Tell the current user that the catalogue contains content that is not
    /// installed yet. MDM deployments can pair this with an automatic schedule
    /// or leave it as an informational prompt.
    @discardableResult
    public func notifyNewLoopsAvailable(count: Int) async -> Bool {
        guard count > 0 else { return false }
        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "New Apple Loops available"
        content.body = "\(count) loop package\(count == 1 ? "" : "s") can be installed by Looper."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "looper.available",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    /// Prompt for relaunch when content changes while a supported Apple app is
    /// open. The caller supplies the app names after checking running processes.
    @discardableResult
    public func notifyRelaunchRecommended(appNames: [String]) async -> Bool {
        let names = appNames.filter { !$0.isEmpty }
        guard !names.isEmpty else { return false }
        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Relaunch recommended"
        content.body = "\(names.joined(separator: ", ")) should be relaunched to see newly installed loops."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "looper.relaunch.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    @discardableResult
    public func notifyRunFailed(message: String) async -> Bool {
        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Looper run failed"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "looper.failed.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    @discardableResult
    public func notifyStorageWarning(message: String) async -> Bool {
        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Looper storage warning"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "looper.storage.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    @discardableResult
    public func notifyRunSummary(message: String) async -> Bool {
        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Looper run finished"
        content.body = message

        let request = UNNotificationRequest(
            identifier: "looper.summary.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    @discardableResult
    public func notifyTest() async -> Bool {
        guard await ensureAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Looper notifications are working"
        content.body = "Notification delivery is available for this signed-in user."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "looper.test.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        return await deliver(request)
    }

    private func deliver(_ request: UNNotificationRequest) async -> Bool {
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    private func ensureAuthorised() async -> Bool {
        guard Self.currentProcessCanDeliverNotifications else {
            return false
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            return true
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// `UNUserNotificationCenter` expects a normal app bundle. The privileged
    /// helper and command-line tool run from `Contents/Helpers`, so they record
    /// results and let the app deliver user-facing notifications.
    private static var currentProcessCanDeliverNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

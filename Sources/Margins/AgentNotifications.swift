import AppKit
import Foundation
import MarginsCore
import UserNotifications

/// Native macOS notification delivery via `UNUserNotificationCenter`, guarded for bundled `.app` runs.
@MainActor
final class AgentNotifications: NSObject {
    static let shared = AgentNotifications()

    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private let delivery: UserNotificationDelivery
    let coordinator: AgentNotificationCoordinator

    init(defaults: UserDefaults = .standard) {
        let delivery = UserNotificationDelivery()
        self.delivery = delivery
        self.coordinator = AgentNotificationCoordinator(delivery: delivery, defaults: defaults)
        super.init()
    }

    func installDelegate() {
        guard Self.isBundledApp else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded(force: Bool = false) {
        coordinator.requestAuthorizationIfNeeded(force: force)
    }

    func clearNotifications(forDocumentURL url: URL) {
        coordinator.clearNotifications(forDocumentURL: url)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard Self.isBundledApp else { return .notDetermined }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension AgentNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let playSound = (notification.request.content.userInfo["playSound"] as? Bool) ?? true
        completionHandler(playSound ? [.banner, .sound] : [.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let urlString = userInfo["documentURL"] as? String
        let threadID = (userInfo["threadID"] as? String).flatMap(UUID.init(uuidString:))
        let intentID = (userInfo["intentID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let urlString, let url = URL(string: urlString) {
                DocumentWindows.shared.focus(url, threadID: threadID, intentID: intentID)
            }
            completionHandler()
        }
    }
}

private final class UserNotificationDelivery: AgentNotificationDelivery {
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ payload: AgentNotificationPayload) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        if payload.playSound { content.sound = .default }
        var userInfo: [AnyHashable: Any] = [
            "documentURL": payload.documentURL.absoluteString,
            "playSound": payload.playSound,
        ]
        if let threadID = payload.threadID { userInfo["threadID"] = threadID.uuidString }
        if let intentID = payload.intentID { userInfo["intentID"] = intentID.uuidString }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func removeDelivered(forDocumentURL url: URL) {
        guard isAvailable else { return }
        let target = url.standardizedFileURL.absoluteString
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications.compactMap { item -> String? in
                guard (item.request.content.userInfo["documentURL"] as? String) == target else { return nil }
                return item.request.identifier
            }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

extension AppState {
    var isDocumentWindowFocused: Bool {
        NSApp.isActive && DocumentWindows.shared.keyState === self
    }

    func prepareAgentNotifications() {
        AgentNotifications.shared.requestAuthorizationIfNeeded()
    }

    func notifyAgentRunFinished(step: Int, run: AnnotationRun?, failed: Bool, cancelled: Bool) {
        let intent = doc.intents.first { $0.kind == .instruction && $0.step == step }
        let wasCancelled = cancelled || intent?.error == "Stopped." || (run?.notes.contains("Stopped.") ?? false)
        let outcome: AgentNotificationOutcome
        if failed {
            let errorMessage = intent?.error ?? run?.notes.last ?? "The agent run failed."
            outcome = .failed(error: errorMessage)
        } else {
            let hasEdits = intent?.status == .pending || run?.status == "pending"
            let summary = !(run?.summary.isEmpty ?? true) ? (run?.summary ?? "") : (intent?.summary ?? "")
            let slug = doc.versions.last?.slug ?? ""
            let reply = intent?.reply ?? ""
            outcome = .completed(hasEdits: hasEdits, summary: summary, slug: slug, reply: reply)
        }
        AgentNotifications.shared.coordinator.notify(
            documentURL: fileURL,
            step: step,
            intentID: intent?.id,
            threadID: intent?.thread,
            outcome: outcome,
            wasCancelled: wasCancelled,
            isDocumentFocused: isDocumentWindowFocused
        )
    }

    func notifyAgentPermissionNeeded(step: Int, request: PermissionRequest) {
        let intent = doc.intents.first { $0.kind == .instruction && $0.step == step }
        AgentNotifications.shared.coordinator.notify(
            documentURL: fileURL,
            step: step,
            intentID: intent?.id,
            threadID: intent?.thread,
            outcome: .permissionNeeded(title: request.title, detail: request.detail),
            wasCancelled: false,
            isDocumentFocused: isDocumentWindowFocused
        )
    }
}

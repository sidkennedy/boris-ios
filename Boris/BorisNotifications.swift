import Foundation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class BorisNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = BorisNotifications()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "boris.notifications")
    @Published private(set) var status = "Notifications are off."
    @Published var sessionURL: URL?
    private var task: Task<Void, Never>?
    private var server = ""
    private var accessKey = ""
    private var deviceToken: String?
    private var registeredToken: String?
    private var registeredServer: String?
    private var registeredKey: String?
    private var remoteRegistered = false

    private struct State: Decodable {
        let event_cursor: Int
        let sessions: [Session]
    }
    private struct Session: Decodable { let status: String }
    private struct PushStatus: Decodable { let remote_push_ready: Bool }
    private struct Event: Decodable {
        let seq: Int
        let kind: String
        let body: Body
        struct Body: Decodable {
            let session_id: String?
            let name: String?
            let status: String?
        }
    }

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func configure(server: String, accessKey: String) async {
        let base = server.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base != self.server || accessKey != self.accessKey || task == nil else { return }
        task?.cancel()
        task = nil
        if registeredServer != nil { await unregister() }
        self.server = base
        self.accessKey = accessKey
        guard enabled else { return }
        guard !accessKey.isEmpty,
              let url = URL(string: base), url.scheme == "https", url.host != nil else {
            status = "Enter your Boris HTTPS address and access key to receive session alerts."
            return
        }
        task = Task { [weak self] in
            await self?.watch(server: base, key: accessKey)
        }
    }

    func enable(server: String, accessKey: String) async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                status = "Allow notifications for Boris in iPhone Settings."
                return
            }
            enabled = true
            UserDefaults.standard.set(true, forKey: "boris.notifications")
            await configure(server: server, accessKey: accessKey)
        } catch { status = error.localizedDescription }
    }

    func disable() async {
        task?.cancel()
        task = nil
        await unregister()
        #if BORIS_REMOTE_PUSH
        UIApplication.shared.unregisterForRemoteNotifications()
        #endif
        enabled = false
        UserDefaults.standard.set(false, forKey: "boris.notifications")
        UserDefaults.standard.removeObject(forKey: "boris.notificationCursor." + server)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        status = "Notifications are off."
    }

    func receivedDeviceToken(_ token: Data) {
        let value = token.map { String(format: "%02x", $0) }.joined()
        if deviceToken != value { remoteRegistered = false }
        deviceToken = value
    }

    func failedRemoteRegistration() {
        status = "Local alerts are on. This build could not register for remote notifications."
    }

    private var pushEnvironment: String {
        #if BORIS_APNS_PRODUCTION
        return "production"
        #else
        return "development"
        #endif
    }

    private func unregister() async {
        if let token = registeredToken, let base = registeredServer, let key = registeredKey {
            _ = try? await request(server: base, key: key, path: "/api/notifications/unregister",
                                   body: ["token": token, "environment": pushEnvironment])
        }
        remoteRegistered = false
        registeredServer = nil
        registeredKey = nil
        registeredToken = nil
    }

    private func request(server: String, key: String, path: String,
                         body: [String: Any]? = nil, retryLogin: Bool = true) async throws -> Data {
        guard let url = URL(string: server + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401, retryLogin, path != "/api/login" {
            _ = try await self.request(server: server, key: key, path: "/api/login",
                                      body: ["token": key], retryLogin: false)
            return try await self.request(server: server, key: key, path: path,
                                          body: body, retryLogin: false)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private func watch(server: String, key: String) async {
        let cursorKey = "boris.notificationCursor." + server
        var cursor = UserDefaults.standard.object(forKey: cursorKey) as? Int
        while !Task.isCancelled {
            do {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard settings.authorizationStatus == .authorized
                        || settings.authorizationStatus == .provisional else {
                    status = "Allow notifications for Boris in iPhone Settings."
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                _ = try await request(server: server, key: key, path: "/api/session-sync", body: [:])
                let stateData = try await request(server: server, key: key, path: "/api/state")
                let state = try JSONDecoder().decode(State.self, from: stateData)
                if cursor == nil {
                    cursor = state.event_cursor // Skip history on first subscription.
                    UserDefaults.standard.set(cursor, forKey: cursorKey)
                }
                try await UNUserNotificationCenter.current().setBadgeCount(
                    state.sessions.filter { $0.status == "AWAITING_INPUT" }.count)
                #if BORIS_REMOTE_PUSH
                let pushData = try? await request(server: server, key: key, path: "/api/notifications")
                let push = pushData.flatMap { try? JSONDecoder().decode(PushStatus.self, from: $0) }
                if push?.remote_push_ready == true {
                    UIApplication.shared.registerForRemoteNotifications()
                    if let token = deviceToken, !remoteRegistered {
                        do {
                            await unregister()
                            _ = try await request(server: server, key: key,
                                                  path: "/api/notifications/register",
                                                  body: ["token": token, "environment": pushEnvironment])
                            try Task.checkCancellation()
                            registeredServer = server
                            registeredKey = key
                            registeredToken = token
                            remoteRegistered = true
                        } catch {
                            try Task.checkCancellation()
                            remoteRegistered = false
                        }
                    }
                } else {
                    remoteRegistered = false
                }
                status = remoteRegistered ? "Remote session notifications are on."
                    : "Local alerts are on. Remote notifications are not configured."
                #else
                status = "Local alerts are on while Boris is active or a voice call is running."
                #endif
                // Poll the event queue, independently of the voice room and its acknowledgments.
                // A suspended app relies on APNs rather than background polling.
                for _ in 0..<3 {
                    try Task.checkCancellation()
                    let data = try await request(server: server, key: key,
                                                 path: "/api/event-page?after=\(cursor ?? 0)")
                    let events = try JSONDecoder().decode([Event].self, from: data)
                    for event in events {
                        try Task.checkCancellation()
                        if !remoteRegistered { try await notify(event, server: server) }
                        cursor = event.seq
                        UserDefaults.standard.set(event.seq, forKey: cursorKey)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = "Waiting to reconnect for session alerts."
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func notify(_ event: Event, server: String) async throws {
        guard event.kind == "attention", let id = event.body.session_id,
              let state = event.body.status else { return }
        let messages = [
            "AWAITING_INPUT": "The agent's turn ended or it needs your input. Tap to open the session.",
            "COMPLETED": "The task is complete. Tap to view the result.",
            "FAILED": "The task failed. Tap to review the session.",
            "PAUSED": "The task is paused. Tap to review the session.",
            "KILLED": "The task stopped. Tap to review the session.",
            "DISCONNECTED": "The session disconnected. Tap to review its status."
        ]
        guard let message = messages[state] else { return }
        let content = UNMutableNotificationContent()
        content.title = event.body.name ?? "Boris session"
        content.body = message
        content.sound = .default
        content.userInfo = ["session_id": id, "server": server, "event_seq": event.seq]
        let notification = UNNotificationRequest(identifier: "boris-\(server)-\(event.seq)",
                                                 content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(notification)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session_id"] as? String
        let source = response.notification.request.content.userInfo["server"] as? String
        Task { @MainActor [weak self] in
            guard let self, let id, UUID(uuidString: id) != nil else { return }
            let base = source ?? UserDefaults.standard.string(forKey: "boris.server") ?? ""
            guard let url = URL(string: base), url.scheme == "https", url.host != nil else { return }
            self.sessionURL = url.appendingPathComponent("dashboard/sessions/\(id)")
        }
        completionHandler()
    }
}

final class BorisAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in BorisNotifications.shared.receivedDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in BorisNotifications.shared.failedRemoteRegistration() }
    }
}

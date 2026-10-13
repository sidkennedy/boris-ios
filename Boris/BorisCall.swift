import Foundation
import AVFoundation
import Security
import SwiftUI
import OSLog
import UIKit
import UserNotifications
@preconcurrency import LiveKit

@MainActor
final class BorisCall: NSObject, ObservableObject, RoomDelegate {
    @Published var connected = false
    @Published var busy = false
    @Published var connectionStatus = "Connecting…"
    @Published var muted = false
    @Published var error: String?
    @Published var server = UserDefaults.standard.string(forKey: "boris.server") ?? ""
    @Published var accessKey = Keychain.read() ?? ""
    private var ending = false
    private var room: Room?
    private var roomName: String?
    private var callServer: String?
    private var expiryTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.sidney.boris", category: "voice-startup")

    override init() {
        super.init()
        // Own the session across capture/playout and mute changes. LiveKit's
        // automatic in-call category excludes mixWithOthers.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        AudioManager.shared.isAdvancedDuckingEnabled = false
        AudioManager.shared.duckingLevel = .min
    }

    private func activateAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try audio.setActive(true)
    }

    struct VoiceJoin: Decodable {
        let url: String
        let token: String
        let room: String
        let expires_at: Double
    }

    func request(_ path: String, body: [String: Any], server override: String? = nil) async throws -> Data {
        let base = (override ?? server).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path), url.scheme == "https", url.host != nil else {
            throw NSError(domain: "Boris", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter Boris's HTTPS address."])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = path == "/api/voice/start" ? 30 : 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            log.info("voice_http path=\(path, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NSError(domain: "Boris", code: 2, userInfo: [NSLocalizedDescriptionKey: detail?["detail"] as? String ?? "Boris could not complete the request."])
        }
        return data
    }

    func toggleMicrophone() async {
        guard !busy else { return }
        if connected, let room {
            do {
                try await room.localParticipant.setMicrophone(enabled: muted)
                muted.toggle()
            } catch { self.error = error.localizedDescription }
            return
        }
        busy = true
        connectionStatus = "Checking microphone…"
        error = nil
        let started = ProcessInfo.processInfo.systemUptime
        defer { busy = false }
        do {
            let permitted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard permitted else {
                throw NSError(domain: "Boris", code: 3, userInfo: [NSLocalizedDescriptionKey: "Enable microphone access for Boris in Settings."])
            }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
            connectionStatus = "Signing in…"
            _ = try await request("/api/login", body: ["token": accessKey])
            UserDefaults.standard.set(server, forKey: "boris.server")
            Keychain.save(accessKey)
            connectionStatus = "Starting call…"
            let data = try await request("/api/voice/start", body: [:])
            let join = try JSONDecoder().decode(VoiceJoin.self, from: data)
            roomName = join.room
            callServer = server
            try activateAudioSession()
            let newRoom = Room(delegate: self)
            room = newRoom
            connectionStatus = "Connecting audio…"
            let rtcStarted = ProcessInfo.processInfo.systemUptime
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try await newRoom.connect(url: join.url, token: join.token,
                                              connectOptions: ConnectOptions(enableMicrophone: true))
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                    throw URLError(.timedOut)
                }
                _ = try await group.next()
            }
            let rtcMs = Int((ProcessInfo.processInfo.systemUptime - rtcStarted) * 1000)
            let totalMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            log.info("voice_connected audio_ms=\(rtcMs, privacy: .public) total_ms=\(totalMs, privacy: .public)")
            connected = true
            muted = false
            expiryTask = Task { [weak self] in
                let delay = max(0, join.expires_at - Date().timeIntervalSince1970)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.end()
            }
        } catch {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            log.info("voice_failed stage=\(self.connectionStatus, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)")
            self.error = (error as? URLError)?.code == .timedOut
                ? "\(connectionStatus) took too long. Check your connection and try again."
                : error.localizedDescription
            await end()
        }
    }

    func end() async {
        guard !ending else { return }
        ending = true
        defer { ending = false }
        expiryTask?.cancel()
        expiryTask = nil
        let endingRoom = roomName
        let endingServer = callServer
        roomName = nil
        callServer = nil
        await room?.disconnect()
        room = nil
        connected = false
        muted = false
        if let endingRoom {
            _ = try? await request("/api/voice/end", body: ["room": endingRoom], server: endingServer)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func notifyCallDrop(_ body: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let content = UNMutableNotificationContent()
        content.title = "Boris call dropped"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "boris-voice-drop",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func recoverAfterDisconnect(_ detail: String) async {
        let droppedRoom = roomName
        let droppedServer = callServer
        notifyCallDrop("I'm reconnecting now. Tap Boris if the call does not return.")
        await end()

        for attempt in 1...3 {
            connectionStatus = "Reconnecting…"
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
            do {
                _ = try await request("/api/login", body: ["token": accessKey], server: droppedServer)
                if let droppedRoom {
                    _ = try? await request(
                        "/api/voice/report",
                        body: ["room": droppedRoom, "reason": detail],
                        server: droppedServer
                    )
                    _ = try? await request(
                        "/api/voice/end",
                        body: ["room": droppedRoom],
                        server: droppedServer
                    )
                }
                await toggleMicrophone()
                if connected {
                    error = nil
                    connectionStatus = "Connected"
                    return
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        error = "Boris couldn't reconnect. Tap the microphone to try again."
        notifyCallDrop("Automatic reconnection failed. Tap Boris to try again.")
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, !self.ending else { return }
            let detail = error?.localizedDescription ?? "Unexpected disconnect"
            self.error = detail
            let task = UIApplication.shared.beginBackgroundTask(withName: "Boris voice recovery")
            await self.recoverAfterDisconnect(detail)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}

enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "com.sidney.boris", kSecAttrAccount as String: "access"]
    static func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
    static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

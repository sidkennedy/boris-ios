import Foundation
import AVFoundation
import Security
import SwiftUI
@preconcurrency import LiveKit

@MainActor
final class BorisCall: NSObject, ObservableObject, RoomDelegate {
    @Published var connected = false
    @Published var busy = false
    @Published var muted = false
    @Published var error: String?
    @Published var server = UserDefaults.standard.string(forKey: "boris.server") ?? ""
    @Published var accessKey = Keychain.read() ?? ""
    private var ending = false
    private var room: Room?
    private var roomName: String?
    private var callServer: String?
    private var expiryTask: Task<Void, Never>?

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
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        error = nil
        defer { busy = false }
        do {
            let permitted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard permitted else {
                throw NSError(domain: "Boris", code: 3, userInfo: [NSLocalizedDescriptionKey: "Enable microphone access for Boris in Settings."])
            }
            _ = try await request("/api/login", body: ["token": accessKey])
            UserDefaults.standard.set(server, forKey: "boris.server")
            Keychain.save(accessKey)
            let data = try await request("/api/voice/start", body: [:])
            let join = try JSONDecoder().decode(VoiceJoin.self, from: data)
            roomName = join.room
            callServer = server
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
            let newRoom = Room(delegate: self)
            room = newRoom
            try await newRoom.connect(url: join.url, token: join.token)
            try await newRoom.localParticipant.setMicrophone(enabled: true)
            connected = true
            muted = false
            expiryTask = Task { [weak self] in
                let delay = max(0, join.expires_at - Date().timeIntervalSince1970)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.end()
            }
        } catch {
            self.error = error.localizedDescription
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

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            if let error { self?.error = error.localizedDescription }
            await self?.end()
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

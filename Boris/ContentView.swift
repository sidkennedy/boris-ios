import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var call: BorisCall
    @State private var showSettings = false
    private let mint = Color(red: 0.706, green: 0.922, blue: 0.682)
    var body: some View {
        VStack(spacing: 26) {
            HStack {
                Text("boris.").font(.system(size: 34, weight: .bold, design: .rounded))
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                    .accessibilityLabel("Connection settings")
            }
            Spacer()
            Text(call.connected ? (call.muted ? "Still here. Mic is off." : "I'm listening.") : "What's on your mind?")
                .font(.system(size: 26, weight: .medium, design: .rounded))
            Button { Task { await call.toggleMicrophone() } } label: {
                Image(systemName: call.muted ? "mic.slash" : "mic")
                    .font(.system(size: 36, weight: .regular))
                    .frame(width: 142, height: 142)
                    .foregroundStyle(Color(red: 0.08, green: 0.16, blue: 0.1))
                    .background(call.muted ? Color.gray : mint, in: Circle())
            }
            .disabled(call.busy)
            .accessibilityLabel(call.connected ? (call.muted ? "Unmute microphone" : "Mute microphone") : "Start talking to Boris")
            Text(call.busy ? "Connecting…" : call.connected ? "You can use other apps while we talk." : "Tap to talk. Boris will keep you posted.")
                .font(.subheadline).foregroundStyle(.secondary)
            if call.connected {
                Button("End call") { Task { await call.end() } }.buttonStyle(.bordered)
            }
            if let error = call.error { Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Spacer()
            if let url = URL(string: call.server), url.scheme == "https" {
                Link("Open sessions ↗", destination: url.appendingPathComponent("dashboard"))
                    .foregroundStyle(mint)
            }
            Text("A clear head. A few good agents.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).background(Color(red: 0.051, green: 0.071, blue: 0.075))
        .onAppear { if call.server.isEmpty || call.accessKey.isEmpty { showSettings = true } }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("Your private Boris server") {
                        TextField("HTTPS address", text: $call.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Boris access key", text: $call.accessKey).textInputAutocapitalization(.never)
                        Text("Use the address and access key from your local Boris setup. Provider API keys stay on the Mac.").font(.caption)
                    }
                }.navigationTitle("Connect to Boris").toolbar { Button("Done") { showSettings = false } }
            }
        }
    }
}

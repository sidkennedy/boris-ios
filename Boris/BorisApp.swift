import SwiftUI

@main
struct BorisApp: App {
    @UIApplicationDelegateAdaptor(BorisAppDelegate.self) private var appDelegate
    @StateObject private var call = BorisCall()
    @StateObject private var notifications = BorisNotifications.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(call).environmentObject(notifications)
                .preferredColorScheme(.dark)
                .task { await notifications.configure(server: call.server, accessKey: call.accessKey) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await notifications.configure(server: call.server, accessKey: call.accessKey) }
                    }
                }
        }
    }
}

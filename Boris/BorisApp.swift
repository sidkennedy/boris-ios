import SwiftUI

@main
struct BorisApp: App {
    @StateObject private var call = BorisCall()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(call).preferredColorScheme(.dark) }
    }
}

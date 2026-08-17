import SwiftUI

@main
struct MirrorFocusApp: App {
    @StateObject private var adConsent = AdConsentManager()

    var body: some Scene {
        WindowGroup {
            MirrorView()
                .preferredColorScheme(.dark)
                .environmentObject(adConsent)
                .task {
                    adConsent.requestConsentIfNeeded()
                }
        }
    }
}

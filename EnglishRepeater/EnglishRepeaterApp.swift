import SwiftUI

@main
struct EnglishRepeaterApp: App {
    @StateObject private var playerVM = PlayerViewModel()
    /// 0 = Library, 1 = Player pushed. Library is the root; tapping a track pushes Player.
    @State private var page = 0
    /// First-launch walkthrough gate. Versioned so a refreshed intro can re-show later.
    @AppStorage("hasSeenOnboarding_v1") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            LibraryView(page: $page)
                .environmentObject(playerVM)
                .tint(Theme.accent)
                .onOpenURL { url in
                    playerVM.addToLibrary(url: url)
                    page = 0
                }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasSeenOnboarding },
                    set: { if !$0 { hasSeenOnboarding = true } }
                )) {
                    OnboardingView(onDone: { hasSeenOnboarding = true })
                }
        }
    }
}

import SwiftUI

@main
struct EnglishRepeaterApp: App {
    @StateObject private var playerVM = PlayerViewModel()
    /// 0 = Library, 1 = Player pushed. Library is the root; tapping a track pushes Player.
    @State private var page = 0

    var body: some Scene {
        WindowGroup {
            LibraryView(page: $page)
                .environmentObject(playerVM)
                .tint(Theme.accent)
                .onOpenURL { url in
                    playerVM.addToLibrary(url: url)
                    page = 0
                }
        }
    }
}

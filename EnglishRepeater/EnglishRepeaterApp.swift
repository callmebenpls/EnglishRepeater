import SwiftUI

@main
struct EnglishRepeaterApp: App {
    @StateObject private var playerVM = PlayerViewModel()
    /// 0 = Library (home), 1 = Player. Two horizontally-swipeable pages, no tab bar.
    @State private var page = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $page) {
                LibraryView(page: $page)
                    .environmentObject(playerVM)
                    .tag(0)

                PlayerView()
                    .environmentObject(playerVM)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))   // swipe between the two pages
            .tint(Theme.accent)
            .onOpenURL { url in
                playerVM.addToLibrary(url: url)
                page = 0
            }
        }
    }
}

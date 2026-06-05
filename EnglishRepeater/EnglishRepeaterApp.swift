import SwiftUI

@main
struct EnglishRepeaterApp: App {
    @StateObject private var playerVM = PlayerViewModel()
    @State private var selectedTab = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                LibraryView(selectedTab: $selectedTab)
                    .environmentObject(playerVM)
                    .tabItem {
                        Label("音频库", systemImage: "music.note.list")
                    }
                    .tag(0)

                PlayerView()
                    .environmentObject(playerVM)
                    .tabItem {
                        Label("正在播放", systemImage: "play.circle")
                    }
                    .tag(1)
            }
            .onOpenURL { url in
                playerVM.addToLibrary(url: url)
                selectedTab = 0
            }
        }
    }
}

import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            PracticeView(mode: .translation)
                .tabItem { Label("Translate", systemImage: "mic.fill") }
                .tag(1)

            PracticeView(mode: .listening)
                .tabItem { Label("Listen", systemImage: "ear.fill") }
                .tag(2)

            ProduceView()
                .tabItem { Label("Produce", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(3)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .environmentObject(store)
        // Activate the correct mode whenever the user switches to a practice tab.
        // Using onChange rather than PracticeView.onAppear avoids the TabView quirk
        // where both tabs' onAppear fire simultaneously on first render.
        .onChange(of: selectedTab) { tab in
            switch tab {
            case 1: store.activateMode(.translation)
            case 2: store.activateMode(.listening)
            case 3: store.activateProduceMode()
            default: break
            }
        }
        .task {
            await store.speech.requestAuthorization()
            await store.prepareOrResumeTodaySession()
        }
    }
}

#Preview {
    ContentView()
}

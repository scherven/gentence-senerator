import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            PracticeView()
                .tabItem { Label("Practice", systemImage: "mic.fill") }
                .tag(1)

            StatsView()
                .tabItem { Label("Progress", systemImage: "chart.bar.fill") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .environmentObject(store)
        .task {
            await store.speech.requestAuthorization()
            await store.prepareOrResumeTodaySession()
        }
    }
}

#Preview {
    ContentView()
}

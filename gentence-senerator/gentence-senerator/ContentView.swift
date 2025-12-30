import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var selectedLanguage = "Mandarin"
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(selectedLanguage: $selectedLanguage)
                .tabItem {
                    Label("Dashboard", systemImage: "house.fill")
                }
                .tag(0)
            
            SettingsView(selectedLanguage: $selectedLanguage)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(1)
        }
    }
}

#Preview {
    ContentView()
}

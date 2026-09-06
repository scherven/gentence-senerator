import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var selectedTab = 0

    var body: some View {
        // The over-budget warning sits above the TabView rather than inside any one screen, so
        // it is visible wherever the user happens to be when the day crosses the cap.
        VStack(spacing: 0) {
            if store.isOverDailyCostCap && !store.costWarningDismissed {
                DailyCostBanner()
                    .environmentObject(store)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            tabs
        }
        .animation(.easeInOut(duration: 0.2), value: store.isOverDailyCostCap)
        .animation(.easeInOut(duration: 0.2), value: store.costWarningDismissed)
    }

    private var tabs: some View {
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

// MARK: - Daily Cost Banner

/// Shown app-wide once the day's API spend passes the cap. It warns rather than blocks —
/// stopping a session mid-sentence would lose the user's work to save a few cents.
private struct DailyCostBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
                .font(.subheadline)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(formattedCost(store.costLedger.todayCost)) of API usage today")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text("Past your \(formattedCost(dailyCostWarningThreshold)) daily limit. Practising still works — this is just a heads-up.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                store.costWarningDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss cost warning")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange)
    }
}

#Preview {
    ContentView()
}

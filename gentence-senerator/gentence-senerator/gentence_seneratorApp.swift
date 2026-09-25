import SwiftUI

@main
struct GentenceApp: App {
    @UIApplicationDelegateAdaptor(Push.self) private var push
    @Environment(\.scenePhase) private var scenePhase
    /// One store for the process, made on first use — which may be iOS
    /// launching the app in the background to hand it an upload's result,
    /// before any scene exists.
    @MainActor static let store = Store(
        tutor: Tutor(api: Anthropic(key: Key.anthropicKey)),
        speech: Voice()
    )
    @State private var store = GentenceApp.store

    var body: some Scene {
        WindowGroup {
            AppShell(store: store)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await store.wake() }
            case .background:
                store.sleep()
                // A session finished with no signal is sent the moment the
                // phone is put away, if the network has come back by then.
                guard store.hasUnsent else { break }
                let task = UIApplication.shared.beginBackgroundTask()
                Task {
                    await store.pump()
                    UIApplication.shared.endBackgroundTask(task)
                }
            default: break
            }
        }
    }
}

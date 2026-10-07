import SwiftUI

@main
struct GentenceApp: App {
    @UIApplicationDelegateAdaptor(Push.self) private var push
    @Environment(\.scenePhase) private var scenePhase
    /// One store for the process, made on first use — which may be iOS
    /// launching the app in the background to hand it an upload's result,
    /// before any scene exists.
    @MainActor static let store = Store(
        tutor: Tutor(api: Anthropic()),
        speech: Voice()
    )
    @State private var store = GentenceApp.store
    /// Once per process, so returning to the app never replays it. UI tests
    /// pass `-skipOpening`.
    @State private var opening = !ProcessInfo.processInfo.arguments.contains("-skipOpening")
    /// Nothing reaches the worker without a code, so nothing wakes either.
    @State private var invited = Worker.invite != nil

    init() { Theme.install() }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if invited {
                    AppShell(store: store)
                } else {
                    InviteScreen {
                        invited = true
                        Push.ask()
                        Task { await store.wake() }
                    }
                }
                if opening {
                    Opening { opening = false }
                        .transition(.identity)
                }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                guard invited else { break }
                Task { await store.wake() }
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

import SwiftUI

@main
struct GentenceApp: App {
    @State private var store = Store(
        tutor: Tutor(api: Anthropic(key: Key.anthropicKey)),
        speech: Voice()
    )

    var body: some Scene {
        WindowGroup {
            AppShell(store: store)
        }
    }
}

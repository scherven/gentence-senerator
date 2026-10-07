import SwiftUI

/// First launch only: the code that lets this install use the worker.
struct InviteScreen: View {
    var redeemed: () -> Void

    @State private var code = ""
    @State private var checking = false
    @State private var refused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            Text("INVITE CODE")
                .font(Theme.F.label)
                .foregroundStyle(Theme.C.ink2)
            TextField("XXXX-XXXX", text: $code)
                .font(Theme.F.number)
                .foregroundStyle(Theme.C.ink)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(redeem)
                .padding(Theme.M.pad)
                .background(Theme.C.stock)
                .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
            if refused {
                Text("Not a code.")
                    .font(Theme.F.meta)
                    .foregroundStyle(Theme.C.bad)
            }
            Button(checking ? "Checking…" : "Enter", action: redeem)
                .buttonStyle(KeyStyle(.primary))
                .disabled(checking || code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Theme.M.gap * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .paper()
    }

    private func redeem() {
        guard !checking else { return }
        checking = true
        refused = false
        Task {
            let ok = await Worker.redeem(code)
            checking = false
            if ok { redeemed() } else { refused = true }
        }
    }
}

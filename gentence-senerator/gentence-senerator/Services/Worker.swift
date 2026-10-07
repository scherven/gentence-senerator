import Foundation

/// The grading worker. It holds the Anthropic and Azure keys and forwards;
/// the app holds only an invite code, sent as `x-invite`.
enum Worker {
    static let base = "https://gentence-grader.gentence-senerator.workers.dev"

    private static let inviteKey = "invite.v1"

    static var invite: String? { UserDefaults.standard.string(forKey: inviteKey) }

    static func url(_ path: String) -> URL { URL(string: base + path)! }

    static func authorize(_ request: inout URLRequest) {
        if let invite { request.setValue(invite, forHTTPHeaderField: "x-invite") }
    }

    /// Keeps `code` if the worker accepts it.
    static func redeem(_ code: String) async -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return false }
        var request = URLRequest(url: url("/check"))
        request.setValue(code, forHTTPHeaderField: "x-invite")
        request.timeoutInterval = 20
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        UserDefaults.standard.set(code, forKey: inviteKey)
        return true
    }
}

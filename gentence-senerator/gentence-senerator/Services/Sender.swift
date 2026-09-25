import Foundation

/// Sends a finished session to the push worker as a background upload.
///
/// A session finished underground used to wait for the app to be opened again
/// before it could be sent. A background upload is handed to iOS, which holds
/// it until there is signal and sends it whether or not the app is running,
/// then wakes the app just long enough to record which batch it became. The
/// worker creates the batch and watches it in one step, and the job id makes a
/// resend return the same batch rather than a second one.
final class Sender: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    static let identifier = "com.technaplex.gentence-senerator.grading"

    /// Handed over by the app delegate when iOS launches the app to deliver
    /// this session's events; called once they have all been handled.
    nonisolated(unsafe) static var finishedEvents: (() -> Void)?

    enum Failure: LocalizedError {
        case rejected(Int, String)
        var errorDescription: String? {
            switch self {
            case .rejected(let code, let body): return "Not accepted (\(code)). \(body.prefix(200))"
            }
        }
    }

    /// Where a job ended up: the batch id, or why it did not get one.
    var onResult: (@MainActor (UUID, Result<String, Error>) -> Void)?

    private let lock = NSLock()
    private var received: [Int: Data] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Reattaches to uploads started by an earlier launch, so their results
    /// are delivered here.
    func resume() { _ = session }

    /// Jobs whose upload iOS is still holding.
    func inFlight() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    /// Background sessions only upload from a file, so the body is written
    /// out first. It stays until the upload finishes, one way or the other.
    func send(job: UUID, body: Data, token: String?, label: String) throws {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("grading", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(job.uuidString).json")
        try body.write(to: file, options: .atomic)

        let task = session.uploadTask(with: Self.request(job: job, token: token, label: label),
                                      fromFile: file)
        task.taskDescription = job.uuidString
        task.resume()
    }

    /// The same upload, sent now from the app rather than left to iOS — for
    /// when the learner would rather press a button than wait. The job id
    /// makes it safe alongside the background copy: whichever arrives second
    /// is handed the batch the first one made.
    func sendNow(job: UUID, body: Data, token: String?, label: String) async throws -> String {
        let (data, response) = try await URLSession.shared.upload(
            for: Self.request(job: job, token: token, label: label), from: body)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let batch = object["batch"] as? String else {
            throw Failure.rejected((response as? HTTPURLResponse)?.statusCode ?? 0,
                                   String(decoding: data, as: UTF8.self))
        }
        return batch
    }

    private static func request(job: UUID, token: String?, label: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Key.graderURL + "/submit")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Key.watchSecret, forHTTPHeaderField: "x-watch-secret")
        request.setValue(job.uuidString, forHTTPHeaderField: "x-job-id")
        request.setValue(label, forHTTPHeaderField: "x-label")
        if let token { request.setValue(token, forHTTPHeaderField: "x-token") }
        request.setValue(sandbox ? "1" : "0", forHTTPHeaderField: "x-sandbox")
        request.timeoutInterval = 30
        return request
    }

    /// Builds run from Xcode can only receive through Apple's sandbox.
    static var sandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = received.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        guard let job = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }

        let result: Result<String, Error>
        if let error {
            result = .failure(error)
        } else if let http = task.response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let batch = object["batch"] as? String {
            result = .success(batch)
        } else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            result = .failure(Failure.rejected(code, String(decoding: data, as: UTF8.self)))
        }

        if let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false) {
            try? FileManager.default.removeItem(
                at: folder.appendingPathComponent("grading/\(job.uuidString).json"))
        }
        let deliver = onResult
        Task { @MainActor in deliver?(job, result) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Sender.finishedEvents?()
            Sender.finishedEvents = nil
        }
    }
}

import AVFoundation
import Observation

/// Plays stretches of one dialogue recording and says where it is, so the
/// read-along can light the word being spoken. Separate from `SpeechIO`: that
/// plays a clip and forgets it, this has to be interrupted and polled.
@MainActor @Observable
final class DialoguePlayer {

    /// Playback position while playing, nil otherwise.
    private(set) var now: Double?
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var loaded: URL?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var end: Double = 0
    @ObservationIgnored private var finished: ((Bool) -> Void)?

    /// Plays `range` at `rate`. `done` gets true if it reached the end, false
    /// if something else stopped it.
    func play(_ url: URL, _ range: ClosedRange<Double>, rate: Float = 1,
              done: ((Bool) -> Void)? = nil) {
        stop()
        do {
            if loaded != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.enableRate = true
                player?.prepareToPlay()
                loaded = url
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            done?(false)
            return
        }
        guard let player else { return }
        player.rate = rate
        player.currentTime = range.lowerBound
        end = range.upperBound
        finished = done
        player.play()
        isPlaying = true
        now = range.lowerBound
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() {
        guard isPlaying else { return }
        halt(reachedEnd: false)
    }

    private func tick() {
        guard let player else { return }
        if player.currentTime >= end || !player.isPlaying {
            halt(reachedEnd: true)
        } else {
            now = player.currentTime
        }
    }

    private func halt(reachedEnd: Bool) {
        ticker?.invalidate()
        ticker = nil
        player?.pause()
        isPlaying = false
        now = nil
        let done = finished
        finished = nil
        done?(reachedEnd)
    }
}

import Foundation
import AVFoundation
import Combine

final class MediaPlaybackModel: ObservableObject {
    let player = AVPlayer()

    @Published var isPlaying = false
    @Published var isEditingCurrentTime = false
    @Published var currentTime: Double = .zero
    @Published var duration: Double = .zero
    @Published var volume: Float = 1.0

    private var subscriptions: Set<AnyCancellable> = []
    private var timeObserver: Any?

    deinit {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    init() {
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                switch status {
                case .playing:
                    self?.isPlaying = true
                case .paused:
                    self?.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
            }
            .store(in: &subscriptions)

        let interval = CMTime(seconds: 0.125, preferredTimescale: 240)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if !self.isEditingCurrentTime {
                self.currentTime = time.seconds
            }
        }

        $isEditingCurrentTime
            .dropFirst()
            .filter({ $0 == false })
            .sink(receiveValue: { [weak self] _ in
                guard let self = self else { return }
                let newTime = CMTime(seconds: self.currentTime, preferredTimescale: 1)
                self.player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.player.rate != 0 {
                    self.player.play()
                }
            })
            .store(in: &subscriptions)

        $volume
            .dropFirst()
            .sink(receiveValue: { [weak self] volume in
                self?.player.volume = volume
            })
            .store(in: &subscriptions)

        self.volume = player.volume
    }

    func setCurrentItem(_ item: AVPlayerItem) {
        currentTime = .zero
        duration = 0.0
        player.replaceCurrentItem(with: item)

        item.publisher(for: \.status)
            .filter({ $0 == .readyToPlay })
            .sink(receiveValue: { [weak self] _ in
                Task.init { @MainActor [weak self] in
                    self?.duration = (try? await item.asset.load(.duration).seconds) ?? 0.0
                }
            })
            .store(in: &subscriptions)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playerItemDidPlayToEnd),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: item)
    }

    @objc
    func playerItemDidPlayToEnd() {
        player.seek(to: .zero)
        player.play()
    }
}

import SwiftUI
import AVFoundation

struct TransportControlsView: View {
    @ObservedObject var model: MediaPlaybackModel

    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    @State private var currentTimeString: String = "00:00"
    @State private var durationTimeString: String = "00:00"

    init(_ model: MediaPlaybackModel) {
        self.model = model
    }

    var body: some View {
            VStack {
                HStack(alignment: .center) {
                    Button {
                        model.isPlaying ? model.player.pause() : model.player.play()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28))
                            .tint(Color.primary)
                    }
                    .buttonStyle(.borderless)
                    Text(currentTimeString)
                        .monospacedDigit()
                    Slider(value: $model.currentTime, in: 0...model.duration, onEditingChanged: { isEditing in
                        model.isEditingCurrentTime = isEditing
                    })
                    Text(durationTimeString)
                        .monospacedDigit()
                }
                HStack(alignment: .center) {
                    Image(systemName: "speaker.wave.3.fill")
                    Slider(value: $model.volume, in: 0...1)
                }
                .frame(maxWidth: 270)
            }
            .padding()
            .onChange(of: model.currentTime) { _, newValue in
                currentTimeString = durationFormatter.string(from: model.currentTime) ?? "00:00"
            }
            .onChange(of: model.duration) { _, newValue in
                durationTimeString = durationFormatter.string(from: model.duration) ?? "00:00"
            }
    }
}

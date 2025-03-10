import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var model = MediaPlaybackModel()
    @State private var videoRenderer: VideoRenderer

    init() {
        let url = Bundle.main.url(forResource: "Oakland", withExtension: "mov")!
        self.videoRenderer = VideoRenderer(url: url)
    }

    var body: some View {
        MetalView(delegate: videoRenderer)
            .ignoresSafeArea()
            .onAppear {
                videoRenderer.prepareToPlay { playerItem in
                    model.setCurrentItem(playerItem)
                }
            }
            .onDisappear {
                model.player.pause()
            }
            .overlay(alignment: .init(horizontal: .center, vertical: .bottom)) {
                TransportControlsView(model)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16.0))
                    .padding()
            }
    }
}

#Preview {
    ContentView()
}

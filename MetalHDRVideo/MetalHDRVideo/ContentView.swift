import SwiftUI
import AVKit

struct ContentView: View {
    @State private var videoRenderer: VideoRenderer

    init() {
        let url = Bundle.main.url(forResource: "Oakland", withExtension: "mov")!
        self.videoRenderer = VideoRenderer(url: url)
    }

    var body: some View {
        MetalView(delegate: videoRenderer)
            .onAppear {
                videoRenderer.play()
            }
            .onDisappear {
                videoRenderer.stop()
            }
    }
}

#Preview {
    ContentView()
}

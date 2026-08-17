import AVKit
import SwiftUI

@MainActor
private final class LoopingVideoPlayer: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        looper = AVPlayerLooper(
            player: player,
            templateItem: AVPlayerItem(url: url)
        )
    }
}

struct RecordingPreviewView: View {
    let clip: RecordedClip

    @Environment(\.dismiss) private var dismiss
    @StateObject private var videoPlayer: LoopingVideoPlayer

    init(clip: RecordedClip) {
        self.clip = clip
        _videoPlayer = StateObject(
            wrappedValue: LoopingVideoPlayer(url: clip.url)
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VideoPlayer(player: videoPlayer.player)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
            }
            .navigationTitle("録画を確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { videoPlayer.player.play() }
        .onDisappear { videoPlayer.player.pause() }
    }
}

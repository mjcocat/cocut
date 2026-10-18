import AVKit
import AppKit
import SwiftUI

struct ClipPreviewView: View {
    let clip: Clip
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    private var aspect: CGFloat {
        guard clip.pixelWidth > 0, clip.pixelHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(clip.pixelWidth) / CGFloat(clip.pixelHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title)
                        .font(.headline)
                    Text("\(clip.durationText) · \(clip.resolutionText) · \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 470, idealHeight: 620)
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

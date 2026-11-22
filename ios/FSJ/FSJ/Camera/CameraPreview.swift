import AVFoundation
import SwiftUI
import UIKit

/// Live camera feed.
struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Loads single frames of a clip for the frame viewer. Only the latest
/// request is kept, so fast scrubbing doesn't queue up work.
@Observable
final class FrameLoader {
    private(set) var image: CGImage?

    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var clip: VideoClip?

    func load(_ clip: VideoClip) {
        guard clip != self.clip else { return }
        self.clip = clip
        image = nil
        guard let url = clip.url else {
            generator = nil
            return
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        self.generator = generator
    }

    func show(frame: Int) {
        guard let generator, let clip else { return }
        task?.cancel()
        // Aim for the middle of the frame so rounding never lands on its neighbour.
        let time = CMTime(seconds: (Double(frame) + 0.5) / clip.fps, preferredTimescale: 600_000)
        task = Task { [weak self] in
            guard let result = try? await generator.image(at: time) else { return }
            guard !Task.isCancelled else { return }
            self?.image = result.image
        }
    }
}

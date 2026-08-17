import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.configureConnection()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
        view.configureConnection()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureConnection()
    }

    func configureConnection() {
        guard let connection = previewLayer.connection else { return }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported, connection.isVideoMirrored {
            connection.isVideoMirrored = false
        }
    }
}

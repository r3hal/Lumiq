import AVFoundation
import SwiftUI

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onFocus: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityLabel = "Live camera preview"
        accessibilityHint = "Tap the preview to focus."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        let indicator = UIView(frame: CGRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56))
        indicator.isUserInteractionEnabled = false
        indicator.layer.borderColor = UIColor.white.cgColor
        indicator.layer.borderWidth = 1
        indicator.layer.cornerRadius = 12
        addSubview(indicator)
        UIView.animate(withDuration: 0.6, delay: 0.35, options: []) {
            indicator.alpha = 0
        } completion: { _ in indicator.removeFromSuperview() }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        rotate(view)
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) { rotate(view) }
    private func rotate(_ view: PreviewSurface) {
        if view.previewLayer.connection?.isVideoRotationAngleSupported(90) == true {
            view.previewLayer.connection?.videoRotationAngle = 90
        }
    }
}

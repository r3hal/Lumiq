import AVFoundation
import SwiftUI

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onFocus: ((CGPoint) -> Void)?
    var onSelect: ((UnitPoint2D) -> Void)?
    var onZoom: ((Double) -> Void)?
    var onPinchBegin: ((@escaping (Double)->Void)->Void)?
    var currentZoom: Double = 1
    private var pinchStart: Double = 1
    private var pinching = false
    private var baseReady = false
    private var pendingScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        addGestureRecognizer(tap)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:))))
        isAccessibilityElement = true
        accessibilityLabel = "Live camera preview"
        accessibilityHint = "Tap a subject to select it and focus. Pinch to zoom."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onSelect?(.init(x: point.x / bounds.width, y: point.y / bounds.height))
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
    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinching = true; baseReady = false; pendingScale = gesture.scale
            if let onPinchBegin {
                onPinchBegin { [weak self] actual in
                    guard let self,self.pinching else { return }
                    self.pinchStart = actual; self.baseReady = true
                    if abs(self.pendingScale-1) > 0.001 { self.onZoom?(actual*Double(self.pendingScale)) }
                }
            } else { pinchStart = currentZoom; baseReady = true }
        }
        if gesture.state == .changed {
            pendingScale = gesture.scale
            if baseReady { onZoom?(pinchStart*Double(gesture.scale)) }
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { pinching = false; baseReady = false }
    }

}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void
    let onSelect: (UnitPoint2D) -> Void
    let onZoom: (Double) -> Void
    let zoom: Double
    let onPinchBegin: (@escaping (Double)->Void)->Void
    var mirrored = false

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.onSelect = onSelect
        view.onZoom = onZoom
        view.onPinchBegin = onPinchBegin
        view.currentZoom = zoom
        rotate(view)
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) {
        view.isUserInteractionEnabled = context.environment.isEnabled
        view.currentZoom = zoom
        view.onFocus = onFocus
        view.onSelect = onSelect
        view.onZoom = onZoom
        view.onPinchBegin = onPinchBegin
        rotate(view)
    }
    private func rotate(_ view: PreviewSurface) {
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if view.previewLayer.connection?.isVideoRotationAngleSupported(90) == true {
            view.previewLayer.connection?.videoRotationAngle = 90
        }
    }
}

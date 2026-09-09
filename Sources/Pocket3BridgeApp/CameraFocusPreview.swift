import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import Pocket3Core
import YunDesign

@MainActor struct Preview: View {
    let session: AVCaptureSession
    let frame: FrameInfo?
    @Bindable var focus: CameraFocusModel
    var body: some View {
        FocusPreviewSurface(session: session, frame: frame, focus: focus,
            selectedPoint: focus.pointSessionID == frame?.sessionID ? focus.requestedPoint : nil,
            helpText: focus.helpText)
    }
}

private struct FocusPreviewSurface: NSViewRepresentable {
    let session: AVCaptureSession
    let frame: FrameInfo?
    let focus: CameraFocusModel
    let selectedPoint: CameraFocusPoint?
    let helpText: String
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }
    func updateNSView(_ view: CameraPreviewView, context: Context) {
        view.focusModel = focus
        view.displayedSessionID = frame?.sessionID
        view.displayedDeviceID = frame?.deviceID
        view.selectedPoint = selectedPoint
        view.toolTip = helpText
        view.setAccessibilityHelp(helpText)
        view.updateFocusMarker()
        view.window?.invalidateCursorRects(for: view)
    }
    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) {
        view.focusModel?.cancel(surfaceID: view.focusSurfaceID)
        view.focusModel = nil
    }
}

/// Native preview-layer geometry accounts for aspect fitting, rotation and
/// mirroring. Black bars never become edge focus points through clamping.
@MainActor final class CameraPreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    let focusSurfaceID = UUID()
    weak var focusModel: CameraFocusModel?
    var displayedSessionID: String?
    var displayedDeviceID: String?
    var selectedPoint: CameraFocusPoint?
    private let marker = CAShapeLayer()

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero); wantsLayer = true
        preview.videoGravity = .resizeAspect; layer = preview
        marker.strokeColor = NSColor.white.cgColor
        marker.fillColor = NSColor.clear.cgColor
        marker.lineWidth = 1
        marker.isHidden = true
        preview.addSublayer(marker)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(loc("Live camera preview"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); updateFocusMarker() }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: focusModel?.canFocus == true ? .crosshair : .arrow)
    }
    override func mouseDown(with event: NSEvent) {
        guard let focusModel, let displayedSessionID, let displayedDeviceID else { return }
        let point = convertToLayer(convert(event.locationInWindow, from: nil))
        let picture = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            .intersection(preview.bounds)
        guard point.x.isFinite, point.y.isFinite, !picture.isNull, !picture.isEmpty, picture.contains(point) else { return }
        window?.makeFirstResponder(self)
        let devicePoint = preview.captureDevicePointConverted(fromLayerPoint: point)
        _ = focusModel.request(at: devicePoint, previewSessionID: displayedSessionID, previewDeviceID: displayedDeviceID,
            surfaceID: focusSurfaceID)
    }
    func updateFocusMarker() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let selectedPoint else { marker.isHidden = true; marker.path = nil; return }
        let point = preview.layerPointConverted(fromCaptureDevicePoint: selectedPoint.cgPoint)
        guard point.x.isFinite, point.y.isFinite, preview.bounds.contains(point) else { marker.isHidden = true; return }
        marker.frame = preview.bounds
        marker.path = CGPath(roundedRect: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26),
            cornerWidth: 3, cornerHeight: 3, transform: nil)
        marker.isHidden = false
    }
}

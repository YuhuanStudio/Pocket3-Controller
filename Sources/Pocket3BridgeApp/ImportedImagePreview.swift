import AppKit
import SwiftUI
import YunDesign

enum ImportedImageGeometry {
    static func imageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, containerSize.width.isFinite, containerSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else { return nil }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2,
            width: size.width, height: size.height)
    }
    static func markerPoint(normalized: CGPoint, imageSize: CGSize, containerSize: CGSize) -> CGPoint? {
        guard normalized.x.isFinite, normalized.y.isFinite, (0...1).contains(normalized.x), (0...1).contains(normalized.y),
              let picture = imageRect(imageSize: imageSize, containerSize: containerSize) else { return nil }
        return CGPoint(x: picture.minX + normalized.x * picture.width, y: picture.minY + normalized.y * picture.height)
    }
}

/// Read-only source image. The coordinate system is already normalized by the
/// image importer; this view has no focus, gesture or camera-service callbacks.
struct ImportedImagePreview: View {
    let image: NSImage?
    let imageSize: CGSize
    let point: CGPoint?
    let redacted: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Yun.Palette.elevated
                if redacted {
                    YunEmptyState(symbol: "eye.slash", message: loc("Image hidden for this screenshot"))
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel(loc("Imported image preview"))
                    if let point, let location = ImportedImageGeometry.markerPoint(normalized: point, imageSize: imageSize, containerSize: geometry.size) {
                        Circle().strokeBorder(.white, lineWidth: 2)
                            .background(Circle().strokeBorder(.black.opacity(0.75), lineWidth: 5))
                            .frame(width: 24, height: 24).position(location)
                            .accessibilityLabel(loc("Model target location"))
                    }
                } else {
                    YunEmptyState(symbol: "photo", message: loc("Open an image file to ask questions without a camera."))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// Render-time projection, never mutation of private user content. The same
/// view is exercised by the public screenshot privacy rendering regression.
struct ObservationPrivateText: View {
    let text: String
    let redacted: Bool
    var body: some View {
        if !redacted { Text(verbatim: text).textSelection(.enabled) }
    }
}

@MainActor struct ImageObservationSourceControls: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack {
                YunBadge(loc("Image file"))
                Spacer(minLength: 0)
                if let frame = model.imageWorkspace.asset?.frame.info {
                    Text(verbatim: "\(frame.width)×\(frame.height)").font(Yun.Text.mono)
                        .foregroundStyle(Yun.Palette.textTertiary)
                }
            }
            if let name = model.imageWorkspace.asset?.displayName {
                Text(model.capturingUI ? loc("Imported image") : name)
                    .font(Yun.Text.caption).lineLimit(2).truncationMode(.middle)
            }
            Button(model.imageWorkspace.asset == nil ? loc("Open image") : loc("Replace image")) { model.chooseObservationImage() }
                .buttonStyle(YunButtonStyle(.primary, small: true))
            Text(loc("Image files up to 8 MB. Your camera connection and AI access stay unchanged."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if model.imageWorkspace.isImporting { ProgressView().controlSize(.small) }
            if let error = model.imageWorkspace.error, !model.capturingUI {
                Text(error).font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

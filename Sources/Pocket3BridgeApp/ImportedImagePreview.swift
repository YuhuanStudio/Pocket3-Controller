import AppKit
import SwiftUI
import Pocket3Core
import YunDesign

enum ImportedImageGeometry {
    static func normalizedPoint(_ point: CGPoint, imageSize: CGSize, containerSize: CGSize, clip: Bool = false) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, let rect = imageRect(imageSize: imageSize, containerSize: containerSize) else { return nil }
        guard clip || ((rect.minX...rect.maxX).contains(point.x) && (rect.minY...rect.maxY).contains(point.y)) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    static func selection(from start: CGPoint, to end: CGPoint, imageSize: CGSize, containerSize: CGSize) -> NormalizedImageRegion? {
        guard let a = normalizedPoint(start, imageSize: imageSize, containerSize: containerSize),
              let b = normalizedPoint(end, imageSize: imageSize, containerSize: containerSize, clip: true),
              abs(end.x - start.x) >= 6, abs(end.y - start.y) >= 6 else { return nil }
        return try? NormalizedImageRegion(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
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

/// File source image with optional analysis-area selection. The importer has
/// normalized its orientation; gestures only choose a crop, never camera focus.
struct ImportedImagePreview: View {
    let image: NSImage?
    let imageSize: CGSize
    let point: CGPoint?
    let redacted: Bool
    var region: NormalizedImageRegion? = nil
    var selectingRegion = false
    var selectRegion: ((NormalizedImageRegion) -> Void)? = nil
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
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
                    if let selection = draftRegion(in: geometry.size) ?? region,
                       let bounds = ImportedImageGeometry.imageRect(imageSize: imageSize, containerSize: geometry.size) {
                        Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .background(.white.opacity(0.06))
                            .frame(width: selection.width * bounds.width, height: selection.height * bounds.height)
                            .position(x: bounds.minX + (selection.x + selection.width/2) * bounds.width,
                                      y: bounds.minY + (selection.y + selection.height/2) * bounds.height)
                            .accessibilityLabel(loc("Selected analysis area"))
                    }
                } else {
                    YunEmptyState(symbol: "photo", message: loc("Open an image or a local video. Analysis uses only the selected frame or area."))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard selectingRegion, !redacted, image != nil else { return }
                        if dragStart == nil {
                            guard ImportedImageGeometry.normalizedPoint(value.startLocation, imageSize: imageSize, containerSize: geometry.size) != nil else { return }
                            dragStart = value.startLocation
                        }
                        dragEnd = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragEnd = nil }
                        guard selectingRegion, !redacted, let start = dragStart,
                              let selected = ImportedImageGeometry.selection(from: start, to: value.location, imageSize: imageSize, containerSize: geometry.size) else { return }
                        selectRegion?(selected)
                    })
        }
        .allowsHitTesting(selectingRegion && !redacted)
        .onChange(of: selectingRegion) { _, _ in dragStart = nil; dragEnd = nil }
    }
    private func draftRegion(in size: CGSize) -> NormalizedImageRegion? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        return ImportedImageGeometry.selection(from: start, to: end, imageSize: imageSize, containerSize: size)
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
                YunBadge(loc(model.imageWorkspace.asset?.videoSource == nil ? "Image file" : "Video frame"))
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
            Button(model.imageWorkspace.asset == nil ? loc("Open media") : loc("Replace media")) { model.chooseObservationImage() }
                .buttonStyle(YunButtonStyle(.primary, small: true))
            Text(loc("Open an image or a local video. Analysis uses only the selected frame or area."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let video = model.imageWorkspace.asset?.videoSource {
                VStack(alignment: .leading, spacing: Yun.Space.xs) {
                    HStack {
                        Text(loc("Video time")).font(Yun.Text.caption)
                        Spacer()
                        Text(String(format: "%.2f / %.2f s", model.imageWorkspace.videoSeekTime, video.metadata.startSeconds + video.metadata.durationSeconds)).font(Yun.Text.mono)
                    }
                    if video.metadata.lastSeekSeconds > video.metadata.startSeconds {
                    Slider(value: Binding(get: { model.imageWorkspace.videoSeekTime }, set: { model.imageWorkspace.videoSeekTime = $0 }),
                           in: video.metadata.startSeconds...video.metadata.lastSeekSeconds,
                           onEditingChanged: { editing in
                               model.imageWorkspace.videoScrubbing = editing
                               if !editing { model.imageWorkspace.seek(to: model.imageWorkspace.videoSeekTime) }
                           })
                        .accessibilityLabel(loc("Video time"))
                    }
                    HStack {
                        Button("−1 s") { model.imageWorkspace.seek(to: max(video.metadata.startSeconds, model.imageWorkspace.videoSeekTime - 1)) }
                        Button("+1 s") { model.imageWorkspace.seek(to: min(video.metadata.lastSeekSeconds, model.imageWorkspace.videoSeekTime + 1)) }
                    }.buttonStyle(YunButtonStyle(.ghost, small: true))
                    Button(loc("Compare +1 s")) { model.imageWorkspace.compareNextSecond() }
                        .buttonStyle(YunButtonStyle(.secondary, small: true))
                        .disabled(!model.imageWorkspace.ready || model.imageWorkspace.isComparingFrames || model.imageWorkspace.videoSeekTime >= video.metadata.lastSeekSeconds)
                    if model.imageWorkspace.isComparingFrames { ProgressView().controlSize(.mini) }
                    if let comparison = model.imageWorkspace.frameComparison {
                        Text(String(format: loc("Frame change · %.3f luma · %.1f%% samples"), comparison.metrics.meanAbsoluteLumaDifference, comparison.metrics.darkPixelChangeFraction * 100))
                            .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.imageWorkspace.ready {
                YunDivider()
                HStack {
                    Button(loc(model.imageWorkspace.selectingRegion ? "Drag over the image" : "Select area")) {
                        model.imageWorkspace.selectingRegion.toggle()
                    }.buttonStyle(YunButtonStyle(.secondary, small: true))
                    if model.imageWorkspace.region != nil {
                        Button(loc("Whole frame")) { model.imageWorkspace.setRegion(nil) }
                            .buttonStyle(YunButtonStyle(.ghost, small: true))
                    }
                }
                if model.imageWorkspace.region != nil {
                    Text(loc("Only the selected area is sent to the model.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                }
            }
            if model.imageWorkspace.isImporting { ProgressView().controlSize(.small) }
            if let error = model.imageWorkspace.error, !model.capturingUI {
                Text(error).font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

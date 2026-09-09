import SwiftUI
import Pocket3Core
import YunDesign

/// Full advertised UVC ranges, using the same compact controls as YunAudio.
struct GimbalRangeControls: View {
    @Bindable var model: AppModel
    @State private var isSubmitting = false

    private var sessionID: String { model.status?.capture.sessionID ?? "" }
    private var canMove: Bool {
        model.ready && !model.isConnecting && !model.isManualPresetBusy
            && model.status?.gimbal?.writable == true
            && model.status?.motionActive == false && !isSubmitting
    }

    var body: some View {
        if let capabilities = model.status?.gimbal,
           let minimum = capabilities.minimum, let maximum = capabilities.maximum,
           minimum.pan < maximum.pan, minimum.tilt < maximum.tilt {
            VStack(spacing: Yun.Space.sm) {
                HStack(spacing: Yun.Space.sm) {
                    preset("home", symbol: "scope", label: loc("Center view"))
                    preset("front", symbol: "camera", label: loc("Face front"))
                    preset("back", symbol: "camera.rotate", label: loc("Face back"))
                }
                .disabled(!canMove || capabilities.defaultPosition == nil)

                GimbalAxisSlider(label: loc("Pan"),
                    position: Double(capabilities.position.pan) / 3600,
                    range: Double(minimum.pan) / 3600...Double(maximum.pan) / 3600,
                    sessionID: sessionID, enabled: canMove,
                    currentSession: { self.sessionID }) { value, session in
                        await point(pan: value, tilt: nil, session: session)
                    }
                    .id("\(sessionID):pan")
                GimbalAxisSlider(label: loc("Tilt"),
                    position: Double(capabilities.position.tilt) / 3600,
                    range: Double(minimum.tilt) / 3600...Double(maximum.tilt) / 3600,
                    sessionID: sessionID, enabled: canMove,
                    currentSession: { self.sessionID }) { value, session in
                        await point(pan: nil, tilt: value, session: session)
                    }
                    .id("\(sessionID):tilt")
            }
        }
    }

    private func preset(_ direction: String, symbol: String, label: String) -> some View {
        Button {
            let requestedSession = sessionID
            Task {
                guard canMove, !requestedSession.isEmpty, requestedSession == sessionID,
                      model.status?.gimbal?.defaultPosition != nil else { return }
                isSubmitting = true
                defer { isSubmitting = false }
                await model.move(direction)
            }
        } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity)
        }
        .buttonStyle(YunButtonStyle(.secondary, small: true))
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private func point(pan: Double?, tilt: Double?, session: String) async {
        guard canMove, !session.isEmpty, session == sessionID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await model.point(panDegrees: pan, tiltDegrees: tilt)
    }
}

/// A session-keyed child discards the entire gesture and its draft on reconnect.
/// Polling updates the readback without replacing a value being dragged.
private struct GimbalAxisSlider: View {
    let label: String
    let position: Double
    let range: ClosedRange<Double>
    let sessionID: String
    let enabled: Bool
    let currentSession: () -> String
    let commit: (Double, String) async -> Void
    @State private var draft: Double?
    @State private var isCommitting = false

    var body: some View {
        HStack(spacing: Yun.Space.sm) {
            Text(label)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .frame(width: 28, alignment: .leading)
            YunSlider(fraction: Binding(
                get: {
                    max(0, min(1, ((draft ?? position) - range.lowerBound)
                        / (range.upperBound - range.lowerBound)))
                },
                set: { fraction in
                    guard enabled, !isCommitting, sessionID == currentSession(), fraction.isFinite else { return }
                    draft = range.lowerBound + max(0, min(1, fraction)) * (range.upperBound - range.lowerBound)
                }), onEditingEnded: {
                    guard enabled, !isCommitting, let value = draft,
                          !sessionID.isEmpty, sessionID == currentSession() else { draft = nil; return }
                    isCommitting = true
                    Task {
                        defer { draft = nil; isCommitting = false }
                        guard sessionID == currentSession() else { return }
                        await commit(value, sessionID)
                    }
                })
                .disabled(!enabled || isCommitting)
                .allowsHitTesting(enabled && !isCommitting)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(degreeLabel))
            Text(degreeLabel)
                .font(Yun.Text.mono)
                .foregroundStyle(Yun.Palette.textTertiary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .onChange(of: sessionID) { _, _ in draft = nil }
        .onChange(of: enabled) { _, value in
            if !value && !isCommitting { draft = nil }
        }
    }

    private var degreeLabel: String {
        "\((draft ?? position).formatted(.number.precision(.fractionLength(0...1))))°"
    }
}

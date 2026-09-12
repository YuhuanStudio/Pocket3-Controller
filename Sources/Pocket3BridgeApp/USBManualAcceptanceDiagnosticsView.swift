import SwiftUI
import Pocket3Core
import YunDesign

/// A compact developer-only disclosure for the latest acceptance report. It
/// deliberately stays inside the existing Diagnostics camera card, so the
/// normal page keeps its current cards and footer height.
struct USBManualAcceptanceDiagnosticsView: View {
    let diagnostics: USBManualAcceptanceDiagnostics?
    let stage: String?
    let failure: String?
    @Binding var isExpanded: Bool

    var body: some View {
        YunDisclosure(loc("USB manual acceptance"), subtitle: summary,
                      isExpanded: $isExpanded) {
            if let diagnostics {
                VStack(alignment: .leading, spacing: Yun.Space.xs) {
                    compactRow(loc("Gimbal Stop"),
                               "\(diagnostics.gimbalStopVerifiedCount)/\(diagnostics.gimbalHoldCount)")
                    compactRow(loc("Gimbal restore"),
                               "\(diagnostics.gimbalRestoreVerifiedCount)/\(diagnostics.gimbalHoldCount)")
                    compactRow(loc("Zoom Stop"), flag(diagnostics.zoomStopVerified))
                    compactRow(loc("Zoom restore"), flag(diagnostics.zoomRestoreVerified))
                    compactRow(loc("Reconnect fence"), flag(
                        diagnostics.reconnectSessionChanged &&
                        diagnostics.oldSessionSuppressed))
                    compactRow(loc("New session ready"), flag(diagnostics.newSessionReady))
                    compactRow(loc("Final restore"), flag(diagnostics.finalRestoreVerified))
                    Text("\(loc("Initial session")): \(diagnostics.initialSessionID)")
                    Text("\(loc("Final session")): \(diagnostics.finalSessionID)")
                        .textSelection(.enabled)
                }
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            } else if let failure {
                Text("\(loc("Acceptance run failed")): \(failure)")
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(loc("No completed USB manual acceptance run"))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
            }
            if let stage {
                Text("\(loc("Last acceptance stage")): \(stage)")
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("Pocket3USBManualAcceptanceDiagnostics")
    }

    private var summary: String {
        guard let diagnostics else {
            if let failure { return "\(loc("Acceptance run failed")) · \(failure)" }
            if let stage { return "\(loc("Last acceptance stage")) · \(stage)" }
            return loc("No completed USB manual acceptance run")
        }
        let outcome = diagnostics.metricsPassed
            ? loc("Metrics passed") : loc("Metrics incomplete")
        return "\(outcome) · \(diagnostics.gimbalStopVerifiedCount)/\(diagnostics.gimbalHoldCount) \(loc("Gimbal Stop"))"
    }

    private func compactRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(label).foregroundStyle(Yun.Palette.textSecondary)
            Spacer(minLength: Yun.Space.sm)
            Text(value).foregroundStyle(Yun.Palette.textPrimary)
                .monospacedDigit()
        }
    }

    private func flag(_ value: Bool) -> String {
        value ? "✓" : "—"
    }
}

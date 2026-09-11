import Foundation
import CryptoKit

/// Three read-only observations from one explicitly paired BLE session.
/// "Fresh" means received by this host within five seconds, not cryptographic
/// freshness, a setter acknowledgment, or association with the USB camera.
struct BluetoothCameraSettingsStore: Sendable {
    struct AdmissionSnapshot: Sendable {
        let observation: CameraSettingsObservation
        let sequence: UInt16
        let fingerprints: [Data]
    }
    static let maximumAge: TimeInterval = 5
    static let maximumFingerprintsPerProperty = 16
    private static let properties: [CameraSettingsProperty] = [
        .lensState, .imageEffect, .exposure, .videoParameters, .sensorAspectRatio,
        .photoParameters, .lapseParameters, .motionlapseParameters, .panoramaParameters
    ]
    private struct Entry: Sendable {
        let observation: CameraSettingsObservation
        let sequence: UInt16
    }
    private struct ResetWindow: Sendable { let start: TimeInterval; let end: TimeInterval }
    private var sessionID: UUID?
    private var peripheralID: UUID?
    private var entries: [CameraSettingsProperty: Entry] = [:]
    // SHA-256 fingerprints only. Never retain packet/value payloads or credentials.
    private var fingerprints: [CameraSettingsProperty: [Data]] = [:]
    private var resetWindows: [CameraSettingsProperty: ResetWindow] = [:]
    private var lastAcceptedUptime: TimeInterval?

    static func binding(sessionID: UUID) -> ContinuousGimbalBinding {
        ContinuousGimbalBinding(sessionID: "ble:\(sessionID.uuidString)", generation: 0)
    }
    mutating func clear() {
        sessionID = nil; peripheralID = nil; entries.removeAll(); fingerprints.removeAll()
        resetWindows.removeAll(); lastAcceptedUptime = nil
    }
    mutating func bind(sessionID: UUID, peripheralID: UUID) {
        clear(); self.sessionID = sessionID; self.peripheralID = peripheralID
    }

    /// A caller may reset only the sequence baseline immediately before an
    /// explicit read subscription. Observations/age and replay hashes stay put.
    /// This method performs no I/O and does not itself refresh a displayed value.
    @discardableResult
    mutating func resetAdmission(for property: CameraSettingsProperty, sessionID: UUID, peripheralID: UUID,
                                 at uptime: TimeInterval) -> Bool {
        guard self.sessionID == sessionID, self.peripheralID == peripheralID, Self.properties.contains(property),
              uptime.isFinite, uptime >= 0, lastAcceptedUptime == nil || uptime >= lastAcceptedUptime!,
              (uptime + 2).isFinite, uptime + 2 > uptime else { return false }
        resetWindows[property] = ResetWindow(start: uptime, end: uptime + 2)
        return true
    }

    @discardableResult
    mutating func receive(_ packet: ValidatedDUMLPacket, sessionID: UUID, peripheralID: UUID,
                          paired: Bool, uptime: TimeInterval) -> Bool {
        guard self.sessionID == sessionID, self.peripheralID == peripheralID, paired,
              uptime.isFinite, uptime >= 0, lastAcceptedUptime == nil || uptime >= lastAcceptedUptime! else { return false }
        let frame = packet.frame
        guard frame.source == 0x28, frame.destination == 0x02, frame.flags == 0,
              frame.commandSet == 0, frame.commandID == 0x99,
              let push = try? CameraPropertyCodec.decodePush(from: frame), Self.properties.contains(push.property),
              push.value.count <= BluetoothCameraPropertyQuery.maximumValueBytes,
              let observation = CameraSettingsObservation.decode(push, binding: Self.binding(sessionID: sessionID), receivedUptime: uptime) else { return false }
        let fingerprint = Data(SHA256.hash(data: packet.frameData))
        guard fingerprints[push.property]?.contains(fingerprint) != true else { return false }

        if let previous = entries[push.property] {
            guard uptime >= previous.observation.receivedUptime else { return false }
            let distance = frame.sequence &- previous.sequence
            let advancesSequence = distance > 0 && distance < 0x8000
            let observationExpired = !previous.observation.isFresh(now: uptime, maximumAge: Self.maximumAge)
            let explicitReset = resetWindows[push.property].map { uptime >= $0.start && uptime <= $0.end } ?? false
            // Each property has its own baseline: unrelated, sparse pushes
            // cannot advance it. Rebase after expiry or an explicit read, but
            // never refresh age from a recently repeated identical packet.
            guard advancesSequence || observationExpired || explicitReset else { return false }
        }

        entries[push.property] = Entry(observation: observation, sequence: frame.sequence)
        var history = fingerprints[push.property] ?? []
        history.append(fingerprint)
        if history.count > Self.maximumFingerprintsPerProperty { history.removeFirst(history.count - Self.maximumFingerprintsPerProperty) }
        fingerprints[push.property] = history
        resetWindows.removeValue(forKey: push.property)
        lastAcceptedUptime = uptime
        return true
    }

    func snapshot(sessionID: UUID, peripheralID: UUID?, paired: Bool,
                  nowUptime: TimeInterval) -> [CameraSettingsObservation] {
        guard self.sessionID == sessionID, self.peripheralID == peripheralID, paired,
              nowUptime.isFinite, nowUptime >= 0 else { return [] }
        return Self.properties.compactMap { property in
            guard let value = entries[property]?.observation,
                  value.isFresh(now: nowUptime, maximumAge: Self.maximumAge) else { return nil }
            return value
        }
    }

    /// Internal write-observation seed. No raw payload is retained or exposed;
    /// a setter cannot use an old replay to manufacture a fresh confirmation.
    func admissionSnapshot(for property: CameraSettingsProperty, sessionID: UUID,
                           peripheralID: UUID, paired: Bool, nowUptime: TimeInterval) -> AdmissionSnapshot? {
        guard self.sessionID == sessionID, self.peripheralID == peripheralID, paired,
              let entry = entries[property], entry.observation.isFresh(now: nowUptime, maximumAge: Self.maximumAge) else { return nil }
        return AdmissionSnapshot(observation: entry.observation, sequence: entry.sequence,
                                 fingerprints: fingerprints[property] ?? [])
    }

    /// Bounded scalar diagnostic for pure tests; not a payload/history export.
    var retainedFingerprintCount: Int { fingerprints.values.reduce(0) { $0 + $1.count } }
}

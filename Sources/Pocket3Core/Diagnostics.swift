import Foundation

public enum Diagnostics {
    /// Diagnostics are shareable by default. Error text can also contain paths
    /// and device names, so preserve error presence rather than its raw wording.
    public static func redacted(_ status: ServiceStatus) throws -> JSONValue {
        var value = try JSONValue.encode(status)
        if case .object(var object) = value {
            object["devices"] = .array([]); object["selected"] = .null
            object["activities"] = .array([]); object["gimbal"] = .null
            object["hasError"] = .bool(status.lastError != nil); object["lastError"] = .null
            object["redacted"] = .bool(true)
            if case .object(var capture) = object["capture"] {
                capture["frame"] = .null; capture["sessionID"] = .string("redacted")
                object["capture"] = .object(capture)
            }
            value = .object(object)
        }
        return value
    }
}

/// Product labels shared by the App, CLI and MCP server. The stable bundle,
/// signing and storage identifiers remain independent of the display name.
public enum Pocket3Product {
    public static let displayName = "Pocket 3 Controller"
    public static let version = "0.0.1"
    public static let prereleaseLabel = "beta 2"
    public static let displayVersion = version + " " + prereleaseLabel
    public static let semanticVersion = version + "-beta.2"
}

enum LumenMCPVersion {
    /// Canonical lumen-mcp release version. The npm publish script reads this
    /// value and synchronizes every package manifest before publishing.
    static let current = "1.0.2"

    static var banner: String { "lumen-mcp \(current)" }
}

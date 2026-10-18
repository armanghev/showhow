import AppKit
import MacHelperCore

/// Wires Mac Helper into Claude Code and Claude Desktop.
@MainActor
enum IntegrationInstaller {
    /// Writes `~/Library/Application Support/MacHelper/mcp.json` (port and
    /// token) for the stdio bridge, readable only by this user.
    static func writeEndpointFile(_ info: MCPEndpointInfo) {
        let url = MCPEndpointInfo.defaultURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(info)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppModel.shared.attention = "Could not write the MCP connection file: \(error.localizedDescription)"
        }
    }

    /// Copies `claude mcp add --transport http mac-helper … --header "Authorization: Bearer …"`.
    @discardableResult
    static func copyClaudeCodeCommand() -> Bool {
        guard let endpoint = MCPHTTPServer.shared.endpoint else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.claudeCodeCommand, forType: .string)
        return true
    }

    /// The stdio bridge inside the app bundle.
    static var bridgeURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "machelper-mcp")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/machelper-mcp")
    }

    /// Adds or replaces the `mac-helper` entry in Claude Desktop's config,
    /// keeping a backup of the original file.
    static func installInClaudeDesktop() throws {
        guard let bridge = bridgeURL, FileManager.default.isExecutableFile(atPath: bridge.path) else {
            throw HandoffError("The machelper-mcp bridge is missing from the app bundle.")
        }
        let configURL = ClaudeDesktopConfig.defaultURL()
        let existing = try? Data(contentsOf: configURL)
        let merged = try ClaudeDesktopConfig.merged(existing: existing, bridgePath: bridge.path)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            try existing.write(to: configURL.appendingPathExtension("machelper-backup"), options: .atomic)
        }
        var data = try JSONEncoder.pretty.encode(merged)
        data.append(0x0A)
        try data.write(to: configURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

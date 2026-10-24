import Foundation

/// Keeps the `afm` MCP server registered with Claude Code and Claude Desktop.
public enum ClaudeHook {
    public struct Status: Sendable, Equatable {
        public var claudeCLIFound: Bool
        public var claudeCodeHooked: Bool
        public var claudeCodePath: String?
        public var desktopHooked: Bool
        public var desktopPath: String?
        public init(claudeCLIFound: Bool = false, claudeCodeHooked: Bool = false, claudeCodePath: String? = nil,
                    desktopHooked: Bool = false, desktopPath: String? = nil) {
            self.claudeCLIFound = claudeCLIFound; self.claudeCodeHooked = claudeCodeHooked; self.claudeCodePath = claudeCodePath
            self.desktopHooked = desktopHooked; self.desktopPath = desktopPath
        }
    }

    /// Honors $HOME so the hook can be exercised against a sandbox home.
    static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    public static var stableCLIPath: String { home + "/.local/bin/afm" }

    public static var desktopConfig: URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Points ~/.local/bin/afm at `binary` (the copy inside the app bundle).
    public static func linkCLI(to binary: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (stableCLIPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let current = try? fm.destinationOfSymbolicLink(atPath: stableCLIPath), current == binary { return }
        if (try? fm.destinationOfSymbolicLink(atPath: stableCLIPath)) != nil || fm.fileExists(atPath: stableCLIPath) {
            try fm.removeItem(atPath: stableCLIPath)
        }
        try fm.createSymbolicLink(atPath: stableCLIPath, withDestinationPath: binary)
    }

    // MARK: Claude Code (through the `claude` CLI, so its config format stays its business)

    static func sh(_ command: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public static func claudeCodeStatus() -> (cli: Bool, hooked: Bool, path: String?) {
        let (found, _) = sh("command -v claude")
        guard found == 0 else { return (false, false, nil) }
        let (code, out) = sh("claude mcp get afm 2>&1")
        guard code == 0 else { return (true, false, nil) }
        let path = out.split(separator: "\n").first { $0.contains("Command:") }
            .map { $0.replacingOccurrences(of: "Command:", with: "").trimmingCharacters(in: .whitespaces) }
        return (true, true, path)
    }

    @discardableResult
    public static func hookClaudeCode(cliPath: String) throws -> String {
        let st = claudeCodeStatus()
        guard st.cli else { throw AFMError(code: "no_claude", message: "Claude Code's `claude` command wasn't found on your PATH.") }
        if st.hooked && st.path == cliPath { return "Already registered." }
        if st.hooked { _ = sh("claude mcp remove afm --scope user 2>&1") }
        let (code, out) = sh("claude mcp add --scope user afm -- \(shellQuote(cliPath)) mcp 2>&1")
        guard code == 0 else { throw AFMError(code: "claude_mcp", message: out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return st.hooked ? "Updated the path." : "Registered."
    }

    public static func unhookClaudeCode() -> String {
        let (code, out) = sh("claude mcp remove afm --scope user 2>&1")
        return code == 0 ? "Removed." : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Claude Desktop (JSON file; backed up before every change)

    public static func desktopStatus() -> (hooked: Bool, path: String?) {
        guard let d = try? Data(contentsOf: desktopConfig),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let afm = servers["afm"] as? [String: Any] else { return (false, nil) }
        return (true, afm["command"] as? String)
    }

    @discardableResult
    public static func hookDesktop(cliPath: String) throws -> String {
        try editDesktop { servers in
            if let a = servers["afm"] as? [String: Any], a["command"] as? String == cliPath { return false }
            servers["afm"] = ["command": cliPath, "args": ["mcp"]]
            return true
        } ? "Registered. Restart Claude Desktop to load it." : "Already registered."
    }

    @discardableResult
    public static func unhookDesktop() throws -> String {
        try editDesktop { servers in servers.removeValue(forKey: "afm") != nil } ? "Removed. Restart Claude Desktop." : "Wasn't registered."
    }

    /// Returns whether anything changed.
    static func editDesktop(_ change: (inout [String: Any]) -> Bool) throws -> Bool {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: desktopConfig) {
            guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw AFMError(code: "desktop_config", message: "Claude Desktop's config isn't valid JSON, so it was left alone.")
            }
            root = obj
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        guard change(&servers) else { return false }
        root["mcpServers"] = servers
        try fm.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: desktopConfig.path) {
            let backup = desktopConfig.deletingPathExtension().appendingPathExtension("afm-backup.json")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: desktopConfig, to: backup)
        }
        let d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: desktopConfig, options: .atomic)
        return true
    }

    public static func status() -> Status {
        let c = claudeCodeStatus()
        let d = desktopStatus()
        return Status(claudeCLIFound: c.cli, claudeCodeHooked: c.hooked, claudeCodePath: c.path, desktopHooked: d.hooked, desktopPath: d.path)
    }
}

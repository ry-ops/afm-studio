import Foundation
import FoundationModels

/// Built-in tools the on-device model can call during a request.
public enum ToolKind: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case datetime
    case calculator
    case systemInfo = "system_info"
    case readFile = "read_file"
    case listDirectory = "list_directory"
    case fetchURL = "fetch_url"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .datetime: "Date & time"
        case .calculator: "Calculator"
        case .systemInfo: "System info"
        case .readFile: "Read file"
        case .listDirectory: "List folder"
        case .fetchURL: "Fetch web page"
        }
    }
    public var summary: String {
        switch self {
        case .datetime: "Current date, time and time zone conversion."
        case .calculator: "Exact arithmetic, so the model doesn't guess at math."
        case .systemInfo: "macOS version, memory, CPU count, uptime."
        case .readFile: "Reads a text file in your home folder (first 6,000 characters)."
        case .listDirectory: "Lists a folder in your home folder."
        case .fetchURL: "Downloads a web page and returns its text. Uses the network."
        }
    }
    public var symbol: String {
        switch self {
        case .datetime: "clock"
        case .calculator: "function"
        case .systemInfo: "desktopcomputer"
        case .readFile: "doc.text"
        case .listDirectory: "folder"
        case .fetchURL: "globe"
        }
    }
    /// Tools that touch files or the network are off unless asked for.
    public var isSensitive: Bool { self == .readFile || self == .listDirectory || self == .fetchURL }
    public static var safeDefaults: [ToolKind] { [.datetime, .calculator] }
    public static var safe: [ToolKind] { [.datetime, .calculator, .systemInfo] }
}

/// Records tool calls so callers can show them.
public final class ToolCallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    public var onCall: (@Sendable (String) -> Void)?
    public init(onCall: (@Sendable (String) -> Void)? = nil) { self.onCall = onCall }
    public var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    func record(_ s: String) {
        lock.lock(); _calls.append(s); lock.unlock()
        onCall?(s)
    }
}

/// A tool whose argument schema is built at runtime.
public struct DynamicTool: Tool {
    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let handler: @Sendable (GeneratedContent) async throws -> String

    public init(name: String, description: String, parameters: GenerationSchema,
                handler: @escaping @Sendable (GeneratedContent) async throws -> String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        try await handler(arguments)
    }
}

public enum ToolRegistry {
    static func args(_ name: String, _ props: [(String, String, Bool)]) -> GenerationSchema {
        let p = props.map { DynamicGenerationSchema.Property(name: $0.0, description: $0.1, schema: .init(type: String.self), isOptional: $0.2) }
        return try! GenerationSchema(root: DynamicGenerationSchema(name: name, properties: p), dependencies: [])
    }

    static func str(_ c: GeneratedContent, _ key: String) -> String? {
        (try? c.value(String?.self, forProperty: key)) ?? nil
    }

    public static func make(_ kinds: [ToolKind], tracker: ToolCallTracker? = nil) -> [any Tool] {
        kinds.map { make($0, tracker: tracker) }
    }

    public static func make(_ kind: ToolKind, tracker: ToolCallTracker?) -> any Tool {
        switch kind {
        case .datetime:
            return DynamicTool(name: kind.rawValue, description: "Get the current date and time. Optionally pass an IANA time zone such as America/Chicago.",
                               parameters: args("DateTimeArgs", [("timezone", "IANA time zone identifier, e.g. Europe/Paris", true)])) { a in
                let tzName = str(a, "timezone")
                tracker?.record("datetime(\(tzName ?? "local"))")
                let tz = tzName.flatMap(TimeZone.init(identifier:)) ?? .current
                let f = DateFormatter()
                f.timeZone = tz
                f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
                return "\(f.string(from: Date())) (time zone \(tz.identifier))"
            }
        case .calculator:
            return DynamicTool(name: kind.rawValue, description: "Evaluate an arithmetic expression exactly. Supports + - * / ^ %, parentheses, sqrt, sin, cos, tan, log, ln, abs, round, floor, ceil, pi and e.",
                               parameters: args("CalcArgs", [("expression", "The expression, e.g. (12.5 * 4) / 3", false)])) { a in
                let expr = str(a, "expression") ?? ""
                tracker?.record("calculator(\(expr))")
                do {
                    let v = try Calculator.evaluate(expr)
                    return "\(expr) = \(Calculator.format(v))"
                } catch {
                    return "Could not evaluate \"\(expr)\": \(error.localizedDescription)"
                }
            }
        case .systemInfo:
            return DynamicTool(name: kind.rawValue, description: "Only when the user asks about this Mac itself: get its macOS version, memory, processor count and uptime.",
                               parameters: args("SysArgs", [("detail", "Optional focus, e.g. memory", true)])) { _ in
                tracker?.record("system_info()")
                let p = ProcessInfo.processInfo
                let gb = Double(p.physicalMemory) / 1_073_741_824
                let up = Int(p.systemUptime)
                return """
                macOS: \(p.operatingSystemVersionString)
                Host: \(Host.current().localizedName ?? p.hostName)
                Memory: \(String(format: "%.0f", gb)) GB
                Processors: \(p.processorCount) (\(p.activeProcessorCount) active)
                Uptime: \(up / 86400)d \((up % 86400) / 3600)h \((up % 3600) / 60)m
                Thermal state: \(["nominal", "fair", "serious", "critical"][min(p.thermalState.rawValue, 3)])
                """
            }
        case .readFile:
            return DynamicTool(name: kind.rawValue, description: "Read a UTF-8 text file from the user's home folder. Returns up to 6,000 characters.",
                               parameters: args("ReadArgs", [("path", "Path to the file, e.g. ~/Documents/notes.txt", false)])) { a in
                let path = str(a, "path") ?? ""
                tracker?.record("read_file(\(path))")
                return try FileAccess.readText(path, limit: 6000)
            }
        case .listDirectory:
            return DynamicTool(name: kind.rawValue, description: "List the files in a folder inside the user's home folder.",
                               parameters: args("ListArgs", [("path", "Folder path, e.g. ~/Downloads", false)])) { a in
                let path = str(a, "path") ?? "~"
                tracker?.record("list_directory(\(path))")
                return try FileAccess.list(path, limit: 100)
            }
        case .fetchURL:
            return DynamicTool(name: kind.rawValue, description: "Download a web page over HTTP(S) and return its readable text (up to 6,000 characters).",
                               parameters: args("FetchArgs", [("url", "The https:// URL to fetch", false)])) { a in
                let url = str(a, "url") ?? ""
                tracker?.record("fetch_url(\(url))")
                return try await WebText.fetch(url, limit: 6000)
            }
        }
    }
}

/// Read-only file access confined to the user's home folder.
public enum FileAccess {
    /// Home folder plus any folders listed in `AFM_ALLOWED_PATHS` (colon-separated).
    public static var allowedRoots: [String] {
        func norm(_ p: String) -> String { URL(fileURLWithPath: (p as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path }
        var roots = [norm(FileManager.default.homeDirectoryForCurrentUser.path)]
        if let extra = ProcessInfo.processInfo.environment["AFM_ALLOWED_PATHS"] {
            roots += extra.split(separator: ":").map { norm(String($0)) }
        }
        return roots
    }

    public static func resolve(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = expanded.hasPrefix("/") ? expanded : home + "/" + expanded
        let url = URL(fileURLWithPath: base).resolvingSymlinksInPath().standardizedFileURL
        guard allowedRoots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else {
            throw AFMError(code: "forbidden", message: "Only files inside your home folder can be read.",
                           suggestion: "Set AFM_ALLOWED_PATHS to allow other folders.")
        }
        return url
    }

    public static func readText(_ path: String, limit: Int) throws -> String {
        let url = try resolve(path)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if (attrs[.size] as? Int ?? 0) > 20_000_000 { throw AFMError(code: "too_large", message: "File is larger than 20 MB.") }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AFMError(code: "binary", message: "That file isn't text.")
        }
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "\n…[truncated, \(s.count) characters total]"
    }

    public static func list(_ path: String, limit: Int) throws -> String {
        let url = try resolve(path)
        let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit).map { u -> String in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true { return u.lastPathComponent + "/" }
            return "\(u.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)))"
        }
        return lines.isEmpty ? "(empty folder)" : lines.joined(separator: "\n") + (items.count > limit ? "\n…and \(items.count - limit) more" : "")
    }
}

public enum WebText {
    public static func fetch(_ s: String, limit: Int) async throws -> String {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AFMError(code: "bad_url", message: "Only http and https URLs can be fetched.")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("afm-studio/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        let text = strip(html)
        return text.count <= limit ? text : String(text.prefix(limit)) + "\n…[truncated]"
    }

    public static func strip(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|p|div|li|h[1-6]|tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\n\\s*(\\n\\s*)+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

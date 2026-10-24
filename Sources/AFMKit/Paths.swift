import Foundation

/// Where AFM Studio keeps sessions, recipes, history and settings.
/// Set `AFM_HOME` to override (tests use this).
public enum AFMPaths {
    public static var root: URL {
        let base: URL
        if let env = ProcessInfo.processInfo.environment["AFM_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AFMStudio", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func dir(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public static var sessions: URL { dir("sessions") }
    public static var recipes: URL { dir("recipes") }
    public static var feedback: URL { dir("feedback") }
    public static var history: URL { root.appendingPathComponent("history.jsonl") }
    public static var settings: URL { root.appendingPathComponent("settings.json") }
}

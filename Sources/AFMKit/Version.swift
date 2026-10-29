import Foundation

public enum AFMVersion {
    public static let string = "0.2.5"
    public static let name = "afm-studio"

    /// The commit this build came from, read once from the app's Info.plist (`AFMCommit`, written by
    /// build-app.sh). Empty for `swift run` and other builds outside an app bundle. Being a `let`,
    /// it is read on first use: a long-running process that touches it at launch keeps reporting
    /// its own build after a newer one is installed over it.
    public static let commit: String = {
        if let c = Bundle.main.object(forInfoDictionaryKey: "AFMCommit") as? String, !c.isEmpty { return c }
        // The CLI runs from Contents/Helpers/afm, where Bundle.main is not the app.
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              let c = info["AFMCommit"] as? String else { return "" }
        return c
    }()

    /// When this process started.
    public static let launched = Date()
}

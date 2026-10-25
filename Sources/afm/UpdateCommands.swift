import Foundation
import AFMKit

/// The checkout this afm came from: the app bundle's recorded source, or the repo around a .build binary.
func cliSourceCheckout() -> String? {
    let exe = executablePath()
    if let r = exe.range(of: "/.build/") {
        let repo = String(exe[..<r.lowerBound])
        return FileManager.default.fileExists(atPath: repo + "/.git") ? repo : nil
    }
    if let r = exe.range(of: ".app/Contents/"), let b = Bundle(path: String(exe[..<r.lowerBound]) + ".app") {
        return Updates.sourceCheckout(bundle: b)
    }
    return nil
}

func cmdUpdate(_ a: Args) async {
    let sub = a.positionals.first ?? "check"
    switch sub {
    case "check", "install":
        let status: Updates.Status
        do { status = try await Updates.check() } catch { fail(error) }
        if a.json {
            var o: [String: Any] = ["current": AFMVersion.string]
            switch status {
            case .available(let r): o["update_available"] = true; o["latest"] = r.version?.description ?? r.tag; o["url"] = r.url
            case .upToDate(let v): o["update_available"] = false; o["latest"] = v
            case .noReleases: o["update_available"] = false
            }
            out(JSONSchemaConverter.jsonText(o))
            return
        }
        switch status {
        case .noReleases:
            out("AFM Studio \(AFMVersion.string). No releases are published yet.")
        case .upToDate(let v):
            out(good("✓ ") + "AFM Studio \(AFMVersion.string) is up to date" + dim(" (latest release: \(v))"))
        case .available(let r):
            out(bold("AFM Studio \(r.version?.description ?? r.tag) is available") + dim("  (you have \(AFMVersion.string))"))
            out(dim("  " + r.url))
            if !r.notes.isEmpty {
                let lines = r.notes.split(separator: "\n", omittingEmptySubsequences: false).prefix(12)
                out("\n" + lines.map { "  " + $0 }.joined(separator: "\n") + (r.notes.split(separator: "\n").count > 12 ? dim("\n  …") : ""))
            }
            out("\n" + bold("To update:"))
            out(Updates.howToUpdate(r, source: cliSourceCheckout()).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
        if sub == "install" { out(dim("\nOne-step install isn't built yet. Run the steps above.")) }
    case "auto":
        var s = AFMSettings.load()
        switch a.positionals.dropFirst().first {
        case "on": s.checkForUpdates = true; s.save(); out("Daily update checks are on. The app checks GitHub at most once a day.")
        case "off": s.checkForUpdates = false; s.save(); out("Daily update checks are off.")
        default: out("Daily update checks are \(s.checkForUpdates ? "on" : "off"). Use: afm update auto on|off")
        }
    default:
        fail("Unknown update command \(sub)", hint: "Use: afm update [check] | afm update auto on|off")
    }
}

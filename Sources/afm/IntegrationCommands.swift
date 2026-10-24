import Foundation
import AFMKit

func cmdIntegrations(_ a: Args) {
    var args = a.positionals
    let sub = args.isEmpty ? "list" : args.removeFirst()
    func find(_ id: String?) -> any AFMIntegration {
        guard let id, let i = IntegrationRegistry.find(id) else {
            fail("unknown integration \(id ?? "")", hint: "Run `afm integrations` to list them.", code: 2)
        }
        return i
    }
    func onOff(_ flag: String) -> Bool? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return ["on", "true", "yes", "1"].contains(args[i + 1].lowercased())
    }
    switch sub {
    case "list":
        for i in IntegrationRegistry.all {
            let p = IntegrationRegistry.prefs(i.id)
            let state = p.enabled ? good("● on") : dim("○ off")
            out("\(state)  \(bold(i.id.padding(toLength: 10, withPad: " ", startingAt: 0))) \(i.summary)")
            if p.enabled { out(dim("            chat tools \(p.chat ? "on" : "off") · tools for Claude \(p.claude ? "on" : "off")")) }
            out(dim("            writes: \(i.manifest.writes.rawValue) · talks to: \(i.manifest.hosts.joined(separator: ", "))"))
        }
        out(dim("\nafm integrations enable ID [--chat on|off] [--claude on|off]   ·   afm integrations disable ID"))
    case "show":
        let i = find(args.first)
        out(bold(i.name) + "  " + i.summary)
        out("Credentials  " + i.manifest.credentials.joined(separator: "; "))
        out("Talks to     " + i.manifest.hosts.joined(separator: ", "))
        out("Writes       " + i.manifest.writes.rawValue)
        out("Data         " + i.manifest.dataNote)
        out("Claude tools " + i.mcpTools.map(\.name).joined(separator: ", "))
    case "enable", "on":
        let i = find(args.first)
        IntegrationRegistry.setPrefs(i.id) { p in
            p.enabled = true
            if let c = onOff("--chat") { p.chat = c }
            if let c = onOff("--claude") { p.claude = c }
        }
        let p = IntegrationRegistry.prefs(i.id)
        out(good("✓ \(i.name) is on.") + dim(" Chat tools \(p.chat ? "on" : "off"), tools for Claude \(p.claude ? "on" : "off")."))
        if p.claude { out(dim("Restart Claude Code or Claude Desktop so they pick up the new tools.")) }
    case "disable", "off":
        let i = find(args.first)
        IntegrationRegistry.setPrefs(i.id) { $0.enabled = false }
        out("\(i.name) is off. Its tools are gone from chat and from Claude.")
    default:
        fail("unknown integrations command \(sub)", hint: "Use list, show ID, enable ID or disable ID.", code: 2)
    }
}

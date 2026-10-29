import Foundation
import AFMKit
import AFMJev

let jevHelp = """
\(bold("afm jev")) — Jev, TypeSafe's decision model. Typed questions in, probabilities out. Calls are billed to your TypeSafe account.

  afm jev status                          Key, connection, model and spending so far
  afm jev key set | show | rm             API key in the Keychain (set reads stdin or asks, hidden)
  afm jev models                          Models your key can use
  afm jev model [NAME]                    Show or set the model (jev-latest, or pin e.g. jev-1.13.0)
  afm jev usage [reset]                   Calls, input tokens and estimated cost from this Mac

  afm jev ask "QUESTION" [TEXT]           True or false: the probability the statement is true
  afm jev choose "QUESTION" --option NAME[=WHEN] --option ... [TEXT]
  afm jev score "QUESTION" --level "LEVEL 0" --level "LEVEL 1" ... [TEXT]
  afm jev run QUESTIONS.json [TEXT]       Several questions at once, in TypeSafe's JSON format

  TEXT can also come from -f FILE or stdin. Add --json for the raw answer, --model NAME for one call.

  echo "WIN A FREE IPHONE, click my profile" | afm jev ask "This YouTube comment is spam"
  git log -1 --format=%B | afm jev choose "What kind of change is this commit?" --option feat --option fix --option docs --option chore
"""

func jevArgs(_ args: inout [String], _ flag: String) -> [String] {
    var values: [String] = []
    while let i = args.firstIndex(of: flag), i + 1 < args.count {
        values.append(args[i + 1])
        args.removeSubrange(i...(i + 1))
    }
    return values
}

func cmdJev(_ a: Args) async {
    var args = a.positionals
    let model = jevArgs(&args, "--model").last
    let options = jevArgs(&args, "--option")
    let levels = jevArgs(&args, "--level")
    let sub = args.isEmpty ? "help" : args.removeFirst()

    func state() -> String {
        let s = gatherInput(a, positionals: args)
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("give Jev some text to decide about", hint: "Pass it as an argument, with -f FILE or on stdin.", code: 2) }
        return s
    }
    func question() -> String {
        guard !args.isEmpty else { fail("give the question first, in quotes", hint: "Run `afm jev help`.", code: 2) }
        return args.removeFirst()
    }
    func decide(_ qs: [(String, [String: Any])]) async throws {
        let text = state()
        let r = try await JevClient.make().decide(state: text, questions: qs, model: model ?? JevSettings.load().model)
        if a.json { out(JSONSchemaConverter.jsonText(r.json)); return }
        out(r.text)
    }

    do {
        switch sub {
        case "help": out(jevHelp)

        case "key":
            switch args.first ?? "show" {
            case "set":
                try JevAuth.save(readSecret("TypeSafe API key (input hidden): "))
                out(good("✓ Saved to the macOS Keychain.") + dim(" Turn Jev on with `afm integrations enable jev` if it isn't already."))
            case "rm", "delete": JevAuth.delete(); out("Removed from the Keychain.")
            default:
                let r = JevAuth.resolve()
                out(r.key.map { "Using \(JevAuth.sourceDescription): \(KeychainSecret.masked($0))" } ?? warn("No key.") + dim(" Run `afm jev key set`."))
            }

        case "status":
            let on = IntegrationRegistry.isEnabled(JevIntegration.integrationID)
            out(on ? good("● Jev is on.") : warn("○ Jev is turned off.") + dim(" Run `afm integrations enable jev`."))
            out("Key     " + (JevAuth.resolve().key.map { "\(KeychainSecret.masked($0)) from \(JevAuth.sourceDescription)" } ?? "none"))
            out("Model   " + JevSettings.load().model)
            out("Usage   " + JevUsage.load().summary)
            if on { let st = await JevIntegration().status(); out((st.connected ? good("✓ ") : warn("✗ ")) + st.detail) }

        case "models":
            for m in try await JevClient.make().models() { out(bold(m.name) + dim("  \(m.releaseDate)  ") + m.description) }

        case "model":
            if let name = args.first {
                var s = JevSettings.load(); s.model = name; s.save()
                out(good("✓ Jev calls now use \(name)."))
            } else { out(JevSettings.load().model) }

        case "usage":
            if args.first == "reset" { JevUsage.reset(); out("Tally reset.") ; return }
            let u = JevUsage.load()
            out(u.summary)
            if !u.bySource.isEmpty { out(dim(u.bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))) }
            out(dim(String(format: "Estimated at TypeSafe's list price of $%.3f per million input tokens. Your TypeSafe console has the real bill.", JevUsage.pricePerMillionInput)))

        case "ask":
            let q = question()
            try await decide([("answer", JevQuestion.noul(instructions: q).json)])

        case "choose", "choice":
            let q = question()
            guard options.count >= 2 else { fail("give at least two --option values", hint: #"For example --option bug="Something is broken" --option question"#, code: 2) }
            try await decide([("answer", JevQuestion.choice(instructions: q, options: options.map(JevOption.parse)).json)])

        case "score":
            let q = question()
            guard levels.count >= 2, levels.count <= 10 else { fail("give 2 to 10 --level values, lowest first", code: 2) }
            try await decide([("answer", JevQuestion.score(instructions: q, levels: levels).json)])

        case "run":
            guard !args.isEmpty else { fail("give a questions file", hint: "Run `afm jev help`.", code: 2) }
            let path = args.removeFirst()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(readFileArg(path).utf8)) else { fail("\(path) isn't valid JSON") }
            try await decide(try JevIntegration.questions(from: obj))

        default:
            fail("unknown jev command \(sub)", hint: "Run `afm jev help`.", code: 2)
        }
    } catch { fail(error) }
}

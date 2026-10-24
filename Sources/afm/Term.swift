import Foundation
import AFMKit

// MARK: - Terminal styling

var stdoutTTY: Bool { isatty(1) == 1 }
var stderrTTY: Bool { isatty(2) == 1 }
var useColor: Bool { ProcessInfo.processInfo.environment["NO_COLOR"] == nil }
func paint(_ s: String, _ code: String, tty: Bool = stdoutTTY) -> String { (tty && useColor) ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func dim(_ s: String, tty: Bool = stdoutTTY) -> String { paint(s, "2", tty: tty) }
func bold(_ s: String) -> String { paint(s, "1") }
func accent(_ s: String) -> String { paint(s, "36") }
func good(_ s: String) -> String { paint(s, "32") }
func warn(_ s: String) -> String { paint(s, "33") }
func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func out(_ s: String, terminator: String = "\n") { print(s, terminator: terminator); fflush(stdout) }

func fail(_ msg: String, hint: String? = nil, code: Int32 = 1) -> Never {
    eprint(paint("afm: ", "31;1", tty: stderrTTY) + msg)
    if let hint { eprint(dim("  " + hint, tty: stderrTTY)) }
    exit(code)
}
func fail(_ e: Error) -> Never {
    let a = AFMError.from(e)
    fail(a.message, hint: a.suggestion, code: a.code == "unavailable" || a.code.hasSuffix("NotEnabled") ? 3 : 1)
}


import Foundation

/// Checks History CSV field encoding. With `--emit`, prints one header and one row of hostile values
/// so `scripts/test-audit-recording.sh` can confirm Python's csv reader gets the literal text back.
@main
struct CSVFieldTests {
    /// Values that broke or could break the old escaping: quotes without commas, lone CR, CRLF,
    /// formula-looking text that must stay literal, and Unicode.
    static let samples = [
        "plain",
        "say \"hi\"",
        "a,b",
        "line\nbreak",
        "carriage\rreturn",
        "crlf\r\nend",
        "=SUM(A1:A2)",
        "+1 and -2 @home",
        "Nu șterge raport.csv.",
        "",
    ]

    static func main() {
        if CommandLine.arguments.contains("--emit") {
            print(samples.indices.map { "c\($0)" }.joined(separator: ","))
            print(samples.map(CSVField.escape).joined(separator: ","))
            return
        }

        var failures = 0
        func expect(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures += 1 }
        }

        expect(CSVField.escape("plain") == "plain", "Plain text stays unquoted")
        expect(CSVField.escape("say \"hi\"") == "\"say \"\"hi\"\"\"", "A quote alone forces quoting and doubles quotes")
        expect(CSVField.escape("carriage\rreturn") == "\"carriage\rreturn\"", "A lone CR forces quoting")
        expect(CSVField.escape("crlf\r\nend") == "\"crlf\r\nend\"", "CRLF forces quoting")
        expect(CSVField.escape("=SUM(A1:A2)") == "=SUM(A1:A2)", "Formula-looking text stays literal")
        expect(CSVField.escape("") == "", "Empty text stays empty")

        if failures > 0 { exit(1) }
    }
}

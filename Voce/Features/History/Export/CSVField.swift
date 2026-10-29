import Foundation

/// RFC 4180 field encoding for History exports.
///
/// Text stays literal: a transcript that starts with `=`, `+`, `-` or `@` is written unchanged, because
/// the benchmark scorer compares exported transcripts exactly. Spreadsheet apps may evaluate such a
/// cell as a formula, so open untrusted exports with formulas disabled or import them as text.
enum CSVField {
    /// Quotes a field when it contains a quote, comma, CR or LF, doubling any embedded quotes.
    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "\"" || $0 == "," || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

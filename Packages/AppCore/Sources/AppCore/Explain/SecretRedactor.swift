import Foundation

/// Removes secrets from text before it goes to a language model: the values
/// of the container's own environment variables, and patterns for secret-like
/// text (secret-named key=value pairs, URL passwords, bearer tokens, JWTs,
/// cloud keys, private key blocks, long random tokens).
public struct SecretRedactor: Sendable {
    /// The literal values to remove, longest first, with their variable names.
    private let knownValues: [(value: String, name: String)]

    public static let placeholder = "[REDACTED]"

    /// - Parameter environment: `NAME=value` entries of the container. Values
    ///   of secret-named variables are always removed; other values only when
    ///   they look like random tokens.
    public init(environment: [String] = []) {
        var values: [(String, String)] = []
        for entry in environment {
            let (name, value) = Self.split(entry)
            guard let value, !value.isEmpty else { continue }
            if Self.isSecretName(name) ? value.count >= 3 : Self.looksRandom(value) {
                values.append((value, name))
            }
        }
        knownValues = values.sorted { $0.0.count > $1.0.count }
    }

    /// The variable names of `NAME=value` entries, in order, without values.
    public static func names(of environment: [String]) -> [String] {
        environment.map { split($0).name }.filter { !$0.isEmpty }
    }

    /// Whether a variable or key name usually holds a secret.
    public static func isSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return secretNameParts.contains { upper.contains($0) }
    }

    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (value, name) in knownValues where result.contains(value) {
            result = result.replacingOccurrences(of: value, with: "[REDACTED:\(name)]")
        }
        for rule in Self.rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    public func redact(_ lines: [String]) -> [String] {
        lines.map(redact)
    }

    // MARK: - Rules

    private static let secretNameParts = [
        "PASSWORD", "PASSWD", "PASSPHRASE", "SECRET", "TOKEN", "APIKEY", "API_KEY",
        "ACCESS_KEY", "PRIVATE_KEY", "CREDENTIAL", "AUTH", "SESSION_KEY", "SIGNING_KEY",
        "ENCRYPTION_KEY", "MASTER_KEY", "DSN", "CONNECTION_STRING", "PWD", "COOKIE"
    ]

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> Rule {
            // The patterns are constants, so a failure here is a programming error.
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template)
        }
        let r = placeholder
        return [
            rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, r),
            rule(#"\b([a-z][a-z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@"#, "$1$2:\(r)@", .caseInsensitive),
            rule(#"\b(bearer|basic|token)(\s+)[A-Za-z0-9._~+/\-]{8,}=*"#, "$1$2\(r)", .caseInsensitive),
            rule(#"(--?(?:password|passwd|pass|token|secret|api-key|apikey|key)(?:=|\s+))("[^"]*"|'[^']*'|\S+)"#, "$1\(r)", .caseInsensitive),
            rule(#"(\b[\w.\-]*(?:password|passwd|pwd|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|credential|auth)[\w.\-]*"?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;}&]+)"#, "$1\(r)", .caseInsensitive),
            rule(#"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#, r),
            rule(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, r),
            rule(#"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b"#, r),
            rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, r),
            rule(#"\bsk-[A-Za-z0-9_\-]{20,}"#, r),
            rule(#"\bAIza[0-9A-Za-z_\-]{35}\b"#, r),
            rule(#"(?<![A-Za-z0-9+/_\-:])(?=[A-Za-z0-9+/_\-]*[0-9])(?=[A-Za-z0-9+/_\-]*[a-z])(?=[A-Za-z0-9+/_\-]*[A-Z])[A-Za-z0-9+/_\-]{32,}={0,2}"#, r)
        ]
    }()

    // MARK: - Helpers

    private static func split(_ entry: String) -> (name: String, value: String?) {
        guard let eq = entry.firstIndex(of: "=") else { return (entry, nil) }
        return (String(entry[..<eq]), String(entry[entry.index(after: eq)...]))
    }

    /// A value of 16+ characters with letters and digits and no spaces or
    /// slashes: an API key or a token, not a path or a word.
    static func looksRandom(_ value: String) -> Bool {
        guard value.count >= 16, !value.contains(" "), !value.contains("/") else { return false }
        let hasDigit = value.contains { $0.isNumber }
        let hasLetter = value.contains { $0.isLetter }
        return hasDigit && hasLetter
    }
}

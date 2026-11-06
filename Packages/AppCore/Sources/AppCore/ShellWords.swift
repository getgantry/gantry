import Foundation

/// POSIX-shell-like word splitting for command fields: `nginx -g 'daemon off;'`
/// becomes `["nginx", "-g", "daemon off;"]`. Handles single quotes, double
/// quotes and backslash escapes. No expansion: `$HOME` and globs stay literal,
/// because the words go to the container runtime, not to a shell.
public enum ShellWords {
    public enum ParseError: Error, Equatable, LocalizedError {
        case unterminatedSingleQuote
        case unterminatedDoubleQuote
        case trailingBackslash

        public var errorDescription: String? {
            switch self {
            case .unterminatedSingleQuote:
                String(localized: "The command has a single quote (') without a closing quote.", bundle: .module)
            case .unterminatedDoubleQuote:
                String(localized: "The command has a double quote (\") without a closing quote.", bundle: .module)
            case .trailingBackslash:
                String(localized: "The command ends with a backslash (\\).", bundle: .module)
            }
        }
    }

    /// Splits `text` into words. Throws on an unterminated quote or a final
    /// backslash, so the caller can show an inline error.
    public static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        // True once the current word has started, so `''` gives an empty word.
        var inWord = false
        var iterator = Array(text).makeIterator()

        while let char = iterator.next() {
            switch char {
            case " ", "\t", "\n", "\r":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            case "\\":
                guard let next = iterator.next() else { throw ParseError.trailingBackslash }
                // Backslash-newline is a line continuation: both go away.
                if next != "\n" {
                    current.append(next)
                    inWord = true
                }
            case "'":
                inWord = true
                var closed = false
                while let inner = iterator.next() {
                    if inner == "'" { closed = true; break }
                    current.append(inner)
                }
                if !closed { throw ParseError.unterminatedSingleQuote }
            case "\"":
                inWord = true
                try readDoubleQuoted(&iterator, into: &current)
            default:
                current.append(char)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Reads up to the closing `"`. Inside double quotes a backslash escapes
    /// only `$`, `` ` ``, `"`, `\` and a newline; before any other character
    /// it stays literal.
    private static func readDoubleQuoted(
        _ iterator: inout IndexingIterator<[Character]>,
        into current: inout String
    ) throws {
        while let inner = iterator.next() {
            switch inner {
            case "\"":
                return
            case "\\":
                guard let next = iterator.next() else { throw ParseError.unterminatedDoubleQuote }
                switch next {
                case "$", "`", "\"", "\\": current.append(next)
                case "\n": break
                default:
                    current.append("\\")
                    current.append(next)
                }
            default:
                current.append(inner)
            }
        }
        throw ParseError.unterminatedDoubleQuote
    }
}

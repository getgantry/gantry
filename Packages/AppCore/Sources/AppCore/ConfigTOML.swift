import Foundation

/// A TOML parse or edit failure for `config.toml`.
public enum ConfigTOMLError: Error, LocalizedError, Sendable, Equatable {
    /// The text is not valid TOML.
    case syntax(line: Int, message: String)
    /// The edit cannot be done without changing other parts of the file.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .syntax(let line, let message):
            "config.toml is not valid TOML (line \(line): \(message)). Fix the file by hand, then try again."
        case .unsupported(let message):
            message
        }
    }
}

/// A parsed TOML value.
indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    /// A date, time or date-time, kept as its literal.
    case datetime(String)
    case array([TOMLValue])
    case table([String: TOMLValue])

    static func == (lhs: TOMLValue, rhs: TOMLValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.integer(a), .integer(b)): a == b
        case let (.float(a), .float(b)): a == b || (a.isNaN && b.isNaN)
        case let (.bool(a), .bool(b)): a == b
        case let (.datetime(a), .datetime(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.table(a), .table(b)): a == b
        default: false
        }
    }

    /// The value as a Foundation object for `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .string(let value), .datetime(let value): value
        case .integer(let value): value
        case .float(let value): value
        case .bool(let value): value
        case .array(let values): values.map(\.foundationObject)
        case .table(let table): table.mapValues(\.foundationObject)
        }
    }
}

/// A TOML 1.0 reader that keeps the byte range of each key/value pair, so an
/// edit can change one value and keep every other byte of the file.
struct ConfigTOMLDocument {
    /// One `key = value` pair.
    struct Entry {
        /// The full key path, from the root table.
        var path: [String]
        var value: TOMLValue
        /// The bytes of the value literal.
        var valueRange: Range<Int>
        /// The physical lines of the pair, with the line break.
        var lineRange: Range<Int>
        /// The pair is inside an inline table (`a = { b = 1 }`).
        var inInlineTable: Bool
        /// The pair is under an array of tables (`[[a]]`).
        var inArrayOfTables: Bool
        /// The table block (index into `blocks`) that holds the pair.
        var block: Int
    }

    /// The root table (index 0) or a `[header]` and the lines that follow it.
    struct Block {
        /// The table path; empty for the root.
        var path: [String]
        var isArrayOfTables: Bool
        /// The header line with its line break; nil for the root.
        var headerRange: Range<Int>?
        /// Where a new pair goes: after the last pair, else after the header.
        var insertionPoint: Int
        var hasEntries: Bool
    }

    enum TableKind: Equatable {
        /// Defined by a `[header]`.
        case header
        /// Created as the parent of a header; a header can still define it.
        case implicit
        /// Created by a dotted key in the given block.
        case dotted(block: Int)
        case arrayOfTables(count: Int)
        /// A value, or a table closed by an inline table or an array.
        case value
        case inlineTable
    }

    let bytes: [UInt8]
    private(set) var entries: [Entry] = []
    private(set) var blocks: [Block] = []
    /// Kinds of the canonical paths (array-of-tables elements are marked).
    private(set) var kinds: [[String]: TableKind] = [:]
    /// Uses `\r\n` when the file does.
    var newline: String

    init(_ text: String) throws {
        bytes = Array(text.utf8)
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        var parser = Parser(bytes: bytes)
        try parser.parse(into: &self)
    }

    /// The pairs not under an array of tables, by dotted key, with inline
    /// tables flattened into their keys.
    var flatValues: [String: TOMLValue] {
        var result: [String: TOMLValue] = [:]
        for entry in entries where !entry.inArrayOfTables {
            if case .table = entry.value { continue }
            result[entry.path.joined(separator: ".")] = entry.value
        }
        return result
    }

    /// Every leaf value by canonical path, to compare a file before and after an edit.
    fileprivate var leaves: [[String]: TOMLValue] {
        var result: [[String]: TOMLValue] = [:]
        for entry in canonicalEntries {
            if case .table = entry.value.value { continue }
            result[entry.path] = entry.value.value
        }
        return result
    }

    fileprivate var canonicalEntries: [(path: [String], value: Entry)] = []

    func kind(of path: [String]) -> TableKind? { kinds[path] }

    // MARK: Registration

    fileprivate static let elementMarker = "\u{0}#"

    /// Maps a raw key path to its canonical path: each array of tables on
    /// the way gets the index of its last element.
    fileprivate func canonical(_ path: [String]) -> [String] {
        var result: [String] = []
        for component in path {
            result.append(component)
            if case .arrayOfTables(let count) = kinds[result] {
                result.append(Self.elementMarker + String(count))
            }
        }
        return result
    }

    fileprivate func isSealed(_ path: [String]) -> Bool {
        for length in 1...max(1, path.count) where length <= path.count {
            switch kinds[Array(path.prefix(length))] {
            case .value?, .inlineTable?: return true
            default: continue
            }
        }
        return false
    }

    fileprivate mutating func defineHeader(_ path: [String], array: Bool) throws -> [String] {
        var current: [String] = []
        for (index, component) in path.enumerated() {
            current.append(component)
            let isLast = index == path.count - 1
            switch kinds[current] {
            case nil:
                if isLast {
                    kinds[current] = array ? .arrayOfTables(count: 1) : .header
                } else {
                    kinds[current] = .implicit
                }
            case .implicit?:
                if isLast {
                    guard !array else { throw ParseFailure.semantic("table \(path.joined(separator: ".")) is already defined") }
                    kinds[current] = .header
                }
            case .header?, .dotted?:
                if isLast { throw ParseFailure.semantic("table \(path.joined(separator: ".")) is defined twice") }
            case .arrayOfTables(let count)?:
                if isLast {
                    guard array else { throw ParseFailure.semantic("\(path.joined(separator: ".")) is an array of tables") }
                    kinds[current] = .arrayOfTables(count: count + 1)
                }
            case .value?, .inlineTable?:
                throw ParseFailure.semantic("\(current.joined(separator: ".")) is not a table")
            }
            if case .arrayOfTables(let count)? = kinds[current] {
                current.append(Self.elementMarker + String(count))
            }
        }
        return current
    }

    /// Registers `key` (relative) under the canonical `table`. `inline` is
    /// set while the pairs of an inline table are read.
    fileprivate mutating func defineKey(_ key: [String], in table: [String], block: Int, inline: Bool) throws -> [String] {
        var current = table
        if !inline, isSealed(table) { throw ParseFailure.semantic("cannot add keys to an inline table or array") }
        for component in key.dropLast() {
            current.append(component)
            switch kinds[current] {
            case nil: kinds[current] = .dotted(block: block)
            case .dotted?: break
            default:
                throw ParseFailure.semantic("cannot use dotted key \(key.joined(separator: ".")) here: \(component) is already defined")
            }
        }
        current.append(key[key.count - 1])
        guard kinds[current] == nil else {
            throw ParseFailure.semantic("duplicate key \(key.joined(separator: "."))")
        }
        kinds[current] = .value
        return current
    }

    fileprivate mutating func markInlineTable(_ path: [String]) { kinds[path] = .inlineTable }

    fileprivate mutating func appendBlock(_ block: Block) { blocks.append(block) }

    fileprivate mutating func appendEntry(_ entry: Entry, canonical: [String]) {
        entries.append(entry)
        canonicalEntries.append((canonical, entry))
        if !entry.inInlineTable {
            blocks[entry.block].insertionPoint = entry.lineRange.upperBound
            blocks[entry.block].hasEntries = true
        }
    }

    fileprivate mutating func appendInlineEntry(_ entry: Entry, canonical: [String]) {
        entries.append(entry)
        canonicalEntries.append((canonical, entry))
    }
}

enum ParseFailure: Error {
    case semantic(String)
}

// MARK: - Parser

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var lineStart = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    private var atEnd: Bool { index >= bytes.count }
    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    private func peek(_ offset: Int) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    private func failure(_ message: String, at position: Int? = nil) -> ConfigTOMLError {
        let end = min(position ?? index, bytes.count)
        let line = bytes[..<end].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        return .syntax(line: line, message: message)
    }

    mutating func parse(into document: inout ConfigTOMLDocument) throws {
        document.appendBlock(.init(path: [], isArrayOfTables: false, headerRange: nil, insertionPoint: 0, hasEntries: false))
        var table: [String] = []
        var inArray = false
        while true {
            skipWhitespace()
            guard let byte = current else { break }
            let start = index
            do {
                if byte == UInt8(ascii: "#") {
                    try skipComment()
                    try endOfLine()
                } else if byte == 0x0A || byte == 0x0D {
                    try endOfLine()
                } else if byte == UInt8(ascii: "[") {
                    let header = try parseHeader(into: &document)
                    table = header.table
                    inArray = header.array || table.contains { $0.hasPrefix(ConfigTOMLDocument.elementMarker) }
                } else {
                    try parsePair(into: &document, table: table, inArray: inArray)
                }
            } catch ParseFailure.semantic(let message) {
                throw failure(message, at: start)
            }
        }
        if !document.blocks[0].hasEntries {
            // Root keys go before the first header.
            let firstHeader = document.blocks.dropFirst().first?.headerRange?.lowerBound
            document.setRootInsertion(firstHeader ?? bytes.count)
        }
    }

    // MARK: Lines

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 { index += 1 }
    }

    private mutating func skipComment() throws {
        while let byte = current, byte != 0x0A {
            if byte == 0x0D, peek(1) == 0x0A { break }
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F { throw failure("control character in a comment") }
            index += 1
        }
    }

    /// Consumes a line break, or accepts the end of the file.
    private mutating func endOfLine() throws {
        guard let byte = current else { return }
        if byte == 0x0A {
            index += 1
        } else if byte == 0x0D, peek(1) == 0x0A {
            index += 2
        } else {
            throw failure("expected the end of the line")
        }
        lineStart = index
    }

    /// Whitespace, comments and line breaks inside an array.
    private mutating func skipArrayFiller() throws {
        while true {
            skipWhitespace()
            guard let byte = current else { return }
            if byte == UInt8(ascii: "#") {
                try skipComment()
            } else if byte == 0x0A || (byte == 0x0D && peek(1) == 0x0A) {
                try endOfLine()
            } else {
                return
            }
        }
    }

    // MARK: Headers and pairs

    private mutating func parseHeader(into document: inout ConfigTOMLDocument) throws -> (table: [String], array: Bool) {
        let start = lineStart
        let array = peek(1) == UInt8(ascii: "[")
        index += array ? 2 : 1
        skipWhitespace()
        let key = try parseKey()
        skipWhitespace()
        guard current == UInt8(ascii: "]") else { throw failure("expected ] after the table name") }
        index += 1
        if array {
            guard current == UInt8(ascii: "]") else { throw failure("expected ]] after the table name") }
            index += 1
        }
        skipWhitespace()
        if current == UInt8(ascii: "#") { try skipComment() }
        try endOfLine()
        let table = try document.defineHeader(key, array: array)
        document.appendBlock(.init(
            path: key, isArrayOfTables: array, headerRange: start..<index, insertionPoint: index, hasEntries: false
        ))
        return (table, array)
    }

    private mutating func parsePair(into document: inout ConfigTOMLDocument, table: [String], inArray: Bool) throws {
        let start = lineStart
        let key = try parseKey()
        skipWhitespace()
        guard current == UInt8(ascii: "=") else { throw failure("expected = after the key") }
        index += 1
        skipWhitespace()
        let block = document.blocks.count - 1
        let canonical = try document.defineKey(key, in: table, block: block, inline: false)
        let valueStart = index
        var inline: [(key: [String], canonical: [String], value: TOMLValue, range: Range<Int>)] = []
        let value = try parseValue(document: &document, base: canonical, inlineEntries: &inline)
        let valueEnd = index
        skipWhitespace()
        if current == UInt8(ascii: "#") { try skipComment() }
        try endOfLine()
        let absolute = document.blocks[block].path + key
        document.appendEntry(.init(
            path: absolute, value: value, valueRange: valueStart..<valueEnd, lineRange: start..<index,
            inInlineTable: false, inArrayOfTables: inArray, block: block
        ), canonical: canonical)
        for item in inline {
            document.appendInlineEntry(.init(
                path: absolute + item.key, value: item.value, valueRange: item.range, lineRange: item.range,
                inInlineTable: true, inArrayOfTables: inArray, block: block
            ), canonical: item.canonical)
        }
    }

    // MARK: Keys

    private mutating func parseKey() throws -> [String] {
        var parts = [try parseSimpleKey()]
        while true {
            let save = index
            skipWhitespace()
            guard current == UInt8(ascii: ".") else {
                index = save
                break
            }
            index += 1
            skipWhitespace()
            parts.append(try parseSimpleKey())
        }
        return parts
    }

    private mutating func parseSimpleKey() throws -> String {
        guard let byte = current else { throw failure("expected a key") }
        if byte == UInt8(ascii: "\"") {
            if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") { throw failure("a key cannot be a multi-line string") }
            return try parseBasicString()
        }
        if byte == UInt8(ascii: "'") {
            if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") { throw failure("a key cannot be a multi-line string") }
            return try parseLiteralString()
        }
        let start = index
        while let byte = current, Self.isBareKeyByte(byte) { index += 1 }
        guard index > start else { throw failure("expected a key") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    static func isBareKeyByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }

    // MARK: Values

    private mutating func parseValue(
        document: inout ConfigTOMLDocument,
        base: [String]?,
        inlineEntries: inout [(key: [String], canonical: [String], value: TOMLValue, range: Range<Int>)]
    ) throws -> TOMLValue {
        guard let byte = current else { throw failure("expected a value") }
        switch byte {
        case UInt8(ascii: "\""):
            if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") { return .string(try parseMultilineBasic()) }
            return .string(try parseBasicString())
        case UInt8(ascii: "'"):
            if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") { return .string(try parseMultilineLiteral()) }
            return .string(try parseLiteralString())
        case UInt8(ascii: "["):
            return try parseArray()
        case UInt8(ascii: "{"):
            return try parseInlineTable(document: &document, base: base, entries: &inlineEntries)
        default:
            return try parseScalar()
        }
    }

    private mutating func parseArray() throws -> TOMLValue {
        index += 1
        var values: [TOMLValue] = []
        while true {
            try skipArrayFiller()
            guard let byte = current else { throw failure("unterminated array") }
            if byte == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            var scratch = try ConfigTOMLDocument("")
            var ignored: [(key: [String], canonical: [String], value: TOMLValue, range: Range<Int>)] = []
            values.append(try parseValue(document: &scratch, base: [], inlineEntries: &ignored))
            try skipArrayFiller()
            guard let next = current else { throw failure("unterminated array") }
            if next == UInt8(ascii: ",") {
                index += 1
            } else if next != UInt8(ascii: "]") {
                throw failure("expected , or ] in an array")
            }
        }
    }

    /// Reads `{ k = v, ... }`. The pairs are registered under `base`, so a
    /// later header or key cannot add to the table.
    private mutating func parseInlineTable(
        document: inout ConfigTOMLDocument,
        base: [String]?,
        entries: inout [(key: [String], canonical: [String], value: TOMLValue, range: Range<Int>)]
    ) throws -> TOMLValue {
        index += 1
        let root = base ?? []
        document.markInlineTable(root)
        var table: [String: TOMLValue] = [:]
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return .table([:])
        }
        while true {
            skipWhitespace()
            let key = try parseKey()
            skipWhitespace()
            guard current == UInt8(ascii: "=") else { throw failure("expected = in an inline table") }
            index += 1
            skipWhitespace()
            let canonical: [String]
            do {
                canonical = try document.defineKey(key, in: root, block: document.blocks.count - 1, inline: true)
            } catch ParseFailure.semantic(let message) {
                throw failure(message)
            }
            let start = index
            var nested: [(key: [String], canonical: [String], value: TOMLValue, range: Range<Int>)] = []
            let value = try parseValue(document: &document, base: canonical, inlineEntries: &nested)
            entries.append((key, canonical, value, start..<index))
            entries.append(contentsOf: nested.map { (key + $0.key, $0.canonical, $0.value, $0.range) })
            insert(value, at: key, into: &table)
            skipWhitespace()
            guard let byte = current else { throw failure("unterminated inline table") }
            if byte == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "}") {
                index += 1
                return .table(table)
            }
            throw failure("expected , or } in an inline table")
        }
    }

    private func insert(_ value: TOMLValue, at key: [String], into table: inout [String: TOMLValue]) {
        guard let first = key.first else { return }
        if key.count == 1 {
            table[first] = value
            return
        }
        var child: [String: TOMLValue] = [:]
        if case .table(let existing)? = table[first] { child = existing }
        insert(value, at: Array(key.dropFirst()), into: &child)
        table[first] = .table(child)
    }

    private mutating func parseScalar() throws -> TOMLValue {
        let start = index
        while let byte = current, !Self.isDelimiter(byte) { index += 1 }
        var token = String(decoding: bytes[start..<index], as: UTF8.self)
        // A date and a time can be split by one space.
        if token.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, current == 0x20,
           let next = peek(1), next >= 0x30, next <= 0x39 {
            index += 1
            while let byte = current, !Self.isDelimiter(byte) { index += 1 }
            token = String(decoding: bytes[start..<index], as: UTF8.self)
        }
        guard !token.isEmpty else { throw failure("expected a value") }
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        if let integer = Self.integer(token) { return .integer(integer) }
        if let float = Self.float(token) { return .float(float) }
        if Self.isDateTime(token) { return .datetime(token) }
        throw failure("invalid value \(token)", at: start)
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: ",")
            || byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "#")
    }

    static func integer(_ token: String) -> Int? {
        if token.wholeMatch(of: /[+-]?(0|[1-9](_?[0-9])*)/) != nil {
            return Int(token.replacingOccurrences(of: "_", with: ""))
        }
        if token.wholeMatch(of: /0x[0-9A-Fa-f](_?[0-9A-Fa-f])*/) != nil { return digits(token, radix: 16) }
        if token.wholeMatch(of: /0o[0-7](_?[0-7])*/) != nil { return digits(token, radix: 8) }
        if token.wholeMatch(of: /0b[01](_?[01])*/) != nil { return digits(token, radix: 2) }
        return nil
    }

    private static func digits(_ token: String, radix: Int) -> Int? {
        Int(token.dropFirst(2).replacingOccurrences(of: "_", with: ""), radix: radix)
    }

    static func float(_ token: String) -> Double? {
        switch token {
        case "inf", "+inf": return .infinity
        case "-inf": return -.infinity
        case "nan", "+nan", "-nan": return .nan
        default: break
        }
        let pattern = /[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?/
        guard token.wholeMatch(of: pattern) != nil, token.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) else {
            return nil
        }
        return Double(token.replacingOccurrences(of: "_", with: ""))
    }

    static func isDateTime(_ token: String) -> Bool {
        let date = /\d{4}-\d{2}-\d{2}/
        let time = /\d{2}:\d{2}:\d{2}(\.\d+)?/
        if token.wholeMatch(of: date) != nil || token.wholeMatch(of: time) != nil { return true }
        return token.wholeMatch(of: /\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?/) != nil
    }

    // MARK: Strings

    private mutating func parseBasicString() throws -> String {
        index += 1
        var out: [UInt8] = []
        while true {
            guard let byte = current else { throw failure("unterminated string") }
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") {
                try parseEscape(into: &out)
                continue
            }
            if byte == 0x0A || byte == 0x0D { throw failure("unterminated string") }
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F { throw failure("control character in a string") }
            out.append(byte)
            index += 1
        }
    }

    private mutating func parseLiteralString() throws -> String {
        index += 1
        let start = index
        while true {
            guard let byte = current else { throw failure("unterminated string") }
            if byte == UInt8(ascii: "'") {
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return text
            }
            if byte == 0x0A || byte == 0x0D { throw failure("unterminated string") }
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F { throw failure("control character in a string") }
            index += 1
        }
    }

    private mutating func skipLeadingNewline() {
        if current == 0x0A {
            index += 1
        } else if current == 0x0D, peek(1) == 0x0A {
            index += 2
        }
    }

    /// The number of quotes `quote` at the read position (at most 5).
    private func run(of quote: UInt8) -> Int {
        var count = 0
        while count < 5, peek(count) == quote { count += 1 }
        return count
    }

    private mutating func parseMultilineBasic() throws -> String {
        index += 3
        skipLeadingNewline()
        var out: [UInt8] = []
        let quote = UInt8(ascii: "\"")
        while true {
            guard let byte = current else { throw failure("unterminated multi-line string") }
            if byte == quote {
                let count = run(of: quote)
                if count >= 3 {
                    out.append(contentsOf: Array(repeating: quote, count: count - 3))
                    index += count
                    return String(decoding: out, as: UTF8.self)
                }
                out.append(contentsOf: Array(repeating: quote, count: count))
                index += count
                continue
            }
            if byte == UInt8(ascii: "\\") {
                // A backslash at the end of a line trims the line break and
                // the whitespace after it.
                var probe = index + 1
                while probe < bytes.count, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
                if probe < bytes.count, bytes[probe] == 0x0A || (bytes[probe] == 0x0D && probe + 1 < bytes.count && bytes[probe + 1] == 0x0A) {
                    index = probe
                    while let next = current, next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D { index += 1 }
                    continue
                }
                try parseEscape(into: &out)
                continue
            }
            if byte == 0x0D {
                guard peek(1) == 0x0A else { throw failure("bare carriage return in a string") }
                out.append(contentsOf: [0x0D, 0x0A])
                index += 2
                continue
            }
            if (byte < 0x20 && byte != 0x09 && byte != 0x0A) || byte == 0x7F { throw failure("control character in a string") }
            out.append(byte)
            index += 1
        }
    }

    private mutating func parseMultilineLiteral() throws -> String {
        index += 3
        skipLeadingNewline()
        var out: [UInt8] = []
        let quote = UInt8(ascii: "'")
        while true {
            guard let byte = current else { throw failure("unterminated multi-line string") }
            if byte == quote {
                let count = run(of: quote)
                if count >= 3 {
                    out.append(contentsOf: Array(repeating: quote, count: count - 3))
                    index += count
                    return String(decoding: out, as: UTF8.self)
                }
                out.append(contentsOf: Array(repeating: quote, count: count))
                index += count
                continue
            }
            if byte == 0x0D, peek(1) != 0x0A { throw failure("bare carriage return in a string") }
            if (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) || byte == 0x7F {
                throw failure("control character in a string")
            }
            out.append(byte)
            index += 1
        }
    }

    private mutating func parseEscape(into out: inout [UInt8]) throws {
        index += 1
        guard let byte = current else { throw failure("unterminated string") }
        index += 1
        let simple: [UInt8: UInt8] = [
            UInt8(ascii: "b"): 0x08, UInt8(ascii: "t"): 0x09, UInt8(ascii: "n"): 0x0A, UInt8(ascii: "f"): 0x0C,
            UInt8(ascii: "r"): 0x0D, UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C
        ]
        if let mapped = simple[byte] {
            out.append(mapped)
            return
        }
        guard byte == UInt8(ascii: "u") || byte == UInt8(ascii: "U") else { throw failure("invalid escape in a string") }
        let count = byte == UInt8(ascii: "u") ? 4 : 8
        guard index + count <= bytes.count,
              let code = UInt32(String(decoding: bytes[index..<index + count], as: UTF8.self), radix: 16),
              let scalar = Unicode.Scalar(code) else {
            throw failure("invalid unicode escape in a string")
        }
        index += count
        out.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
}

extension ConfigTOMLDocument {
    fileprivate mutating func setRootInsertion(_ offset: Int) {
        blocks[0].insertionPoint = offset
    }

    // MARK: Editing

    /// Returns `text` with the value at `path` replaced by the TOML literal
    /// `literal`, added, or removed (nil). Every other byte stays as it was.
    /// Throws when the file does not parse or the edit is not safe.
    static func edit(_ text: String, path: [String], literal: String?) throws -> String {
        guard !path.isEmpty else { throw ConfigTOMLError.unsupported("The key is empty.") }
        let document = try ConfigTOMLDocument(text)
        let display = path.joined(separator: ".")
        var newValue: TOMLValue?
        if let literal {
            guard !literal.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                throw ConfigTOMLError.unsupported("A value cannot contain line breaks.")
            }
            let probe = try? ConfigTOMLDocument("v = " + literal)
            guard let probe, probe.entries.count == 1, probe.blocks.count == 1,
                  probe.entries[0].valueRange == 4..<probe.bytes.count,
                  let value = probe.entries.first?.value else {
                throw ConfigTOMLError.unsupported("The value for \(display) is not a valid TOML value.")
            }
            newValue = value
        }
        let result = try document.applying(path: path, display: display, literal: literal)
        try verify(old: document, newText: result, path: path, value: newValue)
        return result
    }

    private func applying(path: [String], display: String, literal: String?) throws -> String {
        var output = bytes
        if let entry = entries.first(where: { $0.path == path && !$0.inArrayOfTables }) {
            if let literal {
                switch entry.value {
                case .array, .table, .datetime:
                    throw ConfigTOMLError.unsupported("\(display) holds an array, a table or a date in config.toml. Edit it by hand.")
                default: break
                }
                output.replaceSubrange(entry.valueRange, with: Array(literal.utf8))
            } else {
                guard !entry.inInlineTable else {
                    throw ConfigTOMLError.unsupported("\(display) is inside an inline table in config.toml. Edit it by hand.")
                }
                output.removeSubrange(entry.lineRange)
            }
            return String(decoding: output, as: UTF8.self)
        }
        guard let literal else { return String(decoding: bytes, as: UTF8.self) }
        if path.indices.contains(where: { index in
            if case .arrayOfTables = kinds[Array(path.prefix(index + 1))] { return true }
            return false
        }) {
            throw ConfigTOMLError.unsupported("\(display) is under an array of tables in config.toml. Edit it by hand.")
        }
        for length in 1..<path.count {
            switch kinds[Array(path.prefix(length))] {
            case .value?, .inlineTable?:
                throw ConfigTOMLError.unsupported(
                    "\(path.prefix(length).joined(separator: ".")) is not a table in config.toml, so \(display) cannot be added. Edit it by hand."
                )
            default: continue
            }
        }
        if kinds[path] != nil {
            throw ConfigTOMLError.unsupported("\(display) is a table in config.toml, not a value.")
        }
        let section = Array(path.dropLast())
        let name = ConfigTOMLDocument.key([path[path.count - 1]])
        if section.isEmpty {
            return inserted("\(name) = \(literal)", at: blocks[0].insertionPoint)
        }
        switch kinds[section] {
        case .header?:
            guard let block = blocks.firstIndex(where: { $0.path == section && !$0.isArrayOfTables && $0.headerRange != nil }) else {
                throw ConfigTOMLError.unsupported("Could not find the [\(section.joined(separator: "."))] table in config.toml.")
            }
            return inserted("\(name) = \(literal)", at: blocks[block].insertionPoint)
        case .dotted(let block)?:
            guard blocks[block].path.count < path.count, Array(path.prefix(blocks[block].path.count)) == blocks[block].path else {
                throw ConfigTOMLError.unsupported("Could not place \(display) in config.toml. Edit it by hand.")
            }
            let relative = Array(path.dropFirst(blocks[block].path.count))
            return inserted("\(ConfigTOMLDocument.key(relative)) = \(literal)", at: blocks[block].insertionPoint)
        case nil, .implicit?:
            return appendedTable(section, line: "\(name) = \(literal)")
        default:
            throw ConfigTOMLError.unsupported("\(section.joined(separator: ".")) is not a table in config.toml.")
        }
    }

    /// Inserts a line at a line start (or at the end of the file).
    private func inserted(_ line: String, at offset: Int) -> String {
        var output = bytes
        let atEnd = offset >= bytes.count
        let endsWithBreak = bytes.last == 0x0A
        let text: String
        if atEnd, !bytes.isEmpty, !endsWithBreak {
            text = newline + line
        } else {
            text = line + newline
        }
        output.insert(contentsOf: Array(text.utf8), at: min(offset, bytes.count))
        return String(decoding: output, as: UTF8.self)
    }

    private func appendedTable(_ section: [String], line: String) -> String {
        var output = bytes
        let breakBytes = Array(newline.utf8)
        if !output.isEmpty {
            if output.last != 0x0A { output += breakBytes }
            // Start the table after a blank line.
            let body = output.dropLast(output.count >= 2 && output[output.count - 2] == 0x0D ? 2 : 1)
            let lastLine = body.split(separator: 0x0A, omittingEmptySubsequences: false).last ?? []
            if lastLine.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) { output += breakBytes }
        }
        output += Array(("[\(ConfigTOMLDocument.key(section))]" + newline + line + newline).utf8)
        return String(decoding: output, as: UTF8.self)
    }

    /// A dotted key with each part bare when it can be, else quoted.
    static func key(_ parts: [String]) -> String {
        parts.map { part in
            part.utf8.allSatisfy(Parser.isBareKeyByte) && !part.isEmpty ? part : AppleContainerControl.tomlQuoted(part)
        }.joined(separator: ".")
    }

    /// The new text must parse, and its values must equal the old ones with
    /// only `path` changed.
    private static func verify(old: ConfigTOMLDocument, newText: String, path: [String], value: TOMLValue?) throws {
        let updated: ConfigTOMLDocument
        do {
            updated = try ConfigTOMLDocument(newText)
        } catch {
            throw ConfigTOMLError.unsupported("Gantry could not change \(path.joined(separator: ".")) safely in config.toml, so the file was not written. Edit it by hand.")
        }
        var expected = old.leaves.filter { $0.key.count < path.count || Array($0.key.prefix(path.count)) != path }
        if let value {
            if case .table = value {} else { expected[path] = value }
        }
        guard updated.leaves == expected else {
            throw ConfigTOMLError.unsupported("Gantry could not change \(path.joined(separator: ".")) safely in config.toml, so the file was not written. Edit it by hand.")
        }
    }
}

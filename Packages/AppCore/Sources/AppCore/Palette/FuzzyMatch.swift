import Foundation

/// Fuzzy subsequence matching for the command palette. Every query character
/// must occur in the text in order; the score rewards prefixes, word starts
/// and runs of adjacent characters, and charges for gaps.
public enum FuzzyMatch {
    /// The score of `query` in `text`, or nil when the query does not match.
    /// Matching ignores case and diacritics. An empty query matches with 0.
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(fold(query))
        let haystack = Array(fold(text))
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }

        let original = Array(text)
        var best: Int?
        // Try each start position of the first character and keep the best
        // greedy alignment: a later start can land on a word boundary.
        for start in haystack.indices where haystack[start] == needle[0] {
            guard let value = align(needle, haystack, original, from: start) else { break }
            best = max(best ?? value, value)
        }
        guard var total = best else { return nil }

        let foldedText = String(haystack)
        let foldedQuery = String(needle)
        if foldedText == foldedQuery {
            total += 100
        } else if foldedText.hasPrefix(foldedQuery) {
            total += 50
        } else if foldedText.contains(foldedQuery) {
            total += 25
        }
        return total
    }

    /// The best score of `query` over several texts, or nil if none match.
    public static func bestScore(_ query: String, in texts: [String]) -> Int? {
        texts.compactMap { score(query, in: $0) }.max()
    }

    private static func align(
        _ needle: [Character], _ haystack: [Character], _ original: [Character], from start: Int
    ) -> Int? {
        var score = 0
        var index = start
        var previous: Int?
        for character in needle {
            while index < haystack.count, haystack[index] != character { index += 1 }
            guard index < haystack.count else { return nil }
            score += 1
            if index == 0 {
                score += 10
            } else if isBoundary(original, at: index) {
                score += 7
            }
            if let previous {
                if index == previous + 1 {
                    score += 5
                } else {
                    score -= min(index - previous - 1, 5)
                }
            } else {
                score -= min(index, 5)
            }
            previous = index
            index += 1
        }
        return score
    }

    /// A word starts after a separator or at a lower-to-upper case change.
    private static func isBoundary(_ text: [Character], at index: Int) -> Bool {
        guard index > 0, index < text.count else { return index == 0 }
        let before = text[index - 1]
        if " -_./:@".contains(before) { return true }
        return before.isLowercase && text[index].isUppercase
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

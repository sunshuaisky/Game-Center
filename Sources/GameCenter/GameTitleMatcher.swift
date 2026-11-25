import Foundation

enum GameTitleMatcher {
    static func normalize(_ value: String) -> String {
        var title = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        title = title.replacingOccurrences(of: #"\([^)]*\)|\[[^]]*\]"#, with: " ", options: .regularExpression)
        title = title.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? title
        title = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let ignored: Set<String> = ["the", "a", "an", "version", "edition", "game", "gba", "nds"]
        return title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignored.contains($0) }.joined(separator: " ")
    }
    static func hasHan(_ title: String) -> Bool {
        title.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value) }
    }
    static func score(_ source: String, _ candidate: String) -> Double {
        let left = normalize(source), right = normalize(candidate)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if hasHan(left) && hasHan(right) {
            // Chinese words are not separated by spaces. Compare character
            // pairs after simplifying, with length coverage to reject another
            // instalment sharing only its franchise name.
            let a = Array(left.filter { !$0.isWhitespace }), b = Array(right.filter { !$0.isWhitespace })
            if a == b { return 1 }
            guard min(a.count, b.count) >= 3 else { return 0 }
            func pairs(_ text: [Character]) -> Set<String> { Set(zip(text, text.dropFirst()).map { String([$0, $1]) }) }
            let x = pairs(a), y = pairs(b)
            return Double(x.intersection(y).count) / Double(max(x.count, y.count))
        }
        let a = left.split(separator: " ").map(String.init), b = right.split(separator: " ").map(String.init)
        guard a.count > 1, b.count > 1 else { return 0 }
        let x = Set(a), y = Set(b)
        return min(1, Double(x.intersection(y).count) / Double(max(x.count, y.count))
                   + (left.contains(right) || right.contains(left) ? 0.16 : 0) + (a.first == b.first ? 0.08 : 0))
    }
    static func threshold(_ title: String, wikipedia: Bool = false) -> Double {
        if hasHan(title) { return wikipedia ? 0.72 : 0.70 }
        return normalize(title).split(separator: " ").count < 2 ? 1 : wikipedia ? 0.68 : 0.57
    }
}

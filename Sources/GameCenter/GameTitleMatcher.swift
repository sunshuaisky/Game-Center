import Foundation

enum GameTitleMatcher {
    private static let knownExtensionRegex = try! NSRegularExpression(
        pattern: #"(?i)\.(gba|gb|gbc|nds|3ds|3dsx|cci|cxi|cia|iso|cso|pbp|chd|nes|unf|unif|fds|sfc|smc|fig|swc|n64|v64|z64|ndd|gen|md|smd|cue|ccd|img|m3u|bin|app|nsp|xci|nsz|xcz|nup|nro|nso|nca|vpk|zip|gcm|rvz|gcz|ciso|tgc|dol|elf|wbfs|wad|wua|wux|wud|rpx|wuhb|gdi|cdi|a26|col|rom|msx|cas|pce|sgx|sms|ms|gg|32x|sg|sg1000|sc|ws|wsc|ngp|ngpc|ng|pc2|pcv2|myv|tap|tzx|wav|mmi|gz|gcimport)$"#
    )
    private static let bracketRegex = try! NSRegularExpression(pattern: #"\([^)]*\)|\[[^\]]*\]|（[^）]*）|【[^】]*】"#)
    private static let simplifiedTransform = StringTransform("Traditional-Simplified")
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let ignoredWords: Set<String> = ["the", "a", "an", "version", "edition", "game", "gba", "nds"]

    /// Regional Chinese franchise/subtitle canonicalizations so mainland, HK, and TW
    /// game names match cleanly without losing instalment specificity.
    private static let chineseCanonicalReplacements: [(String, String)] = [
        ("精灵宝可梦", "宝可梦"),
        ("口袋妖怪", "宝可梦"),
        ("宠物小精灵", "宝可梦"),
        ("神奇宝贝", "宝可梦"),
        ("萨尔达传说", "塞尔达传说"),
        ("荒野之息", "旷野之息"),
        ("马里奥", "马力欧"),
        ("玛利欧", "马力欧"),
        ("动物之森", "动物森友会"),
        ("喷射战士", "斯普拉遁"),
        ("恶灵古堡", "生化危机"),
        ("魔物猎人", "怪物猎人"),
        ("异度之刃", "异度神剑"),
        ("太空战士", "最终幻想"),
        ("数码暴龙", "数码宝贝"),
        ("美国末日", "最后生还者"),
        ("秘境探险", "神秘海域"),
        ("对马战鬼", "对马岛之魂"),
        ("黑帝斯", "哈迪斯"),
        ("火焰之纹章", "火焰纹章"),
        ("格斗天王", "拳皇"),
        ("潜龙谍影", "合金装备"),
        ("古墓奇兵", "古墓丽影")
    ]

    static func normalize(_ value: String) -> String {
        var title = value.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "" }
        if title.hasPrefix("/") || title.hasPrefix("~/") {
            title = (title as NSString).lastPathComponent
        }
        let extRange = NSRange(location: 0, length: (title as NSString).length)
        title = knownExtensionRegex.stringByReplacingMatches(in: title, range: extRange, withTemplate: "")
        let brRange = NSRange(location: 0, length: (title as NSString).length)
        title = bracketRegex.stringByReplacingMatches(in: title, range: brRange, withTemplate: " ")
        if hasHan(title) {
            title = title.applyingTransform(simplifiedTransform, reverse: false) ?? title
            for (variant, canonical) in chineseCanonicalReplacements {
                if title.contains(variant) {
                    title = title.replacingOccurrences(of: variant, with: canonical)
                }
            }
        }
        title = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
        return title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignoredWords.contains($0) }.joined(separator: " ")
    }

    static func hasHan(_ title: String) -> Bool {
        title.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value) }
    }

    static func hasKana(_ title: String) -> Bool {
        title.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
    }

    static func score(_ source: String, _ candidate: String) -> Double {
        scoreNormalized(normalize(source), normalize(candidate))
    }

    static func scoreNormalized(_ left: String, _ right: String) -> Double {
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
        if hasKana(left) && hasKana(right) {
            let a = Array(left.filter { !$0.isWhitespace }), b = Array(right.filter { !$0.isWhitespace })
            if a == b { return 1 }
            guard min(a.count, b.count) >= 3 else { return 0 }
            func pairs(_ text: [Character]) -> Set<String> { Set(zip(text, text.dropFirst()).map { String([$0, $1]) }) }
            let x = pairs(a), y = pairs(b)
            return Double(x.intersection(y).count) / Double(max(x.count, y.count))
        }
        let a = left.split(separator: " "), b = right.split(separator: " ")
        guard a.count > 1, b.count > 1 else { return 0 }
        let x = Set(a), y = Set(b)
        let leftPadded = " \(left) ", rightPadded = " \(right) "
        let wordContained = leftPadded.contains(rightPadded) || rightPadded.contains(leftPadded)
        return min(1, Double(x.intersection(y).count) / Double(max(x.count, y.count))
                   + (wordContained ? 0.16 : 0) + (a.first == b.first ? 0.08 : 0))
    }

    static func threshold(_ title: String, wikipedia: Bool = false) -> Double {
        if hasHan(title) || hasKana(title) { return wikipedia ? 0.72 : 0.70 }
        return normalize(title).split(separator: " ").count < 2 ? 1 : wikipedia ? 0.68 : 0.57
    }
}

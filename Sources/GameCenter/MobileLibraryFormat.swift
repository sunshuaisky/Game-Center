import Foundation

enum MobileLibraryFormat {
    struct Platform: Codable, Identifiable {
        let id: String
        let folder: String
        let name: String
        let extensions: [String]
        let module: String
        let source: URL
        var runtimeNote: String? = nil
        var runtime: String? = nil
    }

    struct SwitchEntry: Codable, Identifiable {
        let id: String
        let title: String
        let titleID: String?
    }

    enum Engine: String, Codable, CaseIterable, Identifiable {
        case s2arm = "S2Arm"
        case nxnative = "NXNative"
        var id: String { rawValue }
    }

    struct SwitchBuild: Codable {
        var schema = 1
        let titleID: String
        let title: String
        let engine: Engine

        var executable: String {
            switch engine {
            case .s2arm: "S2AImages-\(titleID).dylib"
            case .nxnative: "DmGame\(titleID).framework"
            }
        }

        var image: String { engine == .s2arm ? "game.img" : "romfs.img" }
    }

    static let library = "GameLibrary"
    static let catalog = "catalog.json"

    static func sfoString(_ key: String, at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count >= 20, data.count <= 1_048_576,
              Array(data.prefix(4)) == [0, 80, 83, 70] else { return nil }
        func number(_ offset: Int, _ count: Int) -> Int {
            guard offset >= 0, offset + count <= data.count else { return -1 }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        let keys = number(8, 4), values = number(12, 4), count = number(16, 4)
        guard count >= 0, count <= (data.count - 20) / 16 else { return nil }
        for entry in 0..<count {
            let index = 20 + entry * 16
            let start = keys + number(index, 2)
            guard start >= 0, start < data.count, let end = data[start...].firstIndex(of: 0),
                  String(data: data[start..<end], encoding: .utf8) == key else { continue }
            let offset = values + number(index + 12, 4), length = number(index + 4, 4)
            guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { return nil }
            return String(data: data[offset..<(offset + length)].prefix { $0 != 0 }, encoding: .utf8)
        }
        return nil
    }

    static func isVitaGameFolder(_ url: URL) -> Bool {
        let sfo = url.appendingPathComponent("sce_sys/param.sfo")
        guard FileManager.default.fileExists(atPath: sfo.path) else { return false }
        return !["gp", "ac"].contains(sfoString("CATEGORY", at: sfo) ?? "")
    }

    private static let cueFileRegex = try! NSRegularExpression(pattern: #"(?im)^\s*FILE\s+(?:"([^"]+)"|(\S+))\s+\S+"#)

    /// Disc descriptors and playlists own their referenced files in the library.
    static func playableEntries(_ urls: [URL]) -> [URL] {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        var referenced = Set<String>()
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "ccd" {
                let image = url.deletingPathExtension().appendingPathExtension("img")
                if paths.contains(image.standardizedFileURL.path) { referenced.insert(image.standardizedFileURL.path) }
                continue
            }
            guard ["cue", "m3u"].contains(ext),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let names: [String]
            if ext == "cue" {
                let ns = text as NSString
                names = cueFileRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
                    let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                    return ns.substring(with: range)
                }
            } else {
                names = text.components(separatedBy: .newlines).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
                }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            }
            for name in names {
                let path = url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.path
                if path != url.standardizedFileURL.path, paths.contains(path) { referenced.insert(path) }
            }
        }
        return urls.filter { !referenced.contains($0.standardizedFileURL.path) }
    }

    static func isGameFolder(_ url: URL, runtime: String?) -> Bool {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        switch runtime {
        case "cemu":
            if let tmd = try? Data(contentsOf: url.appendingPathComponent("title.tmd")), tmd.count >= 4 {
                let signature = tmd.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let offsets: [UInt32: Int] = [0x10000: 0x240, 0x10001: 0x140, 0x10002: 0x80,
                                             0x10003: 0x240, 0x10004: 0x140, 0x10005: 0x80]
                if let offset = offsets[signature].map({ $0 + 0x4c }), offset + 8 <= tmd.count {
                    let type = tmd[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    return type != 0x0005000e && type != 0x0005000c
                }
                return true
            }
            let code = url.appendingPathComponent("code", isDirectory: true)
            return ((try? fm.contentsOfDirectory(at: code, includingPropertiesForKeys: nil)) ?? [])
                .contains { $0.pathExtension.lowercased() == "rpx" }
        default: return false
        }
    }

    static func isTitleID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

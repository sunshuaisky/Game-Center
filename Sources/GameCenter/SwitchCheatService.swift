import AppKit
import Foundation

struct SwitchCheatItem: Identifiable, Hashable {
    let id: String
    let buildID: String
    let fileName: String
    let name: String
    let isMaster: Bool
    let isEnabled: Bool
    let duplicateCount: Int
}

struct SwitchCheatCatalog {
    let titleID: String
    let directory: URL
    let items: [SwitchCheatItem]
    let unsupportedFiles: [String]
}

enum SwitchCheatService {
    private struct ParsedFile {
        let url: URL
        let buildID: String
        let entries: [(name: String, isMaster: Bool)]
    }

    static func switchDirectory(from libraryPath: String?) -> URL? {
        guard let libraryPath, !libraryPath.isEmpty else { return nil }
        let root = URL(fileURLWithPath: libraryPath, isDirectory: true)
        if root.lastPathComponent.lowercased() == "switch" { return root }
        if let child = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .first(where: { $0.lastPathComponent.lowercased() == "switch" }) {
            return child
        }
        return root.appendingPathComponent("switch", isDirectory: true)
    }

    static func titleID(for game: Game) -> String? {
        guard let url = try? game.resolvedURL() else { return titleID(in: game.title) }
        if let id = titleID(in: url.lastPathComponent) { return id }
        if url.pathExtension.lowercased() == "app" {
            let plistURL = url.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let id = plist["DMTitleID"] as? String,
               isTitleID(id) { return id.uppercased() }
            let manifestURL = url.appendingPathComponent("Contents/Resources/S2ArmStandalone/standalone.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = manifest["gameID"] as? String,
               isTitleID(id) { return id.uppercased() }
        }
        return titleID(in: game.title) ?? game.metadataTitle.flatMap { titleID(in: $0) }
    }

    static func directory(switchDirectory: URL, titleID: String) -> URL {
        switchDirectory
            .appendingPathComponent("cheat", isDirectory: true)
            .appendingPathComponent(titleID.uppercased(), isDirectory: true)
            .appendingPathComponent("cheats", isDirectory: true)
    }

    static func load(titleID: String, directory: URL) throws -> SwitchCheatCatalog {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "txt" && $0.lastPathComponent.lowercased() != "enabled.txt" && $0.lastPathComponent.lowercased() != "status.txt" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var parsed: [ParsedFile] = []
        var unsupported: [String] = []
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.count == 16, stem.allSatisfy(\.isHexDigit) else {
                unsupported.append(file.lastPathComponent)
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                unsupported.append(file.lastPathComponent)
                continue
            }
            guard let entries = parseEntries(text) else {
                unsupported.append(file.lastPathComponent)
                continue
            }
            parsed.append(ParsedFile(url: file, buildID: stem.uppercased(), entries: entries))
        }

        let enabledByBuild = Dictionary(uniqueKeysWithValues: parsed.map { file in
            (file.buildID, Set(readLines(file.url.deletingPathExtension().appendingPathExtension("enabled"))))
        })
        let s2armEnabled = Set(readLines(directory.appendingPathComponent("enabled.txt")))
        let hasExistingState = parsed.contains { fm.fileExists(atPath: $0.url.deletingPathExtension().appendingPathExtension("enabled").path) }
            || fm.fileExists(atPath: directory.appendingPathComponent("enabled.txt").path)

        var items: [SwitchCheatItem] = []
        for file in parsed {
            let regular = file.entries.filter { !$0.isMaster }
            var countsByName: [String: Int] = [:]
            var uniqueNames: [String] = []
            for entry in regular {
                if countsByName[entry.name] == nil {
                    uniqueNames.append(entry.name)
                }
                countsByName[entry.name, default: 0] += 1
            }
            for name in uniqueNames {
                let duplicates = countsByName[name] ?? 1
                let nxKeys = (1...duplicates).map { index in index == 1 ? name : "\(name) #\(index)" }
                let nxEnabled = nxKeys.allSatisfy { enabledByBuild[file.buildID]?.contains($0) == true }
                let isEnabled = hasExistingState && (nxEnabled || s2armEnabled.contains("\(file.url.lastPathComponent)/\(name)"))
                items.append(SwitchCheatItem(
                    id: "\(file.buildID):\(name)",
                    buildID: file.buildID,
                    fileName: file.url.lastPathComponent,
                    name: name,
                    isMaster: false,
                    isEnabled: isEnabled,
                    duplicateCount: duplicates
                ))
            }
            for entry in file.entries where entry.isMaster {
                items.append(SwitchCheatItem(
                    id: "\(file.buildID):master:\(entry.name)",
                    buildID: file.buildID,
                    fileName: file.url.lastPathComponent,
                    name: entry.name,
                    isMaster: true,
                    isEnabled: true,
                    duplicateCount: 1
                ))
            }
        }
        // NXNative enables every cheat when no state file exists. Seed both engine formats as off
        // so the first launch is safe and the user explicitly chooses what to enable.
        if !hasExistingState, !parsed.isEmpty {
            try writeStates(items: items, directory: directory)
        }
        return SwitchCheatCatalog(titleID: titleID.uppercased(), directory: directory, items: items, unsupportedFiles: unsupported)
    }

    static func setEnabled(_ enabled: Bool, item: SwitchCheatItem, catalog: SwitchCheatCatalog) throws -> SwitchCheatCatalog {
        var items = catalog.items
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return catalog }
        items[index] = SwitchCheatItem(
            id: item.id, buildID: item.buildID, fileName: item.fileName, name: item.name,
            isMaster: item.isMaster, isEnabled: enabled, duplicateCount: item.duplicateCount
        )
        try writeStates(items: items, directory: catalog.directory)
        return SwitchCheatCatalog(
            titleID: catalog.titleID,
            directory: catalog.directory,
            items: items,
            unsupportedFiles: catalog.unsupportedFiles
        )
    }

    static func openFolder(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private static func writeStates(items: [SwitchCheatItem], directory: URL) throws {
        let byBuild = Dictionary(grouping: items.filter { !$0.isMaster && $0.isEnabled }, by: \.buildID)
        let buildIDs = Set(items.map(\.buildID))
        for buildID in buildIDs {
            let enabledNames = (byBuild[buildID] ?? []).flatMap { item in
                (1...item.duplicateCount).map { index in index == 1 ? item.name : "\(item.name) #\(index)" }
            }
            let file = directory.appendingPathComponent("\(buildID).enabled")
            try Data(enabledNames.sorted().joined(separator: "\n").appending(enabledNames.isEmpty ? "" : "\n").utf8).write(to: file, options: .atomic)
        }
        let s2armKeys = items.filter { !$0.isMaster && $0.isEnabled }
            .map { "\($0.fileName)/\($0.name)" }
        let s2armURL = directory.appendingPathComponent("enabled.txt")
        try Data(s2armKeys.sorted().joined(separator: "\n").appending(s2armKeys.isEmpty ? "" : "\n").utf8).write(to: s2armURL, options: .atomic)
    }

    private static func parseEntries(_ text: String) -> [(name: String, isMaster: Bool)]? {
        var entries: [(String, Bool)] = []
        var current: (name: String, isMaster: Bool)?
        var hasCode = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.first == "[" || line.first == "{" {
                if hasCode, let current { entries.append((current.name, current.isMaster)) }
                let master = line.first == "{"
                let close: Character = master ? "}" : "]"
                guard line.last == close, line.count >= 2 else { return nil }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                current = (name.isEmpty ? (master ? "主代码" : "未命名") : name, master)
                hasCode = false
            } else if isHexCodeLine(line) {
                if current == nil { current = ("未命名", false) }
                hasCode = true
            } else {
                return nil
            }
        }
        if hasCode, let current { entries.append((current.name, current.isMaster)) }
        return entries
    }

    private static func isHexCodeLine(_ line: String) -> Bool {
        for byte in line.utf8 {
            let isHex = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
            let isSpace = byte == 32 || byte == 9
            if !isHex && !isSpace { return false }
        }
        return true
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let titleIDRegex = try! NSRegularExpression(pattern: #"(?i)[0-9a-f]{16}"#)

    private static func titleID(in string: String) -> String? {
        let ns = string as NSString
        guard let match = titleIDRegex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range).uppercased()
    }

    private static func isTitleID(_ value: String) -> Bool {
        value.count == 16 && value.allSatisfy(\.isHexDigit)
    }
}

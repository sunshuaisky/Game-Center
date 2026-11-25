import Foundation

/// Seeds bundled BIOS and console firmware into each emulator's data folder.
/// Only missing files are written; anything the user already configured and
/// that still works is left untouched.
///
/// The bundle carries the owner's personal dumps; a package containing
/// SystemFiles must never be redistributed.
enum SystemFileRestorer {
    /// Everything a console's BIOS folder may legitimately contain. Release
    /// archives also ship .bat/.inf/.diff companions that emulators ignore.
    private static let biosExtensions: Set<String> = ["bin", "rom0", "rom1", "rom2", "erom", "mec", "nvm"]

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func restoreIfNeeded() {
        let support = applicationSupport
        preparePS2BIOS(support: support)
        preparePS1BIOS(support: support)

        // PS3: RPCS3 treats a present dev_flash as installed firmware.
        let devFlash = support.appendingPathComponent("rpcs3/dev_flash", isDirectory: true)
        if !FileManager.default.fileExists(atPath: devFlash.path) {
            seedTree(from: bundled("PS3Firmware/dev_flash"), to: devFlash)
        }

        // PSV: Vita3K firmware lives in the vs0/pd0/os0 partitions. ux0 (user
        // apps and saves) is deliberately not bundled and not restored.
        let vitaFS = support.appendingPathComponent("Vita3K/Vita3K/fs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vitaFS.appendingPathComponent("vs0").path) {
            for partition in ["pd0", "vs0", "os0"] {
                seedTree(from: bundled("PSVFirmware/\(partition)"), to: vitaFS.appendingPathComponent(partition, isDirectory: true))
            }
        }
    }

    /// PCSX2 reads its BIOS from the folder named under [Folders] Bios. Fill
    /// its own bios folder from the bundle and switch to it whenever the
    /// configured folder holds no files — the usual cause being a folder under
    /// Downloads that was later moved or deleted.
    static func preparePS2BIOS(support: URL) {
        let root = support.appendingPathComponent("PCSX2", isDirectory: true)
        let managed = root.appendingPathComponent("bios", isDirectory: true)
        let ini = root.appendingPathComponent("inis/PCSX2.ini")
        // PCSX2 resolves folder entries relative to its settings root, not inis/.
        let configured = resolved(MacGameSaveStorage.iniValue(at: ini, section: "Folders", key: "Bios") ?? "bios", base: root)
        ensureBIOS(bundled: bundled("PS2BIOS"), managed: managed, configured: configured) {
            try MacGameSaveStorage.setINI(at: ini, section: "Folders", key: "Bios", value: managed.path)
        }
    }

    /// DuckStation scans [BIOS] SearchDirectory. Same policy as PCSX2.
    static func preparePS1BIOS(support: URL) {
        let root = support.appendingPathComponent("DuckStation", isDirectory: true)
        let managed = root.appendingPathComponent("bios", isDirectory: true)
        let ini = root.appendingPathComponent("settings.ini")
        let configured = resolved(MacGameSaveStorage.iniValue(at: ini, section: "BIOS", key: "SearchDirectory") ?? "bios", base: root)
        ensureBIOS(bundled: bundled("PS1BIOS"), managed: managed, configured: configured) {
            try MacGameSaveStorage.setINI(at: ini, section: "BIOS", key: "SearchDirectory", value: managed.path)
        }
    }

    /// A different folder that actually holds BIOS files is the user's own
    /// working choice and is kept. Otherwise the managed folder is filled
    /// from the bundle, and a broken setting is redirected to it.
    private static func ensureBIOS(
        bundled source: URL?, managed: URL, configured: URL, redirect: () throws -> Void
    ) {
        if configured.standardizedFileURL.path != managed.standardizedFileURL.path, holdsFiles(configured) { return }
        guard seedBIOS(from: source, into: managed) else { return }
        if !holdsFiles(configured) { try? redirect() }
    }

    private static func bundled(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("SystemFiles/\(name)", isDirectory: true),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func resolved(_ value: String, base: URL) -> URL {
        value.hasPrefix("/") ? URL(fileURLWithPath: value) : base.appendingPathComponent(value)
    }

    /// Writes the bundled BIOS files `destination` is still missing, and
    /// reports whether that folder now holds any.
    private static func seedBIOS(from source: URL?, into destination: URL) -> Bool {
        let fileManager = FileManager.default
        if let source, let items = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in items where isBIOSFile(item) && !isDirectory(item) {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path),
                      (try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { continue }
                try? fileManager.copyItem(at: item, to: target)
            }
        }
        return holdsFiles(destination)
    }

    private static func isBIOSFile(_ url: URL) -> Bool {
        biosExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func holdsFiles(_ directory: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        return items.contains { !isDirectory($0) && isBIOSFile($0) }
    }

    private static func seedTree(from source: URL?, to destination: URL) {
        guard let source, !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }
}

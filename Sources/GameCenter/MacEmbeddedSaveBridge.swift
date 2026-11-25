import Foundation
#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif

struct EmbeddedSaveContext: Sendable {
    let systemDir: URL
    let saveDir: URL
    let batteryURL: URL?
    let statesDir: URL
}

/// Bridges the embedded Libretro Helper into Game Center's canonical `save/<platform>` tree
/// and bundled BIOS/SystemFiles, keeping backward compatibility with existing desktop saves
/// and iCloud sync rules.
enum MacEmbeddedSaveBridge {
    private static let desmumeFooterMarker = Data("|<--Snip above here to create a raw sav by excluding this DeSmuME savedata footer:".utf8)

    static func prepare(
        platform: GamePlatform,
        rom: URL,
        root: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> EmbeddedSaveContext {
        let fm = FileManager.default
        let saveRoot = root.appendingPathComponent("save", isDirectory: true)
        let platformFolder = GameSaveLayout.folder(root: root, platform: platform.id)
        let stem = rom.deletingPathExtension().lastPathComponent
        let perGame = platformFolder.appendingPathComponent(stem, isDirectory: true)
        let statesDir = perGame.appendingPathComponent("states", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let defaultSystemDir = support.appendingPathComponent("Game Center/CoreSystem/\(GameSaveLayout.platform(platform.id))", isDirectory: true)

        try fm.createDirectory(at: platformFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: perGame, withIntermediateDirectories: true)
        try fm.createDirectory(at: statesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: defaultSystemDir, withIntermediateDirectories: true)

        switch platform {
        case .gb, .gbc, .gba:
            let targetSav = perGame.appendingPathComponent(stem + ".sav")
            let siblingSav = rom.deletingPathExtension().appendingPathExtension("sav")
            try GameSaveLayout.migrate(siblingSav, to: targetSav, saveRoot: saveRoot)
            let legacySrm = perGame.appendingPathComponent("battery.srm")
            if !fm.fileExists(atPath: targetSav.path), fm.fileExists(atPath: legacySrm.path) {
                try fm.copyItem(at: legacySrm, to: targetSav)
            }
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: perGame,
                batteryURL: targetSav,
                statesDir: statesDir
            )

        case .nds:
            let targetSrm = perGame.appendingPathComponent("battery.srm")
            let legacyBatteryDir = platformFolder.appendingPathComponent("battery", isDirectory: true)
            let dsvCandidates = [
                legacyBatteryDir.appendingPathComponent(stem + ".dsv"),
                rom.deletingPathExtension().appendingPathExtension("dsv")
            ]
            if !fm.fileExists(atPath: targetSrm.path) {
                if let existingDSV = dsvCandidates.first(where: { fm.fileExists(atPath: $0.path) }),
                   let raw = try? Data(contentsOf: existingDSV), !raw.isEmpty {
                    let stripped = stripDeSmuMEFooter(raw)
                    try stripped.write(to: targetSrm, options: .atomic)
                }
            }
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: perGame,
                batteryURL: targetSrm,
                statesDir: statesDir
            )

        case .ps1:
            SystemFileRestorer.preparePS1BIOS(support: support)
            let duckStationBIOS = support.appendingPathComponent("DuckStation/bios", isDirectory: true)
            let bundledBIOS = Bundle.main.resourceURL?.appendingPathComponent("SystemFiles/PS1BIOS", isDirectory: true)
            let biosDir: URL
            if hasBIOSFiles(in: duckStationBIOS) {
                biosDir = duckStationBIOS
            } else if let bundledBIOS, hasBIOSFiles(in: bundledBIOS) {
                biosDir = bundledBIOS
            } else {
                biosDir = defaultSystemDir
            }
            let memcards = platformFolder.appendingPathComponent("memcards", isDirectory: true)
            try fm.createDirectory(at: memcards, withIntermediateDirectories: true)
            return EmbeddedSaveContext(
                systemDir: biosDir,
                saveDir: memcards,
                batteryURL: nil,
                statesDir: statesDir
            )

        case .psp:
            // PPSSPP libretro reads PPSSPP assets from `<systemDir>/PPSSPP` and writes PSP saves under `<saveDir>/PSP/SAVEDATA`.
            let pspAssetsDest = defaultSystemDir.appendingPathComponent("PPSSPP", isDirectory: true)
            if !fm.fileExists(atPath: pspAssetsDest.path),
               let bundledPSP = MacCoreCatalog.bundledSystemAssetsDirectory(for: "PSP") {
                let bundledAssets = bundledPSP.appendingPathComponent("PPSSPP", isDirectory: true)
                if fm.fileExists(atPath: bundledAssets.path) {
                    try? fm.copyItem(at: bundledAssets, to: pspAssetsDest)
                }
            }
            let pspDir = platformFolder.appendingPathComponent("PSP", isDirectory: true)
            try fm.createDirectory(at: pspDir, withIntermediateDirectories: true)
            let savedataTarget = platformFolder.appendingPathComponent("SAVEDATA", isDirectory: true)
            try fm.createDirectory(at: savedataTarget, withIntermediateDirectories: true)
            let nestedSavedata = pspDir.appendingPathComponent("SAVEDATA", isDirectory: true)
            if !fm.fileExists(atPath: nestedSavedata.path), (try? fm.destinationOfSymbolicLink(atPath: nestedSavedata.path)) == nil {
                try? GameSaveLayout.createAlias(at: nestedSavedata, to: savedataTarget)
            }
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: platformFolder,
                batteryURL: nil,
                statesDir: statesDir
            )

        case .threeDS:
            // Azahar libretro stores `sdmc/` and `nand/` under `<saveDir>/Citra` (or `<saveDir>/Azahar`).
            // Link `sdmc` and `nand` directly to `save/3ds/{sdmc,nand}` so desktop Azahar saves stay shared.
            for sub in ["sdmc", "nand"] {
                try fm.createDirectory(at: platformFolder.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
            }
            for coreFolderName in ["Azahar", "Citra"] {
                let coreFolder = platformFolder.appendingPathComponent(coreFolderName, isDirectory: true)
                try fm.createDirectory(at: coreFolder, withIntermediateDirectories: true)
                for sub in ["sdmc", "nand"] {
                    let linkURL = coreFolder.appendingPathComponent(sub, isDirectory: true)
                    let target = platformFolder.appendingPathComponent(sub, isDirectory: true)
                    if !fm.fileExists(atPath: linkURL.path), (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) == nil {
                        try? GameSaveLayout.createAlias(at: linkURL, to: target)
                    }
                }
            }
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: platformFolder,
                batteryURL: nil,
                statesDir: statesDir
            )

        case .wii:
            // Seed Dolphin `dolphin-emu/Sys` data into systemDir if bundled.
            let sysDest = defaultSystemDir.appendingPathComponent("dolphin-emu/Sys", isDirectory: true)
            if !fm.fileExists(atPath: sysDest.path),
               let bundledWii = MacCoreCatalog.bundledSystemAssetsDirectory(for: "Wii") {
                let bundledSys = bundledWii.appendingPathComponent("dolphin-emu/Sys", isDirectory: true)
                if fm.fileExists(atPath: bundledSys.path) {
                    try? fm.createDirectory(at: sysDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.copyItem(at: bundledSys, to: sysDest)
                }
            }
            let userRoot = platformFolder.appendingPathComponent("User", isDirectory: true)
            try fm.createDirectory(at: userRoot, withIntermediateDirectories: true)
            for sub in ["GC", "Wii"] {
                let canonical = platformFolder.appendingPathComponent(sub, isDirectory: true)
                try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
                let linkURL = userRoot.appendingPathComponent(sub, isDirectory: true)
                if !fm.fileExists(atPath: linkURL.path), (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) == nil {
                    try? GameSaveLayout.createAlias(at: linkURL, to: canonical)
                }
            }
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: platformFolder,
                batteryURL: nil,
                statesDir: statesDir
            )

        case .ps2:
            SystemFileRestorer.preparePS2BIOS(support: support)
            let pcsx2Profile = defaultSystemDir.appendingPathComponent("pcsx2", isDirectory: true)
            try fm.createDirectory(at: pcsx2Profile, withIntermediateDirectories: true)

            let managedBIOS = support.appendingPathComponent("PCSX2/bios", isDirectory: true)
            let bundledBIOS = Bundle.main.resourceURL?.appendingPathComponent("SystemFiles/PS2BIOS", isDirectory: true)
            let biosDest = pcsx2Profile.appendingPathComponent("bios", isDirectory: true)
            if !fm.fileExists(atPath: biosDest.path), (try? fm.destinationOfSymbolicLink(atPath: biosDest.path)) == nil {
                if hasBIOSFiles(in: managedBIOS) {
                    try? fm.createSymbolicLink(at: biosDest, withDestinationURL: managedBIOS)
                } else if let bundledBIOS, hasBIOSFiles(in: bundledBIOS) {
                    try? fm.copyItem(at: bundledBIOS, to: biosDest)
                } else {
                    try fm.createDirectory(at: biosDest, withIntermediateDirectories: true)
                }
            }

            let memcards = platformFolder.appendingPathComponent("memcards", isDirectory: true)
            try fm.createDirectory(at: memcards, withIntermediateDirectories: true)
            let profileMemcards = pcsx2Profile.appendingPathComponent("memcards", isDirectory: true)
            if !fm.fileExists(atPath: profileMemcards.path), (try? fm.destinationOfSymbolicLink(atPath: profileMemcards.path)) == nil {
                try? GameSaveLayout.createAlias(at: profileMemcards, to: memcards)
            }
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: platformFolder,
                batteryURL: nil,
                statesDir: statesDir
            )

        default:
            return EmbeddedSaveContext(
                systemDir: defaultSystemDir,
                saveDir: perGame,
                batteryURL: perGame.appendingPathComponent("battery.srm"),
                statesDir: statesDir
            )
        }
    }

    static func stripDeSmuMEFooter(_ data: Data) -> Data {
        if let range = data.range(of: desmumeFooterMarker) {
            return data.subdata(in: 0..<range.lowerBound)
        }
        return data
    }

    private static func hasBIOSFiles(in directory: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return items.contains { ["bin", "rom", "rom0", "rom1", "rom2", "mec", "nvm"].contains($0.pathExtension.lowercased()) }
    }
}

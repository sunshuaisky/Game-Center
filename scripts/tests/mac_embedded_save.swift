import Foundation

enum GamePlatform: String, CaseIterable {
    case gb, gbc, gba, nds, threeDS, psp, famicom, superFamicom, n64, megaDrive, ps1, ps2, ps3, psv, wii, wiiu, switchConsole, macOS
    var id: String { rawValue }
}
struct Game { let platform: GamePlatform }
enum MobileLibraryFormat { static func isTitleID(_ value: String) -> Bool { value.count == 16 } }

@main
struct MacEmbeddedSaveTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("gc-embedded-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }

        let root = fixture.appendingPathComponent("Library")
        let home = fixture.appendingPathComponent("Home")

        // 1. GBA sibling .sav migrates into save/gba/<stem>/<stem>.sav (aligned with CloudSaveDirectorySync)
        let gbaRom = root.appendingPathComponent("gba/Metroid.gba")
        try fm.createDirectory(at: gbaRom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rom".utf8).write(to: gbaRom)
        try Data("gba-battery-data".utf8).write(to: gbaRom.deletingPathExtension().appendingPathExtension("sav"))

        let gbaCtx = try MacEmbeddedSaveBridge.prepare(platform: .gba, rom: gbaRom, root: root, home: home)
        precondition(gbaCtx.batteryURL?.lastPathComponent == "Metroid.sav")
        let gbaContent = try String(contentsOf: gbaCtx.batteryURL!, encoding: .utf8)
        precondition(gbaContent == "gba-battery-data")

        // 2. NDS legacy DeSmuME .dsv footer stripping into battery.srm without touching original .dsv
        let ndsRom = root.appendingPathComponent("nds/Pokemon.nds")
        try fm.createDirectory(at: ndsRom.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyDSV = root.appendingPathComponent("save/nds/battery/Pokemon.dsv")
        try fm.createDirectory(at: legacyDSV.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dsvPayload = Data("RAW_NDS_SRAM_PAYLOAD".utf8)
        dsvPayload.append(Data("|<--Snip above here to create a raw sav by excluding this DeSmuME savedata footer:trailing".utf8))
        try dsvPayload.write(to: legacyDSV)

        let ndsCtx = try MacEmbeddedSaveBridge.prepare(platform: .nds, rom: ndsRom, root: root, home: home)
        precondition(ndsCtx.batteryURL?.lastPathComponent == "battery.srm")
        let ndsContent = try String(contentsOf: ndsCtx.batteryURL!, encoding: .utf8)
        precondition(ndsContent == "RAW_NDS_SRAM_PAYLOAD")
        let intactDSV = try Data(contentsOf: legacyDSV)
        precondition(intactDSV == dsvPayload, "Original .dsv must remain intact")

        // 3. PS1 resolves DuckStation BIOS dir & memcards saveDir
        let ps1BIOSDir = home.appendingPathComponent("Library/Application Support/DuckStation/bios")
        try fm.createDirectory(at: ps1BIOSDir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: ps1BIOSDir.appendingPathComponent("scph5501.bin"))

        let ps1Rom = root.appendingPathComponent("ps1/Symphony.cue")
        let ps1Ctx = try MacEmbeddedSaveBridge.prepare(platform: .ps1, rom: ps1Rom, root: root, home: home)
        precondition(ps1Ctx.systemDir.standardizedFileURL == ps1BIOSDir.standardizedFileURL)
        precondition(ps1Ctx.saveDir.lastPathComponent == "memcards")
        precondition(ps1Ctx.batteryURL == nil)

        // 4. Phase 2 platforms: PSP, 3DS, Wii, PS2 save routing & BIOS linking
        let pspCtx = try MacEmbeddedSaveBridge.prepare(platform: .psp, rom: root.appendingPathComponent("psp/Patapon.iso"), root: root, home: home)
        precondition(fm.fileExists(atPath: pspCtx.saveDir.appendingPathComponent("PSP/SAVEDATA").path))

        let threeDSCtx = try MacEmbeddedSaveBridge.prepare(platform: .threeDS, rom: root.appendingPathComponent("3ds/Zelda.3ds"), root: root, home: home)
        precondition(fm.fileExists(atPath: threeDSCtx.saveDir.appendingPathComponent("Azahar/sdmc").path))
        precondition(fm.fileExists(atPath: threeDSCtx.saveDir.appendingPathComponent("Citra/nand").path))

        let wiiCtx = try MacEmbeddedSaveBridge.prepare(platform: .wii, rom: root.appendingPathComponent("wii/Galaxy.rvz"), root: root, home: home)
        precondition(fm.fileExists(atPath: wiiCtx.saveDir.appendingPathComponent("User/Wii").path))
        precondition(fm.fileExists(atPath: wiiCtx.saveDir.appendingPathComponent("User/GC").path))

        let ps2BIOSDir = home.appendingPathComponent("Library/Application Support/PCSX2/bios")
        try fm.createDirectory(at: ps2BIOSDir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: ps2BIOSDir.appendingPathComponent("scph39001.bin"))
        let ps2Ctx = try MacEmbeddedSaveBridge.prepare(platform: .ps2, rom: root.appendingPathComponent("ps2/ICO.iso"), root: root, home: home)
        precondition(fm.fileExists(atPath: ps2Ctx.systemDir.appendingPathComponent("pcsx2/bios/scph39001.bin").path))
        precondition(fm.fileExists(atPath: ps2Ctx.systemDir.appendingPathComponent("pcsx2/memcards").path))

        print("PASS: Phase 1 & Phase 2 save/BIOS routing (GBA, NDS .dsv, PS1, PSP, 3DS, Wii, PS2)")
    }
}

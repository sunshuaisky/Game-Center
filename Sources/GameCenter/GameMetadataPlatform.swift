import Foundation

/// Shared by desktop and phone; independent of desktop bookmarks and UI types.
enum GameMetadataPlatform: String, CaseIterable, Sendable {
    case gba, gb, gbc, nds, threeDS, psp, famicom, superFamicom, n64, megaDrive, ps1, psv, ps2, ps3, ps4, gamecube, wii, wiiu, dreamcast, xbox, atari2600, colecovision, msx, msx2, pce, pcecd, sgx, sgxcd, sms, gg, segacd, sega32x, segacd32x, sg1000, sc3000, ws, wsc, ngp, ngpc, aes, mvs, n64dd, dendy, fds, pcv2, myvision, zx, zx128, arcade, megald, pcld, switchConsole, macOS
    var isRetroConsole: Bool { self != .switchConsole && self != .macOS }
    init?(platformID: String) {
        self.init(rawValue: ["switch": "switchConsole", "3ds": "threeDS", "nes": "famicom", "snes": "superFamicom", "md": "megaDrive"][platformID] ?? platformID)
    }
}

import Foundation

/// Shared by desktop and phone; independent of desktop bookmarks and UI types.
enum GameMetadataPlatform: String, CaseIterable, Sendable {
    case gba, gb, gbc, nds, threeDS, psp, famicom, superFamicom, n64, megaDrive, ps1, psv, ps2, ps3, ps4, gamecube, wii, wiiu, dreamcast, xbox, atari2600, colecovision, msx, msx2, pce, pcecd, sgx, sgxcd, sms, gg, segacd, sega32x, segacd32x, sg1000, sc3000, ws, wsc, ngp, ngpc, aes, mvs, n64dd, dendy, fds, pcv2, myvision, zx, zx128, arcade, megald, pcld, switchConsole, macOS

    var isRetroConsole: Bool { self != .switchConsole && self != .macOS }

    init?(platformID: String) {
        if let exact = Self(rawValue: platformID) {
            self = exact
            return
        }
        let normalized = platformID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: String] = [
            "switch": "switchConsole",
            "switchconsole": "switchConsole",
            "3ds": "threeDS",
            "3dsx": "threeDS",
            "threeds": "threeDS",
            "nes": "famicom",
            "fc": "famicom",
            "snes": "superFamicom",
            "sfc": "superFamicom",
            "superfamicom": "superFamicom",
            "md": "megaDrive",
            "megadrive": "megaDrive",
            "mega drive": "megaDrive",
            "genesis": "megaDrive",
            "psx": "ps1",
            "vita": "psv",
            "psvita": "psv",
            "ps vita": "psv",
            "gc": "gamecube",
            "ngc": "gamecube",
            "dc": "dreamcast",
            "wii u": "wiiu",
            "mac": "macOS",
            "macos": "macOS"
        ]
        if let mapped = aliases[normalized], let value = Self(rawValue: mapped) {
            self = value
            return
        }
        if let matched = Self.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            self = matched
            return
        }
        return nil
    }
}

import Foundation

final class MetadataFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let bannerFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/metadata-banner.png")
        let bannerImage = try! Data(contentsOf: bannerFixture)

        if url.path.hasSuffix("/banner/1080p") || url.host == "lain.bgm.tv" || url.host == "art.gametdb.com" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bannerImage)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.host == "images.fixture" {
            let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")!
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: image)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.host == "www.gametdb.com", url.path == "/switchtdb.txt" {
            let text: String
            if query["LANG"] == "EN" {
                text = "ABCD1 = Fixture Indie Adventure\n"
            } else {
                text = "ZZZZZ = 无关游戏\n"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var json: [String: Any]?
        if url.host == "api.nlib.cc", url.path == "/nx/01008CF01BAAC000" {
            json = ["name": "The Legend of Zelda™: Echoes of Wisdom", "icon": "https://images.fixture/cover.png"]
        } else if url.host == "api.bgm.tv", url.path.contains("/search/subject/") {
            let decoded = url.path.removingPercentEncoding ?? ""
            if decoded.contains("神秘星际冒险") {
                json = ["results": 1, "list": [["id": 999001, "name": "Fixture Indie Adventure", "name_cn": "神秘星际冒险"]]]
            }
        } else if url.host == "api.bgm.tv", url.path == "/v0/subjects/999001" {
            json = [
                "id": 999001,
                "name": "Fixture Indie Adventure",
                "name_cn": "神秘星际冒险",
                "summary": "一款来自 Bangumi 词条的独立太空动作冒险游戏，用于验证跨源补全和封面回退。",
                "images": ["large": "https://lain.bgm.tv/pic/cover/l/fixture.png"],
                "infobox": [["key": "英文名", "value": "Fixture Indie Adventure"]]
            ]
        } else if url.host?.hasSuffix("wikipedia.org") == true {
            let search = query["gsrsearch"] ?? ""
            let titles = query["titles"] ?? ""
            if search.contains("Unrelated Missing Game") || search.contains("神秘星际冒险") || search.contains("Fixture Indie Adventure") {
                json = nil
            } else if query["prop"] == "langlinks" {
                json = ["query": ["pages": [["langlinks": [["title": "薩爾達傳說 智慧的再現"]]]]]]
            } else if search.contains("智慧") || search.contains("Echoes of Wisdom") || titles.contains("智慧") {
                let chinese = url.host == "zh.wikipedia.org"
                json = ["query": ["pages": [[
                    "title": chinese ? "薩爾達傳說 智慧的再現" : "The Legend of Zelda: Echoes of Wisdom",
                    "extract": chinese ? "《塞尔达传说 智慧的再现》是一款任天堂 Switch 动作冒险游戏。" : "An action adventure game for Nintendo Switch.",
                    "canonicalurl": chinese ? "https://zh.wikipedia.org/wiki/薩爾達傳說_智慧的再現" : "https://en.wikipedia.org/wiki/The_Legend_of_Zelda:_Echoes_of_Wisdom"
                ]]]]
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: json == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json ?? [:])) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

actor BackdropProgress {
    private var received = false
    func record(_ data: Data) { precondition(data.count > 1000); received = true }
    func check() { precondition(received, "Background must publish independently of cover completion") }
}

actor TextProgress {
    private var received = false
    func record(_ result: GameMetadataResult) {
        precondition(result.synopsis != nil && result.artworkData == nil)
        received = true
    }
    func check() { precondition(received, "Text must arrive before the final artwork result") }
}

@main struct MetadataTests {
    static func main() async throws {
        // Title matcher checks including regional Chinese canonicalizations
        precondition(GameTitleMatcher.score("塞尔达传说 智慧的再现", "塞爾達傳說智慧的再現") == 1)
        precondition(GameTitleMatcher.score("塞尔达传说 智慧的再现", "薩爾達傳說 智慧的再現") >= 0.72)
        precondition(GameTitleMatcher.score("塞尔达传说 荒野之息", "薩爾達傳說 曠野之息") == 1)
        precondition(GameTitleMatcher.score("超级马里奥奥德赛", "超级马力欧 奥德赛") == 1)
        precondition(GameTitleMatcher.score("口袋妖怪 绿宝石", "精灵宝可梦 绿宝石") == 1)
        precondition(GameTitleMatcher.score("塞尔达传说 智慧的再现", "塞尔达传说 王国之泪") < 0.72)
        precondition(GameTitleMatcher.score("宝可梦 朱", "宝可梦 紫") < 0.72)
        precondition(GameTitleMatcher.score("塞尔达传说", "塞尔达传说 智慧的再现") < 0.72)
        precondition(GameTitleMatcher.score("Final Fantasy X", "Final Fantasy XVI") < 0.78)
        precondition(GameTitleMatcher.score("The Legend of Zelda™: Echoes of Wisdom", "The Legend of Zelda: Echoes of Wisdom") == 1)

        // Platform alias mapping checks
        precondition(GameMetadataPlatform(platformID: "switch") == .switchConsole)
        precondition(GameMetadataPlatform(platformID: "3ds") == .threeDS)
        precondition(GameMetadataPlatform(platformID: "fc") == .famicom)
        precondition(GameMetadataPlatform(platformID: "sfc") == .superFamicom)
        precondition(GameMetadataPlatform(platformID: "md") == .megaDrive)
        precondition(GameMetadataPlatform(platformID: "psx") == .ps1)
        precondition(GameMetadataPlatform(platformID: "vita") == .psv)
        precondition(GameMetadataPlatform(platformID: "Wii U") == .wiiu)

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MetadataFixture.self]
        let service = GameMetadataService(session: URLSession(configuration: config))

        let named = await service.lookup(title: "塞尔达传说 智慧的再现", platform: .switchConsole, language: "zh", sourceURL: nil)
        precondition(named.title == "塞尔达传说 智慧的再现" && named.synopsis?.contains("动作冒险") == true)

        // Phone can supply its installed Title ID without a desktop .app bundle.
        let textProgress = TextProgress()
        let backdropProgress = BackdropProgress()
        let phone = await service.lookup(title: "智慧再现", platform: .switchConsole, language: "zh", sourceURL: nil, titleID: "01008CF01BAAC000", onText: { await textProgress.record($0) }, onBackdrop: { await backdropProgress.record($0) })
        await textProgress.check()
        await backdropProgress.check()
        precondition(phone.backdropData != nil)
        precondition(phone.artworkData != nil)
        precondition(phone.title == named.title && phone.synopsis == named.synopsis)

        // Desktop launcher identity survives a Chinese filename and a custom bundle identifier.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("智慧再现.app/Contents/Resources/dm")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"game":"01008CF01BAAC000"}"#.utf8).write(to: folder.appendingPathComponent("launcher.json"))
        let app = root.appendingPathComponent("智慧再现.app")
        let desktop = await service.lookup(title: "智慧再现", platform: .switchConsole, language: "zh", sourceURL: app)
        precondition(desktop.title == named.title && desktop.synopsis == named.synopsis)

        // Phone Switch install with UUID passed as explicitTitleID must ignore invalid UUID
        // and fall back to Builds/S2Arm/manifest.json for the real Title ID.
        let iosSwitchDir = root.appendingPathComponent("ios-switch-game/Builds/S2Arm")
        try FileManager.default.createDirectory(at: iosSwitchDir, withIntermediateDirectories: true)
        try Data(#"{"titleID":"01008CF01BAAC000"}"#.utf8).write(to: iosSwitchDir.appendingPathComponent("manifest.json"))
        let iosResolved = await service.lookup(
            title: "智慧再现",
            platform: .switchConsole,
            language: "zh",
            sourceURL: root.appendingPathComponent("ios-switch-game"),
            titleID: "1F140E62-99BA-4D4B-AB35-91F2A7CDFF9B"
        )
        precondition(iosResolved.title == named.title && iosResolved.backdropData != nil)

        // Bangumi fallback provides Chinese synopsis & English title, which unlocks SwitchTDB EN box art.
        let bgmResolved = await service.lookup(title: "神秘星际冒险 [中文版]", platform: .switchConsole, language: "zh", sourceURL: nil)
        precondition(bgmResolved.title == "神秘星际冒险")
        precondition(bgmResolved.synopsis?.contains("Bangumi") == true)
        precondition(bgmResolved.artworkData != nil)
        precondition(bgmResolved.artworkSourceURL?.contains("art.gametdb.com") == true || bgmResolved.artworkSourceURL?.contains("lain.bgm.tv") == true)

        let missing = await service.lookup(title: "Unrelated Missing Game QZX123", platform: .macOS, language: "en", sourceURL: nil)
        precondition(!missing.hasMetadata, "A filename alone must not count as a successful lookup")
        print("PASS: unified matcher, platform aliases, Switch Title ID validation, iOS Builds manifest, Bangumi + SwitchTDB fallback, no false filename success")
    }
}

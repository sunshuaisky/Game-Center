import Foundation

final class MetadataFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if url.path.hasSuffix("/banner/1080p") {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/metadata-banner.png")
            let image = try! Data(contentsOf: fixture)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: image); client?.urlProtocolDidFinishLoading(self); return
        }
        if url.host == "images.fixture" {
            let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")!
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: image); client?.urlProtocolDidFinishLoading(self); return
        }
        var json: [String: Any]?
        if url.host == "api.nlib.cc", url.path == "/nx/01008CF01BAAC000" {
            json = ["name": "The Legend of Zelda™: Echoes of Wisdom", "icon":"https://images.fixture/cover.png"]
        } else if url.host?.hasSuffix("wikipedia.org") == true {
            if query["prop"] == "langlinks" {
                json = ["query": ["pages": [["langlinks": [["title": "薩爾達傳說 智慧的再現"]]]]]]
            } else {
                let chinese = url.host == "zh.wikipedia.org"
                json = ["query": ["pages": [[
                    "title": chinese ? "薩爾達傳說 智慧的再現" : "The Legend of Zelda: Echoes of Wisdom",
                    "extract": chinese ? "《塞尔达传说 智慧的再现》是一款任天堂 Switch 动作冒险游戏。" : "An action adventure game for Nintendo Switch.",
                    "canonicalurl": chinese ? "https://zh.wikipedia.org/wiki/薩爾達傳說_智慧的再現" : "https://en.wikipedia.org/wiki/The_Legend_of_Zelda:_Echoes_of_Wisdom"
                ]]]]
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: json == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
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
        precondition(GameTitleMatcher.score("塞尔达传说 智慧的再现", "塞爾達傳說智慧的再現") == 1)
        precondition(GameTitleMatcher.score("塞尔达传说 智慧的再现", "薩爾達傳說 智慧的再現") >= 0.72)
        precondition(GameTitleMatcher.score("塞尔达传说 智慧的再现", "塞尔达传说 王国之泪") < 0.72)
        precondition(GameTitleMatcher.score("宝可梦 朱", "宝可梦 紫") < 0.72)
        precondition(GameTitleMatcher.score("塞尔达传说", "塞尔达传说 智慧的再现") < 0.72)
        precondition(GameTitleMatcher.score("The Legend of Zelda™: Echoes of Wisdom", "The Legend of Zelda: Echoes of Wisdom") == 1)
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
        // Desktop launcher identity survives a Chinese filename and a custom
        // bundle identifier that no longer embeds the Title ID.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("智慧再现.app/Contents/Resources/dm")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"game":"01008CF01BAAC000"}"#.utf8).write(to: folder.appendingPathComponent("launcher.json"))
        let app = root.appendingPathComponent("智慧再现.app")
        let desktop = await service.lookup(title: "智慧再现", platform: .switchConsole, language: "zh", sourceURL: app)
        precondition(desktop.title == named.title && desktop.synopsis == named.synopsis)
        let missing = await service.lookup(title: "Unrelated Missing Game QZX123", platform: .macOS, language: "en", sourceURL: nil)
        precondition(!missing.hasMetadata, "A filename alone must not count as a successful lookup")
        print("PASS: simplified/traditional/spaced Chinese, regional title variant, reject other instalments, English trademark, phone Title ID, renamed desktop bundle, no false filename success")
    }
}

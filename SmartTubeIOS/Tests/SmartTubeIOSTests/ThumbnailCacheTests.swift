import Foundation
import Testing

@testable import SmartTubeIOS

@Suite("ThumbnailCache response classification")
struct ThumbnailCacheTests {
    private let url = URL(fileURLWithPath: "/vi/abc/maxresdefault.jpg")

    private func response(_ status: Int) throws -> URLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    @Test("2xx is usable")
    func okIsUsable() throws {
        #expect(ThumbnailCache.isUsable(try response(200)))
    }

    @Test("ytimg 404 (decodable grey placeholder body) is a miss")
    func notFoundIsMiss() throws {
        #expect(!ThumbnailCache.isUsable(try response(404)))
    }

    @Test("Non-HTTP responses (file/data URLs) are usable")
    func nonHTTPIsUsable() {
        let plain = URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: 0, textEncodingName: nil)
        #expect(ThumbnailCache.isUsable(plain))
    }
}

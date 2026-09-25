import XCTest
@testable import NotificationCore

final class AppReleaseTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) throws -> AppRelease {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    func testFetchAndHTTPFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ReleaseProtocol.status = 200
        let latest = try await AppRelease.fetch(session: session)
        XCTAssertTrue(latest.isNewer(than: "0.1.0"))
        ReleaseProtocol.status = 403
        do {
            _ = try await AppRelease.fetch(session: session)
            XCTFail("HTTP errors must not be treated as the latest version")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testUpdateNotificationDeduplicationSurvivesRestart() throws {
        let latest = try release("v0.2.2")
        var state = InboxState()
        XCTAssertTrue(latest.shouldNotify(installed: "0.2.1", lastNotified: state.lastNotifiedRelease))
        state.lastNotifiedRelease = "0.2.2"
        let restored = try JSONDecoder().decode(InboxState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(latest.shouldNotify(installed: "0.2.1", lastNotified: restored.lastNotifiedRelease))
        XCTAssertFalse(latest.shouldNotify(installed: "0.2.2", lastNotified: nil))
        XCTAssertFalse(try release("v0.3.0", prerelease: true).shouldNotify(installed: "0.2.1", lastNotified: nil))
        XCTAssertTrue(try release("v0.2.3").shouldNotify(installed: "0.2.1", lastNotified: restored.lastNotifiedRelease))
    }

    func testNumericVersionOrdering() throws {
        XCTAssertTrue(try release("v0.1.10").isNewer(than: "0.1.9"))
        XCTAssertTrue(try release("v1.0.0").isNewer(than: "0.99.99"))
        XCTAssertFalse(try release("v0.1.1").isNewer(than: "0.1.1"))
        XCTAssertFalse(try release("v0.1.0").isNewer(than: "0.1.1"))
    }

    func testIgnoresUnpublishedAndInvalidVersions() throws {
        XCTAssertFalse(try release("v9.0.0", draft: true).isNewer(than: "0.1.1"))
        XCTAssertFalse(try release("v9.0.0", prerelease: true).isNewer(than: "0.1.1"))
        for tag in ["v1.0.0-beta", "latest", "1.2", "1..2", "1.2.3.4", "-1.2.3", "999999999999999999999.0.0"] {
            XCTAssertNil(AppRelease.version(tag))
            XCTAssertFalse(try release(tag).isNewer(than: "0.1.1"))
        }
        XCTAssertFalse(try release("v1.0.0").isNewer(than: "invalid"))
    }
}

private final class ReleaseProtocol: URLProtocol {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/zimathon/github-notification/releases/latest")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"tag_name":"v0.1.1","draft":false,"prerelease":false}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

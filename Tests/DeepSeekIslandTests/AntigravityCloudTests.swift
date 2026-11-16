import Foundation
import XCTest
@testable import DeepSeekIsland

final class AntigravityCloudTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOAuthClientDiscoveryFindsConsumerClient() throws {
        let path = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Antigravity is not installed")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        let client = try XCTUnwrap(AntigravityOAuthConfig.parseClient(fromInstalledArtifactData: data))
        XCTAssertEqual(client.clientID, AntigravityOAuthConfig.consumerClientID)
        XCTAssertEqual(client.clientSecret.count, 35)
        XCTAssertTrue(client.clientSecret.hasPrefix("GOCSPX-"))
    }

    func testCloudFetchUsesStoredGrantAndParsesQuota() async throws {
        let store = SessionStore(directory: directory)
        XCTAssertTrue(store.saveAntigravityCloudGrant(.init(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            email: "user@example.com",
            projectID: "project-1",
            clientID: "client-id",
            clientSecret: "client-secret")))
        let log = RequestLog()
        let client = AntigravityCloudClient(store: store) { request in
            await log.record(request)
            return try Self.response(for: request)
        }
        let result = try await client.fetchQuota()
        XCTAssertEqual(result.email, "user@example.com")
        XCTAssertEqual(result.quota.geminiGroup?.bucket(.fiveHour)?.remainingPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(result.quota.geminiGroup?.bucket(.week)?.remainingPercent ?? 0, 75, accuracy: 0.001)
        let requests = await log.requests
        XCTAssertTrue(requests.contains { $0.url?.path == "/v1internal:loadCodeAssist" })
        let usedDailyHost = requests.contains { request in
            request.url?.host == "daily-cloudcode-pa.googleapis.com"
                && request.url?.path == "/v1internal:retrieveUserQuotaSummary"
        }
        XCTAssertTrue(usedDailyHost)
        XCTAssertTrue(requests.allSatisfy { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer access"
        })
    }

    func testCloudRefreshesExpiredGrantAndPersistsNewToken() async throws {
        let store = SessionStore(directory: directory)
        XCTAssertTrue(store.saveAntigravityCloudGrant(.init(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(-10),
            email: "user@example.com",
            projectID: "project-1",
            clientID: "client-id",
            clientSecret: "client-secret")))
        let client = AntigravityCloudClient(store: store) { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let body = #"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#
                return Self.responseData(request, body: Data(body.utf8))
            }
            try Self.requireBearer(request, token: "new")
            return try Self.response(for: request)
        }
        _ = try await client.fetchQuota()
        let saved = try XCTUnwrap(store.readAntigravityCloudGrant())
        XCTAssertEqual(saved.accessToken, "new")
        XCTAssertGreaterThan(saved.expiresAt.timeIntervalSinceNow, 3_000)
        XCTAssertEqual(saved.refreshToken, "refresh")
    }

    func testCloudRejectsConsumerClientMismatch() async throws {
        let store = SessionStore(directory: directory)
        XCTAssertTrue(store.saveAntigravityCloudGrant(.init(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            email: nil, projectID: nil, clientID: nil, clientSecret: nil)))
        let client = AntigravityCloudClient(store: store) { request in
            let body = #"{"currentTier":null,"ineligibleTiers":[{"reasonCode":"GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"}]}"#
            return Self.responseData(request, body: Data(body.utf8))
        }
        do {
            _ = try await client.fetchQuota()
            XCTFail("Expected client rejection")
        } catch {
            XCTAssertEqual(error as? AntigravityCloudError, .clientRejected)
        }
    }

    func testCloudRequiresSignedInGrant() async throws {
        let store = SessionStore(directory: directory)
        let client = AntigravityCloudClient(store: store) { request in
            throw URLError(.unsupportedURL)
        }
        do {
            _ = try await client.fetchQuota()
            XCTFail("Expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? AntigravityCloudError, .notSignedIn)
        }
    }

    func testTokenExchangeWaitsForAuthorizationConfirmationBeforeSaving() async throws {
        let store = SessionStore(directory: directory)
        let original = AntigravityCloudGrant(
            accessToken: "original", refreshToken: "original-refresh",
            expiresAt: Date().addingTimeInterval(3_600), email: nil,
            projectID: nil, clientID: nil, clientSecret: nil)
        XCTAssertTrue(store.saveAntigravityCloudGrant(original))
        let client = AntigravityCloudClient(store: store) { request in
            let body = request.url?.host == "oauth2.googleapis.com"
                ? #"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600}"#
                : #"{"email":"user@example.com"}"#
            return Self.responseData(request, body: Data(body.utf8))
        }
        let grant = try await client.exchange(code: "code", verifier: "verifier",
                                              redirectURI: "http://127.0.0.1/callback",
                                              oauthClient: .init(clientID: "client", clientSecret: "secret"))
        XCTAssertEqual(grant.accessToken, "new")
        XCTAssertEqual(grant.email, "user@example.com")
        XCTAssertEqual(store.readAntigravityCloudGrant(), original)
    }

    func testTokenRefreshCannotRestoreRemovedCredentials() async throws {
        let store = SessionStore(directory: directory)
        XCTAssertTrue(store.saveAntigravityCloudGrant(.init(
            accessToken: "old", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(-10), email: nil,
            projectID: nil, clientID: "client", clientSecret: "secret")))
        let client = AntigravityCloudClient(store: store) { request in
            XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
            XCTAssertTrue(store.deleteAntigravityCloudGrant())
            return Self.responseData(request, body: Data(#"{"access_token":"new","expires_in":3600}"#.utf8))
        }
        do {
            _ = try await client.fetchQuota()
            XCTFail("Removed credentials must stay removed")
        } catch is CancellationError {}
        XCTAssertNil(store.readAntigravityCloudGrant())
    }

    func testQuotaFallsBackWhenDailyEndpointIsUnavailable() async throws {
        let store = SessionStore(directory: directory)
        XCTAssertTrue(store.saveAntigravityCloudGrant(.init(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600), email: nil,
            projectID: "project-1", clientID: "client", clientSecret: "secret")))
        let log = RequestLog()
        let client = AntigravityCloudClient(store: store) { request in
            await log.record(request)
            if request.url?.host == "daily-cloudcode-pa.googleapis.com" {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503,
                                               httpVersion: nil, headerFields: nil)!)
            }
            return try Self.response(for: request)
        }
        let result = try await client.fetchQuota()
        XCTAssertNotNil(result.quota.geminiGroup?.bucket(.week))
        let requests = await log.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1internal:retrieveUserQuotaSummary" }.map { $0.url!.host! },
                       ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"])
    }

    func testAuthorizationURLCarriesPKCEAndOfflineAccess() throws {
        let url = try XCTUnwrap(AntigravityCloudAuthFlow.authorizationURL(
            clientID: AntigravityOAuthConfig.consumerClientID,
            redirectURI: "http://127.0.0.1:53210/callback",
            state: "state-value",
            challenge: "challenge-value"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["client_id"], AntigravityOAuthConfig.consumerClientID)
        XCTAssertEqual(values["redirect_uri"], "http://127.0.0.1:53210/callback")
        XCTAssertEqual(values["access_type"], "offline")
        XCTAssertEqual(values["code_challenge"], "challenge-value")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["state"], "state-value")
        XCTAssertTrue(values["scope"]?.contains("cloud-platform") == true)
    }

    private static func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url?.path
        switch path {
        case "/v1internal:loadCodeAssist":
            return responseData(request, body: Data(#"{"cloudaicompanionProject":"project-1"}"#.utf8))
        case "/v1internal:retrieveUserQuotaSummary":
            let json = """
            {"groups":[{"displayName":"Gemini Models","buckets":[
              {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,
               "resetTime":"2026-11-23T02:32:05Z"},
              {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,
               "resetTime":"2026-11-16T15:33:31Z"}
            ]}]}
            """
            return responseData(request, body: Data(json.utf8))
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private static func requireBearer(_ request: URLRequest, token: String) throws {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    private static func responseData(_ request: URLRequest, body: Data) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}

private actor RequestLog {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

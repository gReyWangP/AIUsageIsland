import Foundation

struct AntigravityCloudResult: Sendable {
    let quota: AntigravityQuota
    let email: String?
}

struct AntigravityCloudClient: Sendable {
    let store: SessionStore
    var timeout: TimeInterval = 12
    var dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let cloudCodeBase = "https://cloudcode-pa.googleapis.com"
    private static let dailyBase = "https://daily-cloudcode-pa.googleapis.com"
    private static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    private static let onboardUserPath = "/v1internal:onboardUser"
    private static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    private static let refreshSafetyWindow: TimeInterval = 60
    private static let clientMetadata: [String: String] = [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    ]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(store: SessionStore,
         timeout: TimeInterval = 12,
         dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
             try await AntigravityCloudClient.session.data(for: request)
         }) {
        self.store = store
        self.timeout = timeout
        self.dataLoader = dataLoader
    }

    var hasCredentials: Bool { store.readAntigravityCloudGrant() != nil }

    func exchange(code: String, verifier: String, redirectURI: String,
                  oauthClient: AntigravityOAuthClient) async throws -> AntigravityCloudGrant {
        let body = [
            "code": code,
            "client_id": oauthClient.clientID,
            "client_secret": oauthClient.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let json = try await sendForm(AntigravityOAuthConfig.tokenURL, body: body)
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw AntigravityCloudError.invalidResponse
        }
        let idToken = json["id_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        var email = Self.email(fromIDToken: idToken)
        if email == nil { email = try? await fetchUserEmail(accessToken: accessToken) }
        let grant = AntigravityCloudGrant(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email,
            projectID: nil,
            clientID: oauthClient.clientID,
            clientSecret: oauthClient.clientSecret)
        return grant
    }

    func fetchQuota() async throws -> AntigravityCloudResult {
        var grant = try await validGrant()
        let codeAssist = try await loadCodeAssist(accessToken: grant.accessToken)
        if codeAssist.rejectsClientForConsumerTier {
            throw AntigravityCloudError.clientRejected
        }
        let projectID = try await resolveProjectID(accessToken: grant.accessToken,
                                                   stored: grant.projectID,
                                                   initial: codeAssist)
        if let projectID, projectID != grant.projectID {
            try Task.checkCancellation()
            guard store.readAntigravityCloudGrant() == grant else { throw CancellationError() }
            grant.projectID = projectID
            guard store.saveAntigravityCloudGrant(grant) else { throw AntigravityCloudError.invalidResponse }
        }
        let quota = try await retrieveQuotaSummary(accessToken: grant.accessToken,
                                                    projectID: projectID)
        return AntigravityCloudResult(quota: quota, email: grant.email)
    }

    private func validGrant() async throws -> AntigravityCloudGrant {
        guard var grant = store.readAntigravityCloudGrant() else {
            throw AntigravityCloudError.notSignedIn
        }
        guard grant.expiresAt.timeIntervalSinceNow <= Self.refreshSafetyWindow else { return grant }
        let previousGrant = grant
        let oauthClient: AntigravityOAuthClient
        if let clientID = grant.clientID, let clientSecret = grant.clientSecret {
            oauthClient = AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
        } else if let discovered = await Task.detached(priority: .utility, operation: {
            AntigravityOAuthConfig.resolvedClient()
        }).value {
            oauthClient = discovered
        } else {
            throw AntigravityCloudError.oauthClientUnavailable
        }
        let body = [
            "client_id": oauthClient.clientID,
            "client_secret": oauthClient.clientSecret,
            "refresh_token": grant.refreshToken,
            "grant_type": "refresh_token",
        ]
        let json = try await sendForm(AntigravityOAuthConfig.tokenURL, body: body)
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw AntigravityCloudError.authorization
        }
        grant.accessToken = accessToken
        if let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty {
            grant.refreshToken = refreshToken
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        grant.expiresAt = Date().addingTimeInterval(expiresIn)
        if let email = Self.email(fromIDToken: json["id_token"] as? String) {
            grant.email = email
        }
        grant.clientID = oauthClient.clientID
        grant.clientSecret = oauthClient.clientSecret
        try Task.checkCancellation()
        guard store.readAntigravityCloudGrant() == previousGrant else { throw CancellationError() }
        guard store.saveAntigravityCloudGrant(grant) else { throw AntigravityCloudError.invalidResponse }
        return grant
    }

    private func loadCodeAssist(accessToken: String) async throws -> CodeAssistResult {
        let json = try await sendJSON(
            URL(string: Self.cloudCodeBase + Self.loadCodeAssistPath)!,
            accessToken: accessToken,
            body: ["metadata": Self.clientMetadata])
        let payload = (json["response"] as? [String: Any]) ?? json
        let projectID = Self.projectID(payload["cloudaicompanionProject"])
        let currentTier = payload["currentTier"] as? [String: Any]
        let ineligible = payload["ineligibleTiers"] as? [[String: Any]]
        let rejected = currentTier == nil && projectID == nil && ineligible?.contains {
            ($0["reasonCode"] as? String) == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"
        } == true
        return CodeAssistResult(projectID: projectID,
                                rejectsClientForConsumerTier: rejected,
                                onboardTierID: Self.onboardTierID(payload))
    }

    private func resolveProjectID(accessToken: String, stored: String?,
                                  initial: CodeAssistResult) async throws -> String? {
        if let projectID = stored ?? initial.projectID { return projectID }
        guard let tierID = initial.onboardTierID else { return nil }
        do {
            let json = try await sendJSON(
                URL(string: Self.cloudCodeBase + Self.onboardUserPath)!,
                accessToken: accessToken,
                body: ["tierId": tierID, "metadata": Self.clientMetadata])
            let payload = (json["response"] as? [String: Any]) ?? json
            if let projectID = Self.projectID(payload["cloudaicompanionProject"]) { return projectID }
        } catch let error as AntigravityCloudError {
            switch error {
            case .authorization, .clientRejected, .notSignedIn, .oauthClientUnavailable, .cancelled:
                throw error
            default: break
            }
        } catch {
            // Project onboarding is best effort; quota may still be readable.
        }
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            if let projectID = try await loadCodeAssist(accessToken: accessToken).projectID {
                return projectID
            }
        }
        return nil
    }

    private static func onboardTierID(_ payload: [String: Any]) -> String? {
        let allowed = payload["allowedTiers"] as? [[String: Any]] ?? []
        let preferred = allowed.first { $0["isDefault"] as? Bool == true }
        return (preferred?["id"] as? String)
            ?? (allowed.first?["id"] as? String)
            ?? ((payload["paidTier"] as? [String: Any])?["id"] as? String)
            ?? ((payload["currentTier"] as? [String: Any])?["id"] as? String)
    }

    private func retrieveQuotaSummary(accessToken: String, projectID: String?) async throws -> AntigravityQuota {
        let body: [String: Any] = projectID.map { ["project": $0] } ?? [:]
        var lastError: Error = AntigravityCloudError.invalidResponse
        for base in [Self.dailyBase, Self.cloudCodeBase] {
            do {
                let data = try await sendJSONData(
                    URL(string: base + Self.quotaSummaryPath)!,
                    accessToken: accessToken,
                    body: body)
                return try AntigravityQuotaParser.parse(data)
            } catch let error as AntigravityCloudError {
                lastError = error
                switch error {
                case .http(404), .http(500), .http(502), .http(503): continue
                default: throw error
                }
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func fetchUserEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: AntigravityOAuthConfig.userInfoURL)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await dataLoader(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    private func sendForm(_ url: URL, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(body)
        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse else { throw AntigravityCloudError.invalidResponse }
        switch http.statusCode {
        case 200:
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AntigravityCloudError.invalidResponse
            }
            return json
        case 400, 401:
            throw AntigravityCloudError.authorization
        default:
            throw AntigravityCloudError.http(http.statusCode)
        }
    }

    private func sendJSONData(_ url: URL, accessToken: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse else { throw AntigravityCloudError.invalidResponse }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw AntigravityCloudError.authorization
        default:
            throw AntigravityCloudError.http(http.statusCode)
        }
    }

    private func sendJSON(_ url: URL, accessToken: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try await sendJSONData(url, accessToken: accessToken, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityCloudError.invalidResponse
        }
        return json
    }

    private static var userAgent: String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        return "antigravity/hub/2.9.1 darwin/\(architecture)"
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private static func projectID(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        guard let object = value as? [String: Any] else { return nil }
        return (object["id"] as? String) ?? (object["projectId"] as? String)
    }

    private static func email(fromIDToken idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    private struct CodeAssistResult {
        let projectID: String?
        let rejectsClientForConsumerTier: Bool
        let onboardTierID: String?
    }
}
